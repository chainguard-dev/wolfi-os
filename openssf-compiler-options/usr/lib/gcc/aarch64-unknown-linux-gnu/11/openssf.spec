*self_spec:
+ %{!O:%{!O1:%{!O2:%{!O3:%{!O0:%{!Os:%{!0fast:%{!0g:%{!0z:-O2}}}}}}}}} -Wl,--as-needed,-O1,--sort-common -Wl,-z,noexecstack -Wl,-z,relro -Wl,-z,now %{!fdelete-null-pointer-checks:-fno-delete-null-pointer-checks} -fno-strict-overflow -fno-strict-aliasing -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer -Wp,-D_FORTIFY_SOURCE=2 -Wp,-D_GLIBCXX_ASSERTIONS -mbranch-protection=standard -fstack-clash-protection -fstack-protector-strong
