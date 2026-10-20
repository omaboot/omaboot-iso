# OmaBoot? signing keys (public halves only)

The BOOTLIVE hook runs a tester from a stick only if its `manifest.sig` is a valid SSH signature
(`ssh-keygen -Y`, namespace `omaboot-bootlive`) by a key the ISO trusts. `builder/build-iso.sh`
writes the trusted keys to `/usr/share/omaboot/allowed_signers`:

| Build | `OMABOOT_SIGNERS` | Trusted keys |
|---|---|---|
| dev (default) | `dev` | `omaboot-dev` |
| release | `release` | `omaboot-release`, `omaboot-release-backup` |

- `omaboot-dev`: dev builds and test payloads only; never signs a release. Private half on the
  maintainer's laptop and on the dev build runner (`/etc/omaboot/omaboot-dev`).
- `omaboot-release`: lives in 1Password and signs through its SSH agent, with approval per signature.
- `omaboot-release-backup`: offline, on paper only. Used only if the release key is lost or
  compromised, to sign the release that ships a new key list.

Release checksums are signed by the release key in the separate namespace `omaboot-release`, so a
checksum signature can never pass as a stick manifest or the other way round.
