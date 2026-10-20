#!/bin/bash
# chunk-manifest.sh SFS: write SFS's checksum list next to it, as airootfs.chunks (for
# airootfs.sfs), for boot-live's USB port tests: they read the OmaBoot? stick raw, wherever it is
# plugged in, and check what comes back against this list (boot-live internal/handson/diskread.go).
#
# build-iso.sh runs it from inside mkarchiso, right after mkarchiso writes airootfs.sfs and its
# airootfs.sha512 and before the ISO is mastered, so the list sits in the ISO at
# arch/x86_64/airootfs.chunks.
#
# Format (plain text, version 1): '#' lines are comments; then
#   omaboot-chunks 1
#   file airootfs.sfs
#   size <the file's size in bytes>
#   chunk 1048576
#   <index from 0> <sha256 of that 1 MiB chunk of the file, lower-case hex>
# one line per whole chunk of the file's first 64 MiB (fewer for a smaller file).
set -euo pipefail

sfs=$1
if [[ ! -f $sfs ]]; then
  echo "chunk-manifest: no $sfs (an erofs image?): no checksum list, boot-live reads the stick twice instead" >&2
  exit 0
fi
chunk=1048576
size=$(stat -c %s "$sfs")
n=$((size / chunk))
((n > 64)) && n=64
out="${sfs%.sfs}.chunks"
{
  echo "# OmaBoot? checksum list: sha256 of each 1 MiB chunk of airootfs.sfs's first 64 MiB (boot-live's USB read)"
  echo "omaboot-chunks 1"
  echo "file $(basename "$sfs")"
  echo "size $size"
  echo "chunk $chunk"
  for ((i = 0; i < n; i++)); do
    sum=$(dd if="$sfs" bs="$chunk" skip="$i" count=1 status=none | sha256sum)
    echo "$i ${sum%% *}"
  done
} >"$out"
echo "chunk-manifest: $out ($n chunks of $(basename "$sfs"), $size bytes)"
