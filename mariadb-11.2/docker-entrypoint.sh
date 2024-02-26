#!/bin/bash

# This script came from https://github.com/MariaDB/mariadb-docker/blob/f07f84ce55de7d7f1d85ccf2c642c4247b425ea4/docker-entrypoint.sh
# The only change is to tweak the logging function and remove the --rfc flag since it's not supported in our date impl
set -eo pipefail
shopt -s nullglob

# logging functions
mysql_log() {
	local type="$1"; shift
	printf '%s [%s] [Entrypoint]: %s\n' "$(date)" "$type" "$*"
}
mysql_note() {
	mysql_log Note "$@"
}
mysql_warn() {
	mysql_log Warn "$@" >&2
}
mysql_error() {
	mysql_log ERROR "$@" >&2
	exit 1
}

# usage: file_env VAR [DEFAULT]
#    ie: file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)
file_env() {
	local var="$1"
	local fileVar="${var}_FILE"
	local def="${2:-}"
	if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
		mysql_error "Both $var and $fileVar are set (but are exclusive)"
	fi
	local val="$def"
	if [ "${!var:-}" ]; then
		val="${!var}"
	elif [ "${!fileVar:-}" ]; then
		val="$(< "${!fileVar}")"
	fi
	export "$var"="$val"
	unset "$fileVar"
}

# set MARIADB_xyz from MYSQL_xyz when MARIADB_xyz is unset
# and make them the same value (so user scripts can use either)
_mariadb_file_env() {
	local var="$1"; shift
	local maria="MARIADB_${var#MYSQL_}"
	file_env "$var" "$@"
	file_env "$maria" "${!var}"
	if [ "${!maria:-}" ]; then
		export "$var"="${!maria}"
	fi
}

# check to see if this file is being run or sourced from another script
_is_sourced() {
	# https://unix.stackexchange.com/a/215279
	[ "${#FUNCNAME[@]}" -ge 2 ] \
		&& [ "${FUNCNAME[0]}" = '_is_sourced' ] \
		&& [ "${FUNCNAME[1]}" = 'source' ]
}

# usage: docker_process_init_files [file [file [...]]]
#    ie: docker_process_init_files /always-initdb.d/*
# process initializer files, based on file extensions
docker_process_init_files() {
	# mysql here for backwards compatibility "${mysql[@]}"
	# ShellCheck: mysql appears unused. Verify use (or export if used externally)
	# shellcheck disable=SC2034
	mysql=( docker_process_sql )

	echo
	local f
	for f; do
		case "$f" in
			*.sh)
				# https://github.com/docker-library/postgres/issues/450#issuecomment-393167936
				# https://github.com/docker-library/postgres/pull/452
				if [ -x "$f" ]; then
					mysql_note "$0: running $f"
					"$f"
				else
					mysql_note "$0: sourcing $f"
					# ShellCheck can't follow non-constant source. Use a directive to specify location.
					# shellcheck disable=SC1090
					. "$f"
				fi
				;;
			*.sql)     mysql_note "$0: running $f"; docker_process_sql < "$f"; echo ;;
			*.sql.gz)  mysql_note "$0: running $f"; gunzip -c "$f" | docker_process_sql; echo ;;
			*.sql.xz)  mysql_note "$0: running $f"; xzcat "$f" | docker_process_sql; echo ;;
			*.sql.zst) mysql_note "$0: running $f"; zstd -dc "$f" | docker_process_sql; echo ;;
			*)         mysql_warn "$0: ignoring $f" ;;
		esac
		echo
	done
}

# arguments necessary to run "mysqld --verbose --help" successfully (used for testing configuration validity and for extracting default/configured values)
_verboseHelpArgs=(
	--verbose --help
)

mysql_check_config() {
	local toRun=( "$@" "${_verboseHelpArgs[@]}" ) errors
	if ! errors="$("${toRun[@]}" 2>&1 >/dev/null)"; then
		mysql_error $'mysqld failed while attempting to check config\n\tcommand was: '"${toRun[*]}"$'\n\t'"$errors"
	fi
}

# Fetch value from server config
# We use mysqld --verbose --help instead of my_print_defaults because the
# latter only show values present in config files, and not server defaults
mysql_get_config() {
	local conf="$1"; shift
	"$@" "${_verboseHelpArgs[@]}" 2>/dev/null \
		| awk -v conf="$conf" '$1 == conf && /^[^ \t]/ { sub(/^[^ \t]+[ \t]+/, ""); print; exit }'
	# match "datadir      /some/path with/spaces in/it here" but not "--xyz=abc\n     datadir (xyz)"
}

# Do a temporary startup of the MariaDB server, for init purposes
docker_temp_server_start() {
	"$@" --skip-networking --default-time-zone=SYSTEM --socket="${SOCKET}" --wsrep_on=OFF \
		--expire-logs-days=0 \
		--loose-innodb_buffer_pool_load_at_startup=0 &
	declare -g MARIADB_PID
	MARIADB_PID=$!
	mysql_note "Waiting for server startup"
	# only use the root password if the database has already been initialized
	# so that it won't try to fill in a password file when it hasn't been set yet
	extraArgs=()
	if [ -z "$DATABASE_ALREADY_EXISTS" ]; then
		extraArgs+=( '--dont-use-mysql-root-password' )
	fi
	local i
	for i in {30..0}; do
		if docker_process_sql "${extraArgs[@]}" --database=mysql <<<'SELECT 1' &> /dev/null; then
			break
		fi
		sleep 1
	done
	if [ "$i" = 0 ]; then
		mysql_error "Unable to start server."
	fi
}

# Stop the server. When using a local socket file mysqladmin will block until
# the shutdown is complete.
docker_temp_server_stop() {
	kill "$MARIADB_PID"
	wait "$MARIADB_PID"
}

# Verify that the minimally required password settings are set for new databases.
docker_verify_minimum_env() {
	if [ -z "$MARIADB_ROOT_PASSWORD" ] && [ -z "$MARIADB_ROOT_PASSWORD_HASH" ] && [ -z "$MARIADB_ALLOW_EMPTY_ROOT_PASSWORD" ] && [ -z "$MARIADB_RANDOM_ROOT_PASSWORD" ]; then
		mysql_error $'Database is uninitialized and password option is not specified\n\tYou need to specify one of MARIADB_ROOT_PASSWORD, MARIADB_ROOT_PASSWORD_HASH, MARIADB_ALLOW_EMPTY_ROOT_PASSWORD and MARIADB_RANDOM_ROOT_PASSWORD'
	fi
	# More preemptive exclusions of combinations should have been made before *PASSWORD_HASH was added, but for now we don't enforce due to compatibility.
	if [ -n "$MARIADB_ROOT_PASSWORD" ] || [ -n "$MARIADB_ALLOW_EMPTY_ROOT_PASSWORD" ] || [ -n "$MARIADB_RANDOM_ROOT_PASSWORD" ] && [ -n "$MARIADB_ROOT_PASSWORD_HASH" ]; then
		mysql_error "Cannot specify MARIADB_ROOT_PASSWORD_HASH and another MARIADB_ROOT_PASSWORD* option."
	fi
	if [ -n "$MARIADB_PASSWORD" ] && [ -n "$MARIADB_PASSWORD_HASH" ]; then
		mysql_error "Cannot specify MARIADB_PASSWORD_HASH and MARIADB_PASSWORD option."
	fi
}

# creates folders for the database
# also ensures permission for user mysql of run as root
docker_create_db_directories() {
	local user; user="$(id -u)"

	# TODO other directories that are used by default? like /var/lib/mysql-files
	# see https://github.com/docker-library/mysql/issues/562
	mkdir -p "$DATADIR"

	if [ "$user" = "0" ]; then
		# this will cause less disk access than `chown -R`
		find "$DATADIR" \! -user mysql -exec chown mysql: '{}' +
		# See https://github.com/MariaDB/mariadb-docker/issues/363
		find "${SOCKET%/*}" -maxdepth 0 \! -user mysql -exec chown mysql: '{}' \;
	fi
}

_mariadb_version() {
        local mariaVersion="${MARIADB_VERSION##*:}"
        mariaVersion="${mariaVersion%%[-+~]*}"
	echo -n "${mariaVersion}-MariaDB"
}

# initializes the database directory
docker_init_database_dir() {
	mysql_note "Initializing database files"
	installArgs=( --datadir="$DATADIR" --rpm --auth-root-authentication-method=normal )
	# "Other options are passed to mysqld." (so we pass all "mysqld" arguments directly here)
	mysql_install_db "${installArgs[@]}" "${@:2}" \
		--skip-test-db \
		--old-mode='UTF8_IS_UTF8MB3' \
		--default-time-zone=SYSTEM --enforce-storage-engine= \
		--skip-log-bin \
		--expire-logs-days=0 \
		--loose-innodb_buffer_pool_load_at_startup=0 \
		--loose-innodb_buffer_pool_dump_at_shutdown=0
	mysql_note "Database files initialized"
}

# Loads various settings that are used elsewhere in the script
# This should be called after mysql_check_config, but before any other functions
docker_setup_env() {
	# Get config
	declare -g DATADIR SOCKET
	DATADIR="$(mysql_get_config 'datadir' "$@")"
	SOCKET="$(mysql_get_config 'socket' "$@")"


	# Initialize values that might be stored in a file
	_mariadb_file_env 'MYSQL_ROOT_HOST' '%'
	_mariadb_file_env 'MYSQL_DATABASE'
	_mariadb_file_env 'MYSQL_USER'
	_mariadb_file_env 'MYSQL_PASSWORD'
	_mariadb_file_env 'MYSQL_ROOT_PASSWORD'
	# No MYSQL_ compatibility needed for new variables
	file_env 'MARIADB_PASSWORD_HASH'
	file_env 'MARIADB_ROOT_PASSWORD_HASH'

	# set MARIADB_ from MYSQL_ when it is unset and then make them the same value
	: "${MARIADB_ALLOW_EMPTY_ROOT_PASSWORD:=${MYSQL_ALLOW_EMPTY_PASSWORD:-}}"
	export MYSQL_ALLOW_EMPTY_PASSWORD="$MARIADB_ALLOW_EMPTY_ROOT_PASSWORD" MARIADB_ALLOW_EMPTY_ROOT_PASSWORD
	: "${MARIADB_RANDOM_ROOT_PASSWORD:=${MYSQL_RANDOM_ROOT_PASSWORD:-}}"
	export MYSQL_RANDOM_ROOT_PASSWORD="$MARIADB_RANDOM_ROOT_PASSWORD" MARIADB_RANDOM_ROOT_PASSWORD
	: "${MARIADB_INITDB_SKIP_TZINFO:=${MYSQL_INITDB_SKIP_TZINFO:-}}"
	export MYSQL_INITDB_SKIP_TZINFO="$MARIADB_INITDB_SKIP_TZINFO" MARIADB_INITDB_SKIP_TZINFO

	declare -g DATABASE_ALREADY_EXISTS
	if [ -d "$DATADIR/mysql" ]; then
		DATABASE_ALREADY_EXISTS='true'
	fi
}

# Execute the client, use via docker_process_sql to handle root password
docker_exec_client() {
	# args sent in can override this db, since they will be later in the command
	if [ -n "$MYSQL_DATABASE" ]; then
		set -- --database="$MYSQL_DATABASE" "$@"
	fi
	mysql --protocol=socket -uroot -hlocalhost --socket="${SOCKET}" "$@"
}

# Execute sql script, passed via stdin
# usage: docker_process_sql [--dont-use-mysql-root-password] [mysql-cli-args]
#    ie: docker_process_sql --database=mydb <<<'INSERT ...'
#    ie: docker_process_sql --dont-use-mysql-root-password --database=mydb <my-file.sql
docker_process_sql() {
	if [ '--dont-use-mysql-root-password' = "$1" ]; then
		shift
		MYSQL_PWD='' docker_exec_client "$@"
	else
		MYSQL_PWD=$MARIADB_ROOT_PASSWORD docker_exec_client "$@"
	fi
}

# SQL escape the string $1 to be placed in a string literal.
# escape, \ followed by '
docker_sql_escape_string_literal() {
	local newline=$'\n'
	local escaped=${1//\\/\\\\}
	escaped="${escaped//$newline/\\n}"
	echo "${escaped//\'/\\\'}"
}

# Initializes database with timezone info and root password, plus optional extra db/user
docker_setup_db() {
	# Load timezone info into database
	if [ -z "$MARIADB_INITDB_SKIP_TZINFO" ]; then
		# --skip-write-binlog usefully disables binary logging
		# but also outputs LOCK TABLES to improve the IO of
		# Aria (MDEV-23326) for 10.4+.
		mysql_tzinfo_to_sql --skip-write-binlog /usr/share/zoneinfo \
			| docker_process_sql --dont-use-mysql-root-password --database=mysql
		# tell docker_process_sql to not use MYSQL_ROOT_PASSWORD since it is not set yet
	fi
	# Generate random root password
	if [ -n "$MARIADB_RANDOM_ROOT_PASSWORD" ]; then
		MARIADB_ROOT_PASSWORD="$(pwgen --numerals --capitalize --symbols --remove-chars="'\\" -1 32)"
		export MARIADB_ROOT_PASSWORD MYSQL_ROOT_PASSWORD=$MARIADB_ROOT_PASSWORD
		mysql_note "GENERATED ROOT PASSWORD: $MARIADB_ROOT_PASSWORD"
	fi

	# Creates root users for non-localhost hosts
	local rootCreate=
	local rootPasswordEscaped=
	if [ -n "$MARIADB_ROOT_PASSWORD" ]; then
		# Sets root password and creates root users for non-localhost hosts
		rootPasswordEscaped=$( docker_sql_escape_string_literal "${MARIADB_ROOT_PASSWORD}" )
	fi

	# default root to listen for connections from anywhere
	if [ -n "$MARIADB_ROOT_HOST" ] && [ "$MARIADB_ROOT_HOST" != 'localhost' ]; then
		# ref "read -d ''", no, we don't care if read finds a terminating character in this heredoc
		# https://unix.stackexchange.com/questions/265149/why-is-set-o-errexit-breaking-this-read-heredoc-expression/265151#265151
		if [ -n "$MARIADB_ROOT_PASSWORD_HASH" ]; then
			read -r -d '' rootCreate <<-EOSQL || true
				CREATE USER 'root'@'${MARIADB_ROOT_HOST}' IDENTIFIED BY PASSWORD '${MARIADB_ROOT_PASSWORD_HASH}' ;
				GRANT ALL ON *.* TO 'root'@'${MARIADB_ROOT_HOST}' WITH GRANT OPTION ;
			EOSQL
		else
			read -r -d '' rootCreate <<-EOSQL || true
				CREATE USER 'root'@'${MARIADB_ROOT_HOST}' IDENTIFIED BY '${rootPasswordEscaped}' ;
				GRANT ALL ON *.* TO 'root'@'${MARIADB_ROOT_HOST}' WITH GRANT OPTION ;
			EOSQL
		fi
	fi

	local mysqlAtLocalhost=
	local mysqlAtLocalhostGrants=
	# Install mysql@localhost user
	if [ -n "$MARIADB_MYSQL_LOCALHOST_USER" ]; then
		local pw=
		pw="$(pwgen --numerals --capitalize --symbols --remove-chars="'\\" -1 32)"
		# MDEV-24111 before MariaDB-10.4 cannot create unix_socket user directly auth with simple_password_check
		# It wasn't until 10.4 that the unix_socket auth was built in to the server.
		read -r -d '' mysqlAtLocalhost <<-EOSQL || true
		EXECUTE IMMEDIATE IF(VERSION() RLIKE '^10\.3\.',
			"INSTALL PLUGIN /*M10401 IF NOT EXISTS */ unix_socket SONAME 'auth_socket'",
			"SELECT 'already there'");
		CREATE USER mysql@localhost IDENTIFIED BY '$pw';
		ALTER USER mysql@localhost IDENTIFIED VIA unix_socket;
		EOSQL
		if [ -n "$MARIADB_MYSQL_LOCALHOST_GRANTS" ]; then
			if [ "$MARIADB_MYSQL_LOCALHOST_GRANTS" != USAGE ]; then
				mysql_warn "Excessive privileges ON *.* TO mysql@localhost facilitates risks to the confidentiality, integrity and availability of data stored"
			fi
			mysqlAtLocalhostGrants="GRANT ${MARIADB_MYSQL_LOCALHOST_GRANTS} ON *.* TO mysql@localhost;";
		fi
	fi

	local rootLocalhostPass=
	if [ -z "$MARIADB_ROOT_PASSWORD_HASH" ]; then
		# handle MARIADB_ROOT_PASSWORD_HASH for root@localhost after /docker-entrypoint-initdb.d
		rootLocalhostPass="SET PASSWORD FOR 'root'@'localhost'= PASSWORD('${rootPasswordEscaped}');"
	fi

	local createDatabase=
	# Creates a custom database and user if specified
	if [ -n "$MARIADB_DATABASE" ]; then
		mysql_note "Creating database ${MARIADB_DATABASE}"
		createDatabase="CREATE DATABASE IF NOT EXISTS \`$MARIADB_DATABASE\`;"
	fi

	local createUser=
	local userGrants=
	if  [ -n "$MARIADB_PASSWORD" ] || [ -n "$MARIADB_PASSWORD_HASH" ] && [ -n "$MARIADB_USER" ]; then
		mysql_note "Creating user ${MARIADB_USER}"
		if [ -n "$MARIADB_PASSWORD_HASH" ]; then
			createUser="CREATE USER '$MARIADB_USER'@'%' IDENTIFIED BY PASSWORD '$MARIADB_PASSWORD_HASH';"
		else
			# SQL escape the user password, \ followed by '
			local userPasswordEscaped
			userPasswordEscaped=$( docker_sql_escape_string_literal "${MARIADB_PASSWORD}" )
			createUser="CREATE USER '$MARIADB_USER'@'%' IDENTIFIED BY '$userPasswordEscaped';"
		fi

		if [ -n "$MARIADB_DATABASE" ]; then
			mysql_note "Giving user ${MARIADB_USER} access to schema ${MARIADB_DATABASE}"
			userGrants="GRANT ALL ON \`${MARIADB_DATABASE//_/\\_}\`.* TO '$MARIADB_USER'@'%';"
		fi
	fi

	mysql_note "Securing system users (equivalent to running mysql_secure_installation)"
	# tell docker_process_sql to not use MARIADB_ROOT_PASSWORD since it is just now being set
	# --binary-mode to save us from the semi-mad users go out of their way to confuse the encoding.
	docker_process_sql --dont-use-mysql-root-password --database=mysql --binary-mode <<-EOSQL
		-- Securing system users shouldn't be replicated
		SET @orig_sql_log_bin= @@SESSION.SQL_LOG_BIN;
		SET @@SESSION.SQL_LOG_BIN=0;
                -- we need the SQL_MODE NO_BACKSLASH_ESCAPES mode to be clear for the password to be set
		SET @@SESSION.SQL_MODE=REPLACE(@@SESSION.SQL_MODE, 'NO_BACKSLASH_ESCAPES', '');

		DROP USER IF EXISTS root@'127.0.0.1', root@'::1';
		EXECUTE IMMEDIATE CONCAT('DROP USER IF EXISTS root@\'', @@hostname,'\'');

		${rootLocalhostPass}
		${rootCreate}
		${mysqlAtLocalhost}
		${mysqlAtLocalhostGrants}
		-- pre-10.3 only
		DROP DATABASE IF EXISTS test ;
		-- end of securing system users, rest of init now...
		SET @@SESSION.SQL_LOG_BIN=@orig_sql_log_bin;
		-- create users/databases
		${createDatabase}
		${createUser}
		${userGrants}
	EOSQL
}

# backup the mysql database
docker_mariadb_backup_system()
{
	if [ -n "$MARIADB_DISABLE_UPGRADE_BACKUP" ] \
		&& [ "$MARIADB_DISABLE_UPGRADE_BACKUP" = 1 ]; then
		mysql_note "MariaDB upgrade backup disabled due to \$MARIADB_DISABLE_UPGRADE_BACKUP=1 setting"
		return
	fi
	local backup_db="system_mysql_backup_unknown_version.sql.zst"
	local oldfullversion="unknown_version"
	if [ -r "$DATADIR"/mysql_upgrade_info ]; then
		read -r -d '' oldfullversion < "$DATADIR"/mysql_upgrade_info || true
		if [ -n "$oldfullversion" ]; then
			backup_db="system_mysql_backup_${oldfullversion}.sql.zst"
		fi
	fi

	mysql_note "Backing up system database to $backup_db"
	if ! mysqldump --skip-lock-tables --replace --databases mysql --socket="${SOCKET}" | zstd > "${DATADIR}/${backup_db}"; then
		mysql_error "Unable backup system database for upgrade from $oldfullversion."
	fi
	mysql_note "Backing up complete"
}

# perform mariadb-upgrade
# backup the mysql database if this is a major upgrade
docker_mariadb_upgrade() {
	if [ -z "$MARIADB_AUTO_UPGRADE" ] \
		|| [ "$MARIADB_AUTO_UPGRADE" = 0 ]; then
		mysql_note "MariaDB upgrade (mysql_upgrade) required, but skipped due to \$MARIADB_AUTO_UPGRADE setting"
		return
	fi
	mysql_note "Starting temporary server"
	docker_temp_server_start "$@" --skip-grant-tables \
		--loose-innodb_buffer_pool_dump_at_shutdown=0 \
		--skip-slave-start
	mysql_note "Temporary server started."

	docker_mariadb_backup_system

	mysql_note "Starting mariadb-upgrade"
	mysql_upgrade --upgrade-system-tables
	mysql_note "Finished mariadb-upgrade"

	mysql_note "Stopping temporary server"
	docker_temp_server_stop
	mysql_note "Temporary server stopped"
}


_check_if_upgrade_is_needed() {
	if [ ! -f "$DATADIR"/mysql_upgrade_info ]; then
		mysql_note "MariaDB upgrade information missing, assuming required"
		return 0
	fi
	local mariadbVersion
	mariadbVersion="$(_mariadb_version)"
	IFS='.-' read -ra newversion <<<"$mariadbVersion"
	IFS='.-' read -ra oldversion < "$DATADIR"/mysql_upgrade_info || true

	if [[ ${#newversion[@]} -lt 2 ]] || [[ ${#oldversion[@]} -lt 2 ]] \
		|| [[ ${oldversion[0]} -lt ${newversion[0]} ]] \
		|| [[ ${oldversion[0]} -eq ${newversion[0]} && ${oldversion[1]} -lt ${newversion[1]} ]]; then
		return 0
	fi
	mysql_note "MariaDB upgrade not required"
	return 1
}

# check arguments for an option that would cause mysqld to stop
# return true if there is one
_mysql_want_help() {
	local arg
	for arg; do
		case "$arg" in
			-'?'|--help|--print-defaults|-V|--version)
				return 0
				;;
		esac
	done
	return 1
}

_main() {
	# if command starts with an option, prepend mysqld
	if [ "${1:0:1}" = '-' ]; then
		set -- mysqld "$@"
	fi

	#ENDOFSUBSTITUTIONS
	# skip setup if they aren't running mysqld or want an option that stops mysqld
	if [ "$1" = 'mariadbd' ] || [ "$1" = 'mysqld' ] && ! _mysql_want_help "$@"; then
		mysql_note "Entrypoint script for MariaDB Server ${MARIADB_VERSION} started."

		mysql_check_config "$@"
		# Load various environment variables
		docker_setup_env "$@"
		docker_create_db_directories

		# If container is started as root user, restart as dedicated mysql user
		if [ "$(id -u)" = "0" ]; then
			mysql_note "Switching to dedicated user 'mysql'"
			exec gosu mysql "${BASH_SOURCE[0]}" "$@"
		fi

		# there's no database, so it needs to be initialized
		if [ -z "$DATABASE_ALREADY_EXISTS" ]; then
			docker_verify_minimum_env

			# check dir permissions to reduce likelihood of half-initialized database
			ls /docker-entrypoint-initdb.d/ > /dev/null

			docker_init_database_dir "$@"

			mysql_note "Starting temporary server"
			docker_temp_server_start "$@"
			mysql_note "Temporary server started."

			docker_setup_db
			docker_process_init_files /docker-entrypoint-initdb.d/*
			# Wait until after /docker-entrypoint-initdb.d is performed before setting
			# root@localhost password to a hash we don't know the password for.
			if [ -n "${MARIADB_ROOT_PASSWORD_HASH}" ]; then
				mysql_note "Setting root@localhost password hash"
				docker_process_sql --dont-use-mysql-root-password --binary-mode <<-EOSQL
					SET @@SESSION.SQL_LOG_BIN=0;
					SET PASSWORD FOR 'root'@'localhost'= '${MARIADB_ROOT_PASSWORD_HASH}';
				EOSQL
			fi

			mysql_note "Stopping temporary server"
			docker_temp_server_stop
			mysql_note "Temporary server stopped"

			echo
			mysql_note "MariaDB init process done. Ready for start up."
			echo
		# MDEV-27636 mariadb_upgrade --check-if-upgrade-is-needed cannot be run offline
		#elif mysql_upgrade --check-if-upgrade-is-needed; then
		elif _check_if_upgrade_is_needed; then
			docker_mariadb_upgrade "$@"
		fi
	fi
	exec "$@"
}

# If we are sourced from elsewhere, don't perform any further actions
if ! _is_sourced; then
	_main "$@"
fi