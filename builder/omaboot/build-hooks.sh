# shellcheck shell=bash disable=SC2034,SC2154 # build-iso.sh's variables, read and set here
#
# OmaBoot? build steps, called from upstream's builder/build-iso.sh at the lines marked
# "# omaboot hook". build-iso.sh sources this file; the functions run in its shell (set -e) and
# read and set its variables (build_cache_dir, offline_mirror_dir, arch_packages, all_packages,
# required_package_files). Keeping our steps here leaves build-iso.sh upstream's own but for those
# lines, so a rebase onto a newer upstream conflicts only there.
#
# The environment (bin/omarchy-iso-make passes it; builder/omaboot/make-hooks.sh adds ours):
#   OMABOOT_FLAVOUR  omarchy (the installer with the tester), omarchy-lite (dev only, no offline
#                    package mirror), live (the stand-alone tester); lab is planned
#   OMABOOT_SIGNERS  dev or release: the keys the BOOTLIVE hook trusts
#   OMABOOT_RELEASE  release builds: the Omarchy version whose official ISO the packages are pinned to
#   OMABOOT_PIN      pinned dev builds: the same pins with the dev keys
#   OMABOOT_TAG      release builds: the release's tag; OMABOOT_COMMIT dev builds: the commit

# The live image (OMABOOT_FLAVOUR=live): no installer, no offline mirror.
omaboot_live_image() {
  [[ ${OMABOOT_FLAVOUR:-omarchy} == live ]]
}

# Before the build container's packages. OmaBoot? release builds (OMABOOT_RELEASE=<Omarchy
# version>, builder/omaboot/release): every package pinned to the official Omarchy ISO of that
# release. Arch packages from the Arch Linux Archive day that holds all of the official ones (same
# checksums); Omarchy and arch-mact2 packages from repos made out of the official ISO itself
# (mounted at /pinned), since neither keeps a dated archive, and so are any Arch packages that day
# has newer builds of ([arch-held]). The build container's own tools
# (archiso, grub, ...) come from the archive day the official ISO was built on. Pinned dev builds
# (OMABOOT_PIN=<Omarchy version>, the dev workflow's "pinned" packages) use the same pins with the
# dev keys and their own report target: a dev stick on the release's package set.
omaboot_pins() {
  # The pacman config the build downloads packages with (pacman-online-<channel>.conf).
  online_conf=/configs/pacman-online-${OMARCHY_MIRROR}.conf
  OMABOOT_PIN=${OMABOOT_RELEASE:-${OMABOOT_PIN:-}}
  if [[ -z $OMABOOT_PIN ]]; then
    omaboot_mact2_first
    return 0
  fi
  pin_dir=/builder/omaboot/release/pins/$OMABOOT_PIN
  [[ -f $pin_dir/pin.env ]] || { echo "ERROR: no release pin for Omarchy $OMABOOT_PIN ($pin_dir)" >&2; exit 1; }
  # shellcheck disable=SC1091
  source "$pin_dir/pin.env"
  if [[ -n ${OMABOOT_RELEASE:-} ]]; then
    [[ ${OMABOOT_SIGNERS:-dev} == release ]] || { echo "ERROR: release builds trust the release keys only (OMABOOT_SIGNERS=release)" >&2; exit 1; }
    [[ ${OMABOOT_FLAVOUR:-} == live ]] || { echo "ERROR: release builds are live images for now (OMABOOT_FLAVOUR=live)" >&2; exit 1; }
  fi
  for repo in $PINNED_REPOS; do
    [[ -f /pinned/$repo/$repo.db.tar.gz ]] || { echo "ERROR: the pinned [$repo] repo isn't mounted at /pinned/$repo" >&2; exit 1; }
  done
  # The container's repos: its own archive day, then the image's (pacman -Sy with the release config
  # below leaves the image's day in the container's sync databases; later installs fetch from it).
  # shellcheck disable=SC2016 # $repo and $arch are pacman's
  printf 'Server = https://archive.archlinux.org/repos/%s/$repo/os/$arch\n' "$BUILD_ARCHIVE_DATE" "$ARCH_ARCHIVE_DATE" >/etc/pacman.d/mirrorlist
  online_conf=/tmp/pacman-online-release.conf
  {
    awk '/^\[/ { on = ($0 == "[options]") } on' /configs/pacman-online-stable.conf # [options], as the stable channel has it
    # Pacman takes a package from the first repo that has it, so the order matters where a name is in
    # two. [omarchy] first, as the official channel has it since 4.0.5 (upstream 3872d5a): Omarchy's
    # own builds win over Arch's (4.0.5's linux-firmware-cirrus 20260810-3 over core's 20260916-1).
    # Our [omarchy] keeps the older SigLevel: its files are checked against the pin by sha256.
    printf '[omarchy]\nSigLevel = Optional TrustAll\nServer = file:///pinned/omarchy\n\n'
    # Arch packages the archive day has newer builds of (Arch replaced them after the official ISO's
    # package snapshot): the ISO's own copies, ahead of core/extra/multilib. Arch-signed, so the
    # default SigLevel checks them.
    if [[ " $PINNED_REPOS " == *" arch-held "* ]]; then
      printf '[arch-held]\nServer = file:///pinned/arch-held\n\n'
    fi
    # The databases (what gets installed, and each file's checksum) and the package files come from
    # the archive day; pacman checks each file against the archive's checksum and its Arch
    # signature. Not Omarchy's stable mirror as a CacheServer: once it moves past the release's
    # snapshot it answers a missing .sig with an HTML page over pacman's 16 KiB signature limit,
    # and pacman fails the download instead of falling back to the archive.
    for repo in core extra multilib; do
      # shellcheck disable=SC2016 # $repo and $arch are pacman's
      printf '[%s]\nServer = https://archive.archlinux.org/repos/%s/$repo/os/$arch\n\n' "$repo" "$ARCH_ARCHIVE_DATE"
    done
    # the official channel's SigLevel for [arch-mact2]: Never
    printf '[arch-mact2]\nSigLevel = Never\nServer = file:///pinned/arch-mact2\n'
  } >"$online_conf"
  echo "OmaBoot? pinned build for Omarchy $OMARCHY_VERSION: Arch packages from the archive of $ARCH_ARCHIVE_DATE, build tools from $BUILD_ARCHIVE_DATE"
  cat "$online_conf"
  # Upstream's build reads its channel's config from /configs (read-only): the pinned config is
  # mounted over it for this container (it's privileged), so every package the build fetches comes
  # from the pins.
  mount --bind "$online_conf" "/configs/pacman-online-${OMARCHY_MIRROR}.conf"
  # (sha256sum: the bare container has no cmp yet)
  [[ $(sha256sum <"$online_conf") == "$(sha256sum <"/configs/pacman-online-${OMARCHY_MIRROR}.conf")" ]] || { echo "ERROR: the pinned pacman config didn't take the channel's place" >&2; exit 1; }
}

# Unpinned builds: arch-mact2's GitHub copy first. mirror.funami.tech served the build box at
# ~14 KB/s (2026-10-14). The channel's config gets the GitHub server at the top of its
# [arch-mact2] section, mounted over it like the pinned config above, so upstream's file stays
# as it is.
OMABOOT_MACT2_GITHUB=https://github.com/NoaHimesaka1873/arch-mact2-mirror/releases/download/release
omaboot_mact2_first() {
  local conf=/configs/pacman-online-${OMARCHY_MIRROR}.conf tmp=/tmp/pacman-online-mact2.conf
  grep -qx '\[arch-mact2\]' "$conf" || return 0
  awk -v gh="Server = $OMABOOT_MACT2_GITHUB" '
    /^\[/ { sec = $0 }
    sec == "[arch-mact2]" && $0 == gh { next }
    { print }
    $0 == "[arch-mact2]" { print gh }' "$conf" >"$tmp"
  mount --bind "$tmp" "$conf"
  [[ $(sha256sum <"$tmp") == "$(sha256sum <"$conf")" ]] || { echo "ERROR: the arch-mact2 mirror order didn't take the channel's place" >&2; exit 1; }
}

# After the offline mirror's package list (all_packages). The live image also has linux-omarchy,
# the kernel non-T2 Macs run once installed, so GRUB can boot each Mac with the kernel an install
# would give it (builder/omaboot/grub-live-entries.cfg); and Mesa, for GPU tests without the
# offline mirror. It leaves out the installer's tools and the rest of the rescue toolbox
# (builder/omaboot/live/leave-out.packages); pacman drops what only they needed. With no installer,
# its mirror only has to carry what mkarchiso installs into the image (packages.x86_64, with their
# dependencies) and the kernel headers build-modules.sh needs; the installer's ~1250-package set is
# neither downloaded nor indexed, which takes minutes off dev builds (owner, 2026-10-12).
omaboot_live_packages() {
  omaboot_live_image || return 0
  printf '%s\n' linux-omarchy mesa mesa-utils >>"$build_cache_dir/packages.x86_64"
  grep -vxF -f <(grep -v '^#' /builder/omaboot/live/leave-out.packages) "$build_cache_dir/packages.x86_64" >/tmp/packages.live
  mv /tmp/packages.live "$build_cache_dir/packages.x86_64"
  mapfile -t all_packages < <(
    {
      grep -hv '^#\|^$' "$build_cache_dir/packages.x86_64"
      printf '%s\n' linux-t2-headers linux-omarchy-headers
    } | sed -e 's/^broadcom-wl$/broadcom-wl-dkms/' | sort -u
  )
}

# Before the offline mirror is pruned and indexed. The live image indexes its smaller set in a
# directory of its own, links to the cached files, so the package cache the other image types
# share isn't pruned down to it: offline_mirror_dir points there from here on (upstream's prune
# finds nothing to drop among links, its repo-add indexes them, and the build's repo link points
# there). omaboot_package_cache keeps the cache's place.
omaboot_live_mirror() {
  omaboot_package_cache=$offline_mirror_dir
  omaboot_live_image || return 0
  rm -rf /tmp/omaboot-live-mirror
  mkdir -p /tmp/omaboot-live-mirror
  for package_file in "${required_package_files[@]}"; do
    ln -s "$offline_mirror_dir/$package_file" /tmp/omaboot-live-mirror/
  done
  offline_mirror_dir=/tmp/omaboot-live-mirror
  echo "live mirror: ${#required_package_files[@]} packages"
}

# After the offline mirror is indexed, before mkarchiso: our additions to the archiso profile.
omaboot_profile() {
  # OmaBoot? image types (OMABOOT_FLAVOUR): omarchy (the installer with the tester), omarchy-lite (dev
  # only, no offline package mirror), live (the stand-alone tester). lab (candidate fixes) is planned.
  case ${OMABOOT_FLAVOUR:-omarchy} in
    omarchy | omarchy-lite | live) ;;
    lab) echo "ERROR: the lab image isn't built yet (OmaBoot? LIVE-PLAN §15)" >&2 && exit 1 ;;
    *) echo "ERROR: unknown OMABOOT_FLAVOUR '$OMABOOT_FLAVOUR' (omarchy, omarchy-lite or live)" >&2 && exit 1 ;;
  esac

  # Patched applesmc and radeon for the live system, built against the exact linux-t2 in the
  # mirror and installed under updates/ (see builder/omaboot/build-modules.sh).
  bash /builder/omaboot/build-modules.sh "$offline_mirror_dir" "$build_cache_dir/airootfs"

  # Signing: the keys the BOOTLIVE hook trusts (see builder/omaboot/keys/README.md). Dev builds
  # trust only the dev key; release builds (OMABOOT_SIGNERS=release) only the release key and its
  # offline backup.
  local signer_keys signer_key key_type key_blob
  case ${OMABOOT_SIGNERS:-dev} in
    dev) signer_keys=(omaboot-dev) ;;
    release) signer_keys=(omaboot-release omaboot-release-backup) ;;
    *) echo "OMABOOT_SIGNERS must be dev or release, not '$OMABOOT_SIGNERS'" >&2 && exit 1 ;;
  esac
  mkdir -p "$build_cache_dir/airootfs/usr/share/omaboot"
  for signer_key in "${signer_keys[@]}"; do
    read -r key_type key_blob _ <"/builder/omaboot/keys/$signer_key.pub"
    printf 'omaboot namespaces="omaboot-bootlive" %s %s %s\n' "$key_type" "$key_blob" "$signer_key"
  done >"$build_cache_dir/airootfs/usr/share/omaboot/allowed_signers"

  # USB phones and LTE sticks rank between a cable and Wi-Fi (builder/omaboot/network).
  install -D -m 644 /builder/omaboot/network/15-omaboot-tether.network "$build_cache_dir/airootfs/etc/systemd/network/15-omaboot-tether.network"

  # The BOOTLIVE hook and the built-in tester (builder/omaboot/airootfs), which the image's
  # /root/.automated_script.sh runs on tty1. mkarchiso drops file modes: list them.
  install -D -m 755 /builder/omaboot/airootfs/usr/local/bin/omaboot-bootlive "$build_cache_dir/airootfs/usr/local/bin/omaboot-bootlive"
  install -D -m 755 /builder/omaboot/airootfs/usr/local/bin/omaboot-live "$build_cache_dir/airootfs/usr/local/bin/omaboot-live"
  sed -i 's|^file_permissions=(|file_permissions=(\n  ["/usr/local/bin/omaboot-bootlive"]="0:0:755"\n  ["/usr/local/bin/omaboot-live"]="0:0:755"|' "$build_cache_dir/profiledef.sh"
  grep -qF '["/usr/local/bin/omaboot-live"]="0:0:755"' "$build_cache_dir/profiledef.sh" || { echo "ERROR: the tester's file modes didn't make it into profiledef.sh" >&2; exit 1; }

  # The boot menu (builder/omaboot/tools/grub-splice.sh): our entries for this image type in place
  # of upstream's, and our look.
  bash /builder/omaboot/tools/grub-splice.sh "$build_cache_dir/grub/grub.cfg" "${OMABOOT_FLAVOUR:-omarchy}" >/tmp/omaboot-grub.cfg
  mv /tmp/omaboot-grub.cfg "$build_cache_dir/grub/grub.cfg"

  # The GRUB theme and fonts (copied to /boot/grub on the ISO with the rest of the profile's grub/
  # folder), and the Option-key startup picker's icon and name, which mkarchiso (archiso 90) is
  # taught to copy into the EFI system partition image right after it fills it. Checked, so an
  # archiso change fails loudly.
  pacman --noconfirm -S --needed freetype2 >/dev/null # grub-mkfont needs it
  mkdir -p "$build_cache_dir/grub/fonts" "$build_cache_dir/grub/themes/omaboot"
  local size
  for size in 16 24; do
    grub-mkfont -n omaboot-v -s "$size" -o "$build_cache_dir/grub/fonts/omaboot-v$size.pf2" "/builder/omaboot/assets/grub/omaboot-v$size.bdf"
  done
  cp /builder/omaboot/grub-theme/theme.txt /builder/omaboot/assets/grub/theme/*.png "$build_cache_dir/grub/themes/omaboot/"
  local esp_anchor esp_src esp_add chunks_anchor chunks_add
  esp_anchor="    mcopy -s -i \"\${efibootimg}\" \"\${efiboot_files[@]}\" '::/'"
  if [[ $(grep -cxF "$esp_anchor" /usr/bin/mkarchiso) != 1 ]]; then
    echo "ERROR: mkarchiso no longer has the line the OmaBoot? ESP files are added after" >&2
    exit 1
  fi
  # Each build type has its own icon and name (builder/omaboot/assets/esp/<flavour>-<dev|release>).
  esp_src="/builder/omaboot/assets/esp/${OMABOOT_FLAVOUR:-omarchy}-$([[ ${OMABOOT_SIGNERS:-dev} == release ]] && echo release || echo dev)"
  if [[ ! -f $esp_src/.VolumeIcon.icns ]]; then
    echo "ERROR: no startup picker icon for this build type: $esp_src" >&2
    exit 1
  fi
  esp_add="    mcopy -i \"\${efibootimg}\" $esp_src/.VolumeIcon.icns ::/\n    mcopy -i \"\${efibootimg}\" $esp_src/.disk_label $esp_src/.disk_label_2x $esp_src/.disk_label.contentDetails ::/EFI/BOOT/"
  awk -v anchor="$esp_anchor" -v add="$esp_add" '{ print } $0 == anchor { print add }' /usr/bin/mkarchiso > /tmp/mkarchiso
  install -m 755 /tmp/mkarchiso /usr/bin/mkarchiso
  grep -F '.VolumeIcon.icns' /usr/bin/mkarchiso

  # airootfs.sfs's checksum list (builder/omaboot/tools/chunk-manifest.sh), for boot-live's USB
  # port tests to check the stick's raw reads against. mkarchiso is taught to write it right after
  # airootfs.sfs and its checksum (in _prepare_airootfs_image), so it lands in the ISO next to them
  # as arch/x86_64/airootfs.chunks. Checked, so an archiso change fails loudly.
  chunks_anchor="    _mkchecksum"
  if [[ $(grep -cxF "$chunks_anchor" /usr/bin/mkarchiso) != 1 ]]; then
    echo "ERROR: mkarchiso no longer has the line the OmaBoot? checksum list is written after" >&2
    exit 1
  fi
  chunks_add="    bash /builder/omaboot/tools/chunk-manifest.sh \"\${isofs_dir}/\${install_dir}/\${arch}/airootfs.sfs\""
  awk -v anchor="$chunks_anchor" -v add="$chunks_add" '{ print } $0 == anchor { print add }' /usr/bin/mkarchiso > /tmp/mkarchiso
  install -m 755 /tmp/mkarchiso /usr/bin/mkarchiso
  grep -F 'chunk-manifest.sh' /usr/bin/mkarchiso

  omaboot_live_profile
  omaboot_lite_profile
}

# The live image (OMABOOT_FLAVOUR=live): no installer and no offline mirror; both kernels (each
# with its own archiso initramfs); the menu from grub-live-entries.cfg in place of the installer's
# entries; tty1 runs the tester instead of the installer.
omaboot_live_profile() {
  omaboot_live_image || return 0
  sed -i "s|'-Xcompression-level' '19'|'-Xcompression-level' '3'|; s|'-action' 'uncompressed@subpathname(var/cache/omarchy/mirror/offline)'|'-action' 'exclude@subpathname(var/cache/omarchy/mirror/offline)'|" "$build_cache_dir/profiledef.sh"
  if ! grep -q "exclude@subpathname(var/cache/omarchy/mirror/offline)" "$build_cache_dir/profiledef.sh"; then
    echo "ERROR: live build couldn't exclude the offline mirror in profiledef.sh" >&2
    exit 1
  fi
  sed 's/linux-t2/linux-omarchy/g' "$build_cache_dir/airootfs/etc/mkinitcpio.d/linux-t2.preset" >"$build_cache_dir/airootfs/etc/mkinitcpio.d/linux-omarchy.preset"
  # Both initramfs images xz-compressed: about half zstd's size (owner, 2026-10-14: smaller is
  # better); the kernel unpacks them once at boot.
  printf '%s\n' 'COMPRESSION="xz"' 'COMPRESSION_OPTIONS=(-9e)' >>"$build_cache_dir/airootfs/etc/mkinitcpio.conf.d/archiso.conf"
  # releng starts the services of packages the live edition leaves out (leave-out.packages)
  rm -f "$build_cache_dir"/airootfs/etc/systemd/system/cloud-init.target.wants/*.service
  local unit
  for unit in hv_fcopy_daemon hv_kvp_daemon hv_vss_daemon vboxservice vmtoolsd vmware-vmblock-fuse livecd-talk; do
    rm -f "$build_cache_dir/airootfs/etc/systemd/system/multi-user.target.wants/$unit.service"
  done
  # No listening network service on a tester: releng starts sshd, and nothing on the live image uses it
  rm -f "$build_cache_dir/airootfs/etc/systemd/system/multi-user.target.wants/sshd.service"
  mkdir -p "$build_cache_dir/airootfs/usr/share/omaboot"
  touch "$build_cache_dir/airootfs/usr/share/omaboot/live-image"
  # Our boot splash in place of Omarchy's (builder/omaboot/plymouth): the theme, its images for
  # this build type, and the pacman hook that selects it before the initramfs is built.
  local splash_src theme_dir bl
  splash_src="/builder/omaboot/assets/plymouth/live-$([[ ${OMABOOT_SIGNERS:-dev} == release ]] && echo release || echo dev)"
  theme_dir="$build_cache_dir/airootfs/usr/share/plymouth/themes/omaboot-live"
  install -d "$theme_dir"
  install -m 644 /builder/omaboot/plymouth/omaboot-live.plymouth /builder/omaboot/plymouth/omaboot-live.script "$splash_src"/*.png "$theme_dir/"
  install -D -m 644 /builder/omaboot/plymouth/60-omaboot-live-splash.hook "$build_cache_dir/airootfs/etc/pacman.d/hooks/60-omaboot-live-splash.hook"
  install -D -m 644 /builder/omaboot/plymouth/omaboot-retain-splash.conf "$build_cache_dir/airootfs/etc/systemd/system/plymouth-quit.service.d/omaboot-retain-splash.conf"
  # Macs: arm the lid's wake only when the lid is closed, so a sleep with the lid open isn't woken
  # by the lid a few seconds in (builder/omaboot/sleep; boot-live's sleep test checks it)
  install -D -m 755 /builder/omaboot/sleep/omaboot-lid-wake "$build_cache_dir/airootfs/usr/lib/systemd/system-sleep/omaboot-lid-wake"
  sed -i 's|^file_permissions=(|file_permissions=(\n  ["/usr/lib/systemd/system-sleep/omaboot-lid-wake"]="0:0:755"|' "$build_cache_dir/profiledef.sh"
  echo "live $(date -u +%F)" >"$build_cache_dir/airootfs/usr/share/omaboot/build"
  # what boot-live reports as the image (omarchy.image in reports)
  if [[ -n ${OMABOOT_RELEASE:-} ]]; then
    echo "omaboot-live ${OMABOOT_TAG:?release builds need OMABOOT_TAG}" >"$build_cache_dir/airootfs/usr/share/omaboot/image"
  else
    echo "omaboot-live dev ${OMABOOT_COMMIT:-$(date -u +%F)}" >"$build_cache_dir/airootfs/usr/share/omaboot/image"
  fi
  # The boot-live tester (S1 step 4), when the workflow brought it in from the ISO share: the
  # binary, our console fonts, where reports go (target.conf), and the egl-probe helper built here
  # against the image's own Mesa. Without it the placeholder tester runs.
  if [[ -x /builder/omaboot/bootlive/boot-live ]]; then
    bl=/builder/omaboot/bootlive
    install -D -m 755 "$bl/boot-live" "$build_cache_dir/airootfs/usr/local/bin/boot-live"
    install -d "$build_cache_dir/airootfs/usr/share/omaboot/fonts"
    install -m 644 "$bl"/fonts/*.psf.gz "$build_cache_dir/airootfs/usr/share/omaboot/fonts/"
    [[ -f $bl/target.conf ]] && install -m 644 "$bl/target.conf" "$build_cache_dir/airootfs/usr/share/omaboot/target.conf"
    if [[ -f $bl/egl-probe.c ]]; then
      pacman --noconfirm -S --needed gcc mesa libglvnd >/dev/null
      install -d "$build_cache_dir/airootfs/usr/lib/omaboot"
      cc -O2 -o "$build_cache_dir/airootfs/usr/lib/omaboot/egl-probe" "$bl/egl-probe.c" -lEGL -lGLESv2 -lgbm
    fi
    # mkarchiso drops file modes: list the executables
    sed -i 's|^file_permissions=(|file_permissions=(\n  ["/usr/local/bin/boot-live"]="0:0:755"\n  ["/usr/lib/omaboot/egl-probe"]="0:0:755"|' "$build_cache_dir/profiledef.sh"
    [[ -f $build_cache_dir/airootfs/usr/lib/omaboot/egl-probe ]] || sed -i '/"\/usr\/lib\/omaboot\/egl-probe"/d' "$build_cache_dir/profiledef.sh"
    echo "boot-live installed: $("$build_cache_dir/airootfs/usr/local/bin/boot-live" --version 2>&1 | head -n1)"
  fi
  if grep -q 'Install Omarchy' "$build_cache_dir/grub/grub.cfg" || ! grep -q 'omaboot-live-omarchy' "$build_cache_dir/grub/grub.cfg" || ! grep -q 'System restart' "$build_cache_dir/grub/grub.cfg"; then
    echo "ERROR: live build's grub.cfg menu swap went wrong" >&2
    exit 1
  fi
  # What isn't unpacked from the packages it keeps (builder/omaboot/live/noextract.conf): other
  # languages, manuals, firmware for hardware no Mac has. Under [options], where pacman reads it.
  awk 'FNR == NR { if ($0 ~ /^NoExtract/) add = add $0 "\n"; next } { print } /^\[options\]/ { printf "%s", add }' \
    /builder/omaboot/live/noextract.conf "$build_cache_dir/pacman-offline.conf" >/tmp/pacman-offline.live
  mv /tmp/pacman-offline.live "$build_cache_dir/pacman-offline.conf"
  grep -c '^NoExtract' "$build_cache_dir/pacman-offline.conf" | grep -qv '^0$' || { echo "ERROR: live build: NoExtract didn't make it into pacman-offline.conf" >&2; exit 1; }
}

# Omarchy Lite dev builds (OMABOOT_FLAVOUR=omarchy-lite): leave the offline package mirror out of
# the live image and compress fast. The ISO drops from ~6.2 GB to ~1.5 GB and builds and writes in a
# fraction of the time; it boots, runs the BOOTLIVE hook and starts the configurator, but can't
# install, so the install entries say so. Full builds are unchanged.
omaboot_lite_profile() {
  [[ ${OMABOOT_FLAVOUR:-omarchy} == omarchy-lite ]] || return 0
  sed -i "s|'-Xcompression-level' '19'|'-Xcompression-level' '3'|; s|'-action' 'uncompressed@subpathname(var/cache/omarchy/mirror/offline)'|'-action' 'exclude@subpathname(var/cache/omarchy/mirror/offline)'|" "$build_cache_dir/profiledef.sh"
  if ! grep -q "exclude@subpathname(var/cache/omarchy/mirror/offline)" "$build_cache_dir/profiledef.sh"; then
    echo "ERROR: Omarchy Lite build couldn't exclude the offline mirror in profiledef.sh" >&2
    exit 1
  fi
  sed -i 's/^menuentry "Install Omarchy/menuentry "(Omarchy Lite dev build: no installer) Install Omarchy/' "$build_cache_dir/grub/grub.cfg"
  grep -c "Omarchy Lite dev build" "$build_cache_dir/grub/grub.cfg"
}

# After mkarchiso: the checks on the image it built, and for release and pinned dev builds the
# package manifest.
omaboot_after_mkarchiso() {
  if omaboot_live_image && ! grep -qx 'Theme=omaboot-live' "$build_cache_dir/work/x86_64/airootfs/etc/plymouth/plymouthd.conf"; then
    echo "ERROR: live build: the OmaBoot? Live splash wasn't selected (plymouthd.conf)" >&2
    exit 1
  fi
  # The live image: nothing the leave-outs took is one a Mac's hardware or the tester needs
  if omaboot_live_image; then
    bash /builder/omaboot/live/check-live-image.sh "$build_cache_dir/work/x86_64/airootfs"
  fi

  # Release and pinned dev builds: the package manifest (every package in the image: name,
  # version, repo, file, sha256 of the file installed) and the pin check: a package the official
  # ISO has must be the very same file (same sha256); anything else is one the live edition adds.
  [[ -n $OMABOOT_PIN ]] || return 0
  local image_root package_cache installed installed_count listed name version repo file want sum official
  image_root="$build_cache_dir/work/x86_64/airootfs"
  package_cache=${omaboot_package_cache:-$offline_mirror_dir}
  mapfile -t installed < <(pacman --root "$image_root" --dbpath "$image_root/var/lib/pacman" -Qq)
  pacman --config "$online_conf" --dbpath /tmp/offlinedb -S --print --print-format '%n %v %r %f' "${installed[@]}" |
    sort -u >/tmp/omaboot-resolved.tsv
  {
    printf '# name\tversion\trepo\tfile\tsha256\tofficial ISO\n'
    while read -r name version repo file; do
      want=$(awk -F'\t' -v n="$name" '!/^#/ && $1 == n { print $2 "\t" $3 "\t" $4 }' "$pin_dir/official-packages.tsv")
      [[ -n $file && -f $package_cache/$file ]] || { echo "ERROR: no package file for $name ($file)" >&2; exit 1; }
      sum=$(sha256sum "$package_cache/$file" | cut -d' ' -f1)
      if [[ -z $want ]]; then
        official="added"
      elif [[ $want == "$version"$'\t'"$file"$'\t'"$sum" ]]; then
        official="same"
      else
        echo "ERROR: $name $version ($file, $sum) isn't the official ISO's ($want): the pin failed" >&2
        exit 1
      fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$version" "$repo" "$file" "$sum" "$official"
    done </tmp/omaboot-resolved.tsv
  } >/out/packages.tsv
  installed_count=${#installed[@]}
  listed=$(grep -vc '^#' /out/packages.tsv)
  if [[ $listed != "$installed_count" ]]; then
    echo "ERROR: the package manifest lists $listed packages, the image has $installed_count" >&2
    exit 1
  fi
  echo "Package manifest: $listed packages, $(grep -c $'\tsame$' /out/packages.tsv) the official ISO's own files, $(grep -c $'\tadded$' /out/packages.tsv) added"
}
