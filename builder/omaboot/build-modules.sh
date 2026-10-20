#!/bin/bash
# OmaBoot? dev builds: patched kernel modules for the live system.
#
#   bash /builder/omaboot/build-modules.sh OFFLINE_MIRROR_DIR AIROOTFS_DIR
#
# Builds applesmc (container_of fix for the keyboard-backlight LED oops that t2linux patch 3001
# causes on pre-T2 Macs) and radeon (the iMac10,1 LVDS panel-clock fix) against the exact
# linux-t2 and linux-t2-headers packages this ISO ships, and installs them under
# /usr/lib/modules/$KVER/updates in the airootfs, where they win over the stock modules once the
# kernel package's depmod hook runs. Also lifts the live ISO's applesmc blacklist.
#
# Each module is first rebuilt unpatched and must match the shipped one (applesmc by srcversion,
# radeon's .text byte for byte); otherwise the build stops, so a source mismatch can't slip in.
#
# The live image (OMABOOT_FLAVOUR=live) also boots linux-omarchy, so it gets the same radeon fix
# for that kernel too. Its applesmc stays Omarchy's own: that's what an installed system runs.
#
# Cached (owner, 2026-10-12: faster dev builds): the result is kept in /var/cache/omaboot-modules
# (bin/omarchy-iso-make mounts it from the build box), keyed by the image type, the kernel and
# headers package files, this script and the patches. A build with the same key unpacks it instead
# of cloning and compiling: the stock-rebuild checks passed for those exact files when it was made.
set -euo pipefail
MIRROR=$1
AIROOTFS=$2
HERE=$(cd "$(dirname "$0")" && pwd)
# The archlinux/archlinux build container is minimal: modinfo (kmod), pahole and bc may be missing.
pacman --noconfirm -S --needed kmod pahole bc zstd >/dev/null
W=/tmp/omaboot-modules
rm -rf "$W"
mkdir -p "$W"
cd "$W"

pick() { # exactly one package file with this name (NAME-<version>)
	local f
	f=$(ls "$MIRROR"/"$1"-[0-9]*.pkg.tar.zst 2>/dev/null || true)
	[ "$(echo "$f" | grep -c .)" = 1 ] || { echo "omaboot-modules: expected one $1 package in the mirror, found: $f" >&2; exit 1; }
	echo "$f"
}
KPKG=$(pick linux-t2)
HPKG=$(pick linux-t2-headers)
KEYFILES=("$KPKG" "$HPKG")
if [ "${OMABOOT_FLAVOUR:-omarchy}" = live ]; then
	OKPKG=$(pick linux-omarchy)
	OHPKG=$(pick linux-omarchy-headers)
	KEYFILES+=("$OKPKG" "$OHPKG")
fi
CACHE=/var/cache/omaboot-modules
KEY=$({
	echo "${OMABOOT_FLAVOUR:-omarchy}"
	for f in "${KEYFILES[@]}"; do basename "$f"; done
	cat "$HERE/build-modules.sh" "$HERE"/patches/*
} | sha256sum | cut -c1-16)
if [ -f "$CACHE/$KEY.tar" ]; then
	tar -xf "$CACHE/$KEY.tar" -C "$AIROOTFS"
	rm -f "$AIROOTFS/etc/modprobe.d/blacklist-applesmc.conf"
	echo "omaboot-modules: cached build $KEY (same kernel packages, script and patches)"
	cat "$AIROOTFS/usr/share/omaboot/modules.txt"
	exit 0
fi
mkdir -p headers shipped
tar --zstd -xf "$HPKG" -C headers
KVER=$(ls headers/usr/lib/modules)
H=$W/headers/usr/lib/modules/$KVER/build
tar --zstd -xf "$KPKG" -C shipped "usr/lib/modules/$KVER/kernel/drivers/hwmon/applesmc.ko.zst" \
	"usr/lib/modules/$KVER/kernel/drivers/gpu/drm/radeon/radeon.ko.zst"
find shipped -name '*.zst' -exec zstd -q -d -f --rm {} \;
SH=$W/shipped/usr/lib/modules/$KVER/kernel/drivers
PKGVER=$(tar --zstd -xOf "$KPKG" .PKGINFO | sed -n 's/^pkgver = //p') # e.g. 7.2.9.arch1-1
TAG=v$(echo "${PKGVER%-*}" | sed 's/\.arch/-arch/')                   # e.g. v7.2.9-arch1
echo "omaboot-modules: kernel $KVER, package $PKGVER, Arch tag $TAG"

git clone -q --depth 1 --filter=blob:none --sparse --branch "$TAG" https://github.com/archlinux/linux.git ksrc
git -C ksrc sparse-checkout set drivers/gpu/drm/radeon drivers/hwmon
git clone -q https://github.com/t2linux/linux-t2-patches.git t2p

build() { make -s -j"$(nproc)" -C "${2:-$H}" M="$1" modules 2>&1 | grep -v -i 'BTF' || true; }

# applesmc: find the t2linux patch set this kernel was built with (newest first)
want=$(modinfo -F srcversion "$SH/hwmon/applesmc.ko")
T2=""
for c in $(git -C t2p log --format=%h -n 15 -- '300*.patch'); do
	rm -rf applesmc && mkdir applesmc && cp ksrc/drivers/hwmon/applesmc.c applesmc/
	git -C t2p checkout -q "$c"
	if (cd applesmc && for p in "$W"/t2p/300*.patch; do patch -s -p3 <"$p" >/dev/null 2>&1 || { echo "omaboot-modules:   $c: $(basename "$p") doesn't apply"; exit 1; }; done) &&
		echo 'obj-m := applesmc.o' >applesmc/Kbuild && build "$W/applesmc" | tail -3 &&
		got=$(modinfo -F srcversion applesmc/applesmc.ko 2>&1) && echo "omaboot-modules:   $c: srcversion $got" && [ "$got" = "$want" ]; then
		T2=$c
		break
	fi
done
[ -n "$T2" ] || { echo "omaboot-modules: no t2linux patch set reproduces the shipped applesmc ($want)" >&2; exit 1; }
echo "omaboot-modules: applesmc stock rebuild matches (t2linux $T2)"
(cd applesmc && rm -f ./*.o ./*.ko ./*.mod* .*.cmd Module.symvers modules.order && patch -s -p3 <"$HERE/patches/0001-applesmc-led-container_of.patch")
build "$W/applesmc"

# radeon SRC_DIR HEADERS_BUILD SHIPPED_KO OUT: rebuild stock (must match SHIPPED_KO's .text), then
# with the iMac10,1 panel fix, into OUT/radeon.ko
radeon() {
	local src=$1 h=$2 shipped=$3 out=$4
	cp "$src/radeon_trace.h" "$h/drivers/gpu/drm/radeon/" # it includes itself by a tree-relative path
	rm -rf "$out" && cp -r "$src" "$out"
	build "$out" "$h"
	cmp -s <(objcopy -O binary --only-section=.text "$out/radeon.ko" /dev/stdout) \
		<(objcopy -O binary --only-section=.text "$shipped" /dev/stdout) ||
		{ echo "omaboot-modules: stock radeon rebuild differs from the shipped module ($shipped)" >&2; exit 1; }
	echo "omaboot-modules: radeon stock rebuild matches ($shipped)"
	rm -rf "$out" && cp -r "$src" "$out"
	(cd "$out" && sed -n '/^--- a\//,$p' "$HERE/patches/0002-radeon-imac10-1-panel-clock.patch" | patch -s -p5)
	build "$out" "$h"
}

# radeon: no t2linux patches touch it
radeon ksrc/drivers/gpu/drm/radeon "$H" "$SH/gpu/drm/radeon/radeon.ko" "$W/radeon"

U=$AIROOTFS/usr/lib/modules/$KVER/updates
mkdir -p "$U"
for m in applesmc/applesmc.ko radeon/radeon.ko; do
	objcopy --strip-debug "$m" "$U/$(basename "$m")"
	zstd -q -f --rm "$U/$(basename "$m")"
done
rm -f "$AIROOTFS/etc/modprobe.d/blacklist-applesmc.conf"
mkdir -p "$AIROOTFS/usr/share/omaboot"
{
	echo "kernel=$KVER"
	echo "linux_t2=$PKGVER"
	echo "arch_tag=$TAG"
	echo "t2linux_patches=$T2"
	echo "applesmc=updates/applesmc.ko.zst (+ 0001-applesmc-led-container_of.patch; blacklist removed)"
	echo "radeon=updates/radeon.ko.zst (+ 0002-radeon-imac10-1-panel-clock.patch)"
	(cd "$U" && sha256sum ./*.ko.zst)
} >"$AIROOTFS/usr/share/omaboot/modules.txt"

if [ "${OMABOOT_FLAVOUR:-omarchy}" = live ]; then
	# linux-omarchy: a kernel.org stable tarball plus Omarchy's patches (omacom/omarchy-pkgs
	# pkgbuilds/linux-omarchy), none of which touch radeon as of 7.2.5-3; if one ever does, the stock
	# rebuild check stops the build.
	mkdir -p oheaders oshipped
	tar --zstd -xf "$OHPKG" -C oheaders
	OKVER=$(ls oheaders/usr/lib/modules)
	OH=$W/oheaders/usr/lib/modules/$OKVER/build
	tar --zstd -xf "$OKPKG" -C oshipped "usr/lib/modules/$OKVER/kernel/drivers/gpu/drm/radeon/radeon.ko.zst"
	find oshipped -name '*.zst' -exec zstd -q -d -f --rm {} \;
	OPKGVER=$(tar --zstd -xOf "$OKPKG" .PKGINFO | sed -n 's/^pkgver = //p') # e.g. 7.2.5-3
	OTAG=v${OPKGVER%-*}
	echo "omaboot-modules: kernel $OKVER, package linux-omarchy $OPKGVER, stable tag $OTAG"
	git clone -q --depth 1 --filter=blob:none --sparse --branch "$OTAG" \
		https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git oksrc ||
		{ rm -rf oksrc && git clone -q --depth 1 --filter=blob:none --sparse --branch "$OTAG" https://github.com/gregkh/linux.git oksrc; }
	git -C oksrc sparse-checkout set drivers/gpu/drm/radeon
	radeon oksrc/drivers/gpu/drm/radeon "$OH" "$W/oshipped/usr/lib/modules/$OKVER/kernel/drivers/gpu/drm/radeon/radeon.ko" "$W/oradeon"
	OU=$AIROOTFS/usr/lib/modules/$OKVER/updates
	mkdir -p "$OU"
	objcopy --strip-debug oradeon/radeon.ko "$OU/radeon.ko"
	zstd -q -f --rm "$OU/radeon.ko"
	{
		echo "kernel=$OKVER"
		echo "linux_omarchy=$OPKGVER"
		echo "stable_tag=$OTAG"
		echo "radeon=updates/radeon.ko.zst (+ 0002-radeon-imac10-1-panel-clock.patch)"
		(cd "$OU" && sha256sum ./*.ko.zst)
	} >>"$AIROOTFS/usr/share/omaboot/modules.txt"
fi
cat "$AIROOTFS/usr/share/omaboot/modules.txt"

if [ -d "$CACHE" ]; then # keep it for the next build with the same key; the newest 4 stay
	saved=(usr/share/omaboot/modules.txt "usr/lib/modules/$KVER/updates")
	[ "${OMABOOT_FLAVOUR:-omarchy}" = live ] && saved+=("usr/lib/modules/$OKVER/updates")
	tar -cf "$CACHE/$KEY.tar.part" -C "$AIROOTFS" "${saved[@]}"
	mv "$CACHE/$KEY.tar.part" "$CACHE/$KEY.tar"
	ls -t "$CACHE"/*.tar | tail -n +5 | xargs -r rm -f
	echo "omaboot-modules: cached as $KEY"
fi
