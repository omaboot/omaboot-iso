# OmaBoot? images

The images of [OmaBoot?](https://omaboot.live), a comprehensive Intel Mac test suite for Omarchy,
built from Omarchy's own ISO. **OmaBoot? Live** boots an Intel Mac from a USB stick, tests how
well Omarchy runs on it, and sends the report to [DoesItOmarchy.com](https://doesitomarchy.com).

This repository is a fork of [omacom/omarchy-iso](https://github.com/omacom/omarchy-iso): everything
OmaBoot? adds or changes sits on top of the commit the official Omarchy ISO was built from. The rest
of the repository, its root README included, is upstream's.

- **[builder/omaboot/](../builder/omaboot/)**: the tester image (the boot-live tester, its boot menu
  and splash, the signed BOOTLIVE hook, the patched applesmc and radeon modules).
- **[builder/omaboot/release/](../builder/omaboot/release/README.md)**: how a release is built.
  Every package is the official Omarchy ISO's own file (pinned by checksum), the image is
  smoke-tested in QEMU and compared with the official ISO file by file, and the checksums are
  signed with the release key.

## Releases

A `v<omarchy>-<n>` tag builds a release on GitHub's runners (`.github/workflows/release.yml`). The
images are downloaded from [omaboot.live](https://omaboot.live/download/), with how to verify them.

## Licence

MIT, as upstream's [LICENSE](../LICENSE). OmaBoot?'s changes are © The OmaBoot? authors
([builder/omaboot/LICENSE](../builder/omaboot/LICENSE)).
