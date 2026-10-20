#!/bin/bash
# Checks a built live image's root file system (mkarchiso's work/x86_64/airootfs) for what the live
# edition's leave-outs must never take away, and fails the build when something's missing:
#
#   1. Mac firmware: for every PCI and USB ID in mac-hardware-ids.txt, the kernel modules that claim
#      it (each kernel's modules.alias), and every firmware file those modules ask for (modinfo).
#      None of those may be a file a package ships but noextract.conf left out. (Firmware no
#      package ships is missing from the official ISO too: not our concern here.)
#   2. The tester's programs: every program boot-live runs, and the helpers it needs.
#
#   check-live-image.sh IMAGE_ROOT
set -euo pipefail
root=${1:?usage: check-live-image.sh IMAGE_ROOT}
here=$(cd "$(dirname "$0")" && pwd)
fail=0

# ── 1. Mac firmware ─────────────────────────────────────────────────────────────
# The firmware files packages ship that aren't on disk: what NoExtract left out.
left_out=$(mktemp)
# (pacman prints each path with the image root in front: take it off; a failed query fails the build)
owned=$(pacman --root "$root" --dbpath "$root/var/lib/pacman" -Qlq)
fw_owned=$(sed "s|^${root%/}||" <<<"$owned" | awk '/^\/usr\/lib\/firmware\/.*[^\/]$/')
[[ -n $fw_owned ]] || { echo "check-live-image: no firmware files listed for the image's packages: can't check" >&2; exit 1; }
while read -r f; do [[ -e $root$f ]] || echo "$f"; done <<<"$fw_owned" | sort -u >"$left_out"
echo "firmware: $(wc -l <<<"$fw_owned") files in the packages, $(wc -l <"$left_out") left out"
if grep -q '^NoExtract.*usr/lib/firmware' "$root/etc/pacman.conf" 2>/dev/null && [[ ! -s $left_out ]]; then
  echo "check-live-image: the image's pacman.conf leaves firmware out, yet none is missing: the check isn't seeing it" >&2
  exit 1
fi

ids=$(grep -v '^#' "$here/mac-hardware-ids.txt")
# firmware-exceptions.txt: firmware a Mac's driver declares that no Mac's chip loads
mapfile -t exceptions < <(grep -v '^#' "$here/firmware-exceptions.txt" | cut -f1,2)
excepted() {
  local e
  for e in "${exceptions[@]}"; do
    # shellcheck disable=SC2053
    [[ ${e%%$'\t'*} == "$1" && $2 == ${e#*$'\t'} ]] && return 0
  done
  return 1
}
for kdir in "$root"/usr/lib/modules/*/; do
  kver=$(basename "$kdir")
  [[ -f $kdir/modules.alias ]] || continue
  # the modules whose aliases match a Mac's vendor and device (PCI) or vendor and product (USB);
  # a wildcard in the pattern matches anything, class-only aliases included
  mods=$(awk -v ids="$ids" '
    BEGIN { n = split(ids, a, "\n"); for (i = 1; i <= n; i++) { split(a[i], p, ":"); want[p[1] ":" toupper(p[2]) ":" toupper(p[3])] = 1 } }
    function re(s) { gsub(/\*/, ".*", s); return "^" s "$" }
    $1 == "alias" && $2 ~ /^pci:v/ {
      if (!match($2, /^pci:v([0-9A-F*]+)d([0-9A-F*]+)sv/, m)) next
      for (k in want) { split(k, w, ":"); if (w[1] != "pci") continue
        if (("0000" w[2]) ~ re(m[1]) && ("0000" w[3]) ~ re(m[2])) { print $3; break } }
    }
    $1 == "alias" && $2 ~ /^usb:v/ {
      if (!match($2, /^usb:v([0-9A-F*]+)p([0-9A-F*]+)d/, m)) next
      for (k in want) { split(k, w, ":"); if (w[1] != "usb") continue
        if (w[2] ~ re(m[1]) && w[3] ~ re(m[2])) { print $3; break } }
    }' "$kdir/modules.alias" | tr '-' '_' | sort -u)
  missing=0 checked=0 excused=0
  for mod in $mods; do
    while read -r fw; do
      [[ -n $fw ]] || continue
      checked=$((checked + 1))
      if excepted "$mod" "$fw"; then excused=$((excused + 1)); continue; fi
      for f in "/usr/lib/firmware/$fw" "/usr/lib/firmware/$fw.zst" "/usr/lib/firmware/$fw.xz"; do
        if grep -qxF "$f" "$left_out"; then
          echo "MISSING: $kver: $mod needs $f, left out by noextract.conf" >&2
          missing=$((missing + 1)) fail=1
        fi
      done
    done < <(modinfo -b "$root" -k "$kver" -F firmware "$mod" 2>/dev/null)
  done
  echo "$kver: $(wc -w <<<"$mods") modules for the Macs' hardware, $checked firmware files they ask for, $excused not for a Mac's chip (firmware-exceptions.txt), $missing missing"
done
rm -f "$left_out"

# ── 2. The tester's programs ────────────────────────────────────────────────────
# Every program boot-live runs (exec.Command in its source) and what its tests rely on.
for p in amixer aplay arecord journalctl losetup mkfs.fat mount umount networkctl partx setfont sync \
  systemctl udevadm poweroff reboot eglinfo usbmuxd iwctl loadkeys dumpkeys; do
  if ! [[ -x $root/usr/bin/$p || -x $root/usr/sbin/$p ]]; then
    echo "MISSING: the tester runs $p, which isn't in the image" >&2
    fail=1
  fi
done
[[ -x $root/usr/lib/omaboot/egl-probe ]] || { echo "MISSING: /usr/lib/omaboot/egl-probe" >&2; fail=1; }

if ((fail)); then
  echo "check-live-image: the live edition left out something a Mac or the tester needs" >&2
  exit 1
fi
echo "check-live-image: Mac firmware and the tester's programs are all there"
