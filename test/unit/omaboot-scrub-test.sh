#!/bin/bash
#
# The scrub check (builder/omaboot/tools/scrub-check.sh) over this fork: its generic part on what
# the fork changed since the official ISO's commit it's based on (OFFICIAL_ISO_COMMIT in the newest
# builder/omaboot/release/pins/*/pin.env; upstream's own files are upstream's), the maintainers'
# private patterns (when present) on everything. The dev-only files listed in
# builder/omaboot/private-only.txt, when it's there, are skipped.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT"

pin=$(printf '%s\n' builder/omaboot/release/pins/*/pin.env | sort -V | tail -n1)
base=${OMABOOT_UPSTREAM_BASE:-$(sed -n 's/^OFFICIAL_ISO_COMMIT=//p' "$pin")}
args=(-b "${base:?no OFFICIAL_ISO_COMMIT in $pin}")
[[ ! -f builder/omaboot/private-only.txt ]] || args+=(-x builder/omaboot/private-only.txt)

sh builder/omaboot/tools/scrub-check.sh "${args[@]}"
printf 'ok - scrub check\n'
