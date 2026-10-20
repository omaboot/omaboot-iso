#!/bin/bash
# Writes builder/omaboot/live/mac-hardware-ids.txt: every PCI and USB ID DoesItOmarchy.com's catalog
# knows on Intel Macs (its components and the chipset plumbing seen on real Macs), for the live
# image's firmware check (check-live-image.sh). Re-run when the catalog gains IDs.
#   builder/omaboot/tools/mac-ids.sh DOESITOMARCHY_CHECKOUT
set -euo pipefail
src=${1:?usage: mac-ids.sh DOESITOMARCHY_CHECKOUT}
out=$(cd "$(dirname "$0")/../live" && pwd)/mac-hardware-ids.txt
{
  echo "# PCI and USB IDs on Intel Macs, from DoesItOmarchy.com's catalog (github.com/doesitomarchy/doesitomarchy,"
  echo "# data/components and data/plumbing.yaml, CC BY-SA 4.0) at $(git -C "$src" rev-parse --short=7 HEAD)."
  echo "# Made by builder/omaboot/tools/mac-ids.sh; don't edit by hand."
  grep -h -oE '(pci|usb):[0-9a-f]{4}:[0-9a-f]{4}' "$src"/data/components/*.yaml "$src"/data/plumbing.yaml | sort -u
} >"$out"
echo "$(grep -vc '^#' "$out") IDs in $out"
