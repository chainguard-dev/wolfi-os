USE_CACHE ?= yes
ARCH ?= $(shell uname -m)
ifeq (${ARCH}, arm64)
	ARCH = aarch64
endif
TARGETDIR = packages/${ARCH}

MELANGE ?= $(shell which melange)
WOLFICTL ?= $(shell which wolfictl)
KEY ?= local-melange.rsa
REPO ?= $(shell pwd)/packages
CACHE_DIR ?= gs://wolfi-sources/

WOLFI_SIGNING_PUBKEY ?= https://packages.wolfi.dev/os/wolfi-signing.rsa.pub
WOLFI_PROD ?= https://packages.wolfi.dev/os

MELANGE_OPTS += --repository-append ${REPO}
MELANGE_OPTS += --keyring-append ${KEY}.pub
MELANGE_OPTS += --signing-key ${KEY}
MELANGE_OPTS += --arch ${ARCH}
MELANGE_OPTS += --env-file build-${ARCH}.env
MELANGE_OPTS += --namespace wolfi
MELANGE_OPTS += --generate-index false
MELANGE_OPTS += --pipeline-dir ./pipelines/
MELANGE_OPTS += ${MELANGE_EXTRA_OPTS}

ifeq (${USE_CACHE}, yes)
	MELANGE_OPTS += --cache-source ${CACHE_DIR}
endif

ifeq (${BUILDWORLD}, no)
MELANGE_OPTS += -k ${WOLFI_SIGNING_PUBKEY}
MELANGE_OPTS += -r ${WOLFI_PROD}
endif

# The list of packages to be built. The order matters.
# wolfictl determines the list and order
# set only to be called when needed, so make can be instant to run
# when it is not
PKGLISTCMD ?= $(WOLFICTL) text --dir . --type name --pipeline-dir=./pipelines/

all: ${KEY} .build-packages
ifeq ($(MAKECMDGOALS),all)
  PKGLIST := $(addprefix package/,$(shell $(PKGLISTCMD)))
else
  PKGLIST :=
endif
.build-packages: $(PKGLIST)

${KEY}:
	${MELANGE} keygen ${KEY}

clean:
	rm -rf packages/${ARCH}

.PHONY: list list-yaml
list:
	$(info $(shell $(PKGLISTCMD)))
	@printf ''

list-yaml:
	$(info $(addsuffix .yaml,$(shell $(PKGLISTCMD))))
	@printf ''

package/%:
	$(eval yamlfile := $*.yaml)
	$(eval pkgver := $(shell $(MELANGE) package-version $(yamlfile)))
	$(MAKE) yamlfile=$(yamlfile) pkgname=$* packages/$(ARCH)/$(pkgver).apk

packages/$(ARCH)/%.apk: $(KEY)
	@mkdir -p ./$(pkgname)/
	$(eval SOURCE_DATE_EPOCH ?= $(shell git log -1 --pretty=%ct --follow $(yamlfile)))
	@SOURCE_DATE_EPOCH=$(SOURCE_DATE_EPOCH) $(MELANGE) build $(yamlfile) $(MELANGE_OPTS) --source-dir ./$(pkgname)/ --log-policy builtin:stderr,$(TARGETDIR)/buildlogs/$*.log

dev-container:
	docker run --privileged --rm -it \
	    -v "${PWD}:${PWD}" \
	    -w "${PWD}" \
	    -e SOURCE_DATE_EPOCH=0 \
	    ghcr.io/wolfi-dev/sdk:latest@sha256:a55fdbc2778d43134309dfdacb6dcd7d2ae44bff14f1a20a215308faf11dc200

PACKAGES_CONTAINER_FOLDER ?= /work/packages
TMP_REPOSITORIES_DIR := $(shell mktemp -d)
TMP_REPOSITORIES_FILE := $(TMP_REPOSITORIES_DIR)/repositories
local-wolfi:
	@echo "https://packages.wolfi.dev/os" > $(TMP_REPOSITORIES_FILE)
	@echo "$(PACKAGES_CONTAINER_FOLDER)" >> $(TMP_REPOSITORIES_FILE)
	docker run --rm -it \
		--mount type=bind,source="${PWD}/packages",destination="$(PACKAGES_CONTAINER_FOLDER)",readonly \
		--mount type=bind,source="${PWD}/local-melange.rsa.pub",destination="/etc/apk/keys/local-melange.rsa.pub",readonly \
		--mount type=bind,source="$(TMP_REPOSITORIES_FILE)",destination="/etc/apk/repositories",readonly \
		-w "$(PACKAGES_CONTAINER_FOLDER)" \
		cgr.dev/chainguard/wolfi-base:latest
	@rm "$(TMP_REPOSITORIES_FILE)"
	@rmdir "$(TMP_REPOSITORIES_DIR)"
