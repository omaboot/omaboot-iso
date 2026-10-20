#!/bin/bash
#
# OmaBoot?: our GRUB menu, spliced into upstream's configs/grub/grub.cfg at build time, so that
# file stays upstream's own. Two parts of it are replaced, each with a file of ours:
#
#   the serial console block  ->  builder/omaboot/grub-head.cfg (our palette, font and wordmark;
#                                 the serial console skipped on EFI, where Macs have no com0)
#   the default entry and the menu entries, up to the Memtest86+ entries
#                             ->  builder/omaboot/grub-installer-entries.cfg (omarchy, omarchy-lite)
#                                 builder/omaboot/grub-live-entries.cfg (live)
#
# Everything else (modules, fonts, the platform name, Memtest86+, UEFI shell and firmware
# settings, shutdown, restart) is upstream's as it stands. Each replaced part must still read as
# it did when our file was made from it (the checksums below): when upstream changes one, the
# build stops here instead of dropping the change unseen. Carry the change over into our file,
# then put the new checksum (printed) below.
#
# Usage: grub-splice.sh GRUB_CFG FLAVOUR   (writes the result to stdout)

set -euo pipefail

# sha256 of upstream's parts as our files were made from them (omarchy-iso fd1c9a5; its arm64
# entries and %KERNEL%/%KERNEL_OPTIONS% placeholders give x86_64 the same linux-t2 entries as 7cfb711)
serial_sum=8e658d0ff7b7c0a5c819451aaf85613e6582fabd05472e42836b3bdd1ac1f2cd
menu_sum=31fc5946f6e134b835e81960c4d5b72989283de219e10c364915cac8e138446c

cfg=$1
flavour=$2
here=$(cd "$(dirname "$0")/.." && pwd)
case $flavour in
  omarchy | omarchy-lite) entries=$here/grub-installer-entries.cfg ;;
  live) entries=$here/grub-live-entries.cfg ;;
  *) echo "grub-splice: no GRUB menu for image type '$flavour'" >&2 && exit 1 ;;
esac

serial_start='# Enable serial console'
serial_end='# Get a human readable platform identifier'
menu_start='# Set default menu entry'
menu_end="if [ \"\${grub_platform}\" == 'efi' -a \"\${grub_cpu}\" == 'x86_64' -a -f '/boot/memtest86+/memtest.efi' ]; then"

# The lines from START up to (not including) END; empty unless each is there exactly once, in order.
part() {
  awk -v start="$2" -v end="$3" '
    $0 == start { starts++; on = 1 }
    $0 == end { ends++; if (on) done = 1; on = 0 }
    on { text = text $0 "\n" }
    END { if (starts == 1 && ends == 1 && done) printf "%s", text }
  ' "$1"
}

check() { # check NAME START END SUM
  local text sum
  text=$(part "$cfg" "$2" "$3"; echo .)
  text=${text%.}
  if [[ -z $text ]]; then
    echo "grub-splice: upstream's grub.cfg no longer has its $1 where OmaBoot? replaces it ('$2' up to '$3')" >&2
    exit 1
  fi
  sum=$(printf '%s' "$text" | sha256sum | cut -d' ' -f1)
  if [[ $sum != "$4" ]]; then
    echo "grub-splice: upstream changed its $1 in grub.cfg, the part OmaBoot? replaces" >&2
    echo "  Carry the change over into builder/omaboot/grub-*.cfg, then set its checksum in grub-splice.sh to $sum" >&2
    exit 1
  fi
}
check "serial console block" "$serial_start" "$serial_end" "$serial_sum"
check "menu entries" "$menu_start" "$menu_end" "$menu_sum"

awk -v serial_start="$serial_start" -v serial_end="$serial_end" -v menu_start="$menu_start" \
  -v menu_end="$menu_end" -v head="$here/grub-head.cfg" -v entries="$entries" '
  function insert(file, line) { while ((getline line < file) > 0) print line; close(file) }
  $0 == serial_start { insert(head); skip = 1; next }
  $0 == menu_start { insert(entries); skip = 1; next }
  $0 == serial_end || $0 == menu_end { skip = 0 }
  !skip { print }
' "$cfg"
