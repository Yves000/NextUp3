# Vendored third-party code

These files are copied into the tree so the tweak builds without extra
submodules. They are **not** covered by this repository's GPL-3.0 license —
each remains under its original author's terms.

| Directory | Project | Author | Source |
|---|---|---|---|
| `LightMessaging/` | LightMessaging — header-only mach IPC for jailbroken iOS | Ryan Petrich | https://github.com/rpetrich/lightmessaging |
| `libSandy/` | libSandy public header (`libSandy.h`) | opa334 | https://github.com/opa334/libSandy |

The tweak links neither project as a binary: LightMessaging is header-only,
and libSandy is loaded at runtime via `dlopen` (the device installs
`com.opa334.libsandy` as a package dependency).
