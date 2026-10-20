#!/bin/bash
# Check an OmaBoot? release: SHA256SUMS.sig must be an SSH signature (namespace omaboot-release) by the
# release key or its offline backup (builder/omaboot/keys), then every file SHA256SUMS lists that is
# in the folder must match it. With --all, every listed file must be there.
#   verify-sums.sh [--all] DIR
#   verify-sums.sh --signers > allowed_signers     (the file people verify a download with)
set -euo pipefail
keys=$(cd "$(dirname "$0")/../keys" && pwd)
signers() {
  local k t b
  for k in omaboot-release omaboot-release-backup; do
    read -r t b _ <"$keys/$k.pub"
    printf 'omaboot namespaces="omaboot-release" %s %s %s\n' "$t" "$b" "$k"
  done
}
if [[ ${1:-} == --signers ]]; then
  signers
  exit 0
fi
all=no
[[ ${1:-} == --all ]] && { all=yes; shift; }
dir=${1:?usage: verify-sums.sh [--all] DIR | --signers}
[[ -f $dir/SHA256SUMS && -f $dir/SHA256SUMS.sig ]] || { echo "verify-sums: $dir needs SHA256SUMS and SHA256SUMS.sig" >&2; exit 1; }
allowed=$(mktemp)
signers >"$allowed"
ssh-keygen -Y verify -f "$allowed" -I omaboot -n omaboot-release -s "$dir/SHA256SUMS.sig" <"$dir/SHA256SUMS"
if [[ $all == yes ]]; then
  (cd "$dir" && sha256sum --strict -c SHA256SUMS)
else
  (cd "$dir" && sha256sum --strict -c --ignore-missing SHA256SUMS)
fi
