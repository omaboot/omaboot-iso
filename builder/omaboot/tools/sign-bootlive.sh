#!/bin/bash
# Sign a BOOTLIVE stick folder for omaboot-bootlive: write `manifest` (sha256 of every file except
# results/, the manifest and its signature) and `manifest.sig` (an SSH signature of the manifest,
# namespace omaboot-bootlive).
#   sign-bootlive.sh STICK_DIR KEY
# KEY is a private key file (dev: ~/.config/omaboot/omaboot-dev, or /etc/omaboot/omaboot-dev on
# the dev build runner), or a public key whose private half is in the SSH agent (release: the 1Password key,
# builder/omaboot/keys/omaboot-release.pub; 1Password asks for approval). See builder/omaboot/keys/.
set -euo pipefail
dir=$1
key=$(realpath -- "$2")
cd "$dir"
find . -type f ! -path './results/*' ! -name manifest ! -name manifest.sig -printf '%P\n' | LC_ALL=C sort |
  while read -r f; do sha256sum -- "$f"; done >manifest
rm -f manifest.sig
ssh-keygen -q -Y sign -f "$key" -n omaboot-bootlive manifest
echo "signed $(wc -l <manifest) files in $dir"
