#!/bin/bash
# OmaBoot? build dry run (dry-run.sh): the stand-in for each tool the build needs the network, real
# packages or the build box for. It's called by the tool's name; each call is logged to
# /harness-state/calls.log, sorted where order doesn't matter, so two runs compare line by line.
set -euo pipefail
state=/harness-state
tool=${0##*/}
log() { printf '%s\n' "$*" >>"$state/calls.log"; }
pkgfile() { printf '%s-1-1-x86_64.pkg.tar.zst' "$1"; }

case $tool in
  date) exec /usr/bin/date -d '2026-01-01 00:00:00 UTC' "$@" ;;
  pacman-key | cc | check-live-image.sh) log "$tool $*" ;;
  build-modules.sh)
    log "$tool mirror=$1 ($(find "$1/" -maxdepth 1 -name '*.pkg.tar.zst' | wc -l) packages) airootfs=$2"
    ;;
  grub-mkfont)
    log "$tool $*"
    while (($#)); do [[ $1 == -o ]] && echo "dry run font" >"$2"; shift; done
    ;;
  curl)
    url='' file=''
    while (($#)); do
      case $1 in
        -o) file=$2; shift ;;
        http*) url=$1 ;;
      esac
      shift
    done
    log "curl $url${file:+ -o $file}"
    node='node dry run'
    if [[ $url == *SHASUMS256.txt* ]]; then
      printf '%s  node-v0.0.0-darwin-x64.tar.gz\n' 0000
      printf '%s  node-v0.0.0-linux-x64.tar.gz\n' "$(echo "$node" | sha256sum | cut -d' ' -f1)"
    elif [[ -n $file ]]; then
      echo "$node" >"$file"
    fi
    ;;
  repo-add)
    opts=() db='' files=()
    for a in "$@"; do
      if [[ $a == -* ]]; then opts+=("$a"); elif [[ -z $db ]]; then db=$a; else files+=("$a"); fi
    done
    links=0
    for f in "${files[@]}"; do [[ -L $f ]] && links=$((links + 1)); done
    log "repo-add ${opts[*]} $db: ${#files[@]} files ($links links): $(printf '%s\n' "${files[@]##*/}" | sort | tr '\n' ' ')"
    # a real database (and its .files twin) with one entry per package, added to any already
    # there: upstream's mirror index unpacks the parts it had repo-add write
    entries=$(mktemp -d) # (in the run's own /tmp)
    [[ -s $db ]] && bsdtar -xf "$db" -C "$entries" 2>/dev/null
    for f in "${files[@]}"; do
      entry=${f##*/}
      entry=${entry%.pkg.tar.*}
      entry=${entry%-*}
      mkdir -p "$entries/$entry"
      printf '%%FILENAME%%\n%s\n\n%%NAME%%\n%s\n\n' "${f##*/}" "${entry%-*-*}" >"$entries/$entry/desc"
    done
    for out in "$db" "${db%.db.tar.gz}.files.tar.gz"; do
      (cd "$entries" && find . -mindepth 1 -maxdepth 1 -type d -printf '%P\n' | sort | bsdtar -czf "$out" -T -)
    done
    ;;
  mkarchiso)
    log "mkarchiso $*"
    profile=${*: -1}
    work=
    while (($#)); do [[ $1 == -w ]] && work=$2; shift; done
    mkdir -p "$state/profile"
    tar -C "$profile" --exclude=./work --exclude=./airootfs/var/cache/omarchy/mirror/offline -cf - . |
      tar -C "$state/profile" -xf -
    (
      declare -A file_permissions=() # as mkarchiso has it
      # shellcheck disable=SC1091
      source "$profile/profiledef.sh"
      for v in iso_name iso_label iso_publisher iso_application iso_version install_dir buildmodes \
        bootmodes arch pacman_conf airootfs_image_type airootfs_image_tool_options \
        bootstrap_tarball_compression; do
        declare -p "$v" 2>/dev/null || echo "unset $v"
      done
      for k in "${!file_permissions[@]}"; do echo "file_permissions $k ${file_permissions[$k]}"; done | sort
    ) >"$state/profile.txt"
    cp /usr/bin/mkarchiso "$state/mkarchiso"
    # what the image's pacman hooks would leave for the checks after mkarchiso
    mkdir -p "$work/x86_64/airootfs/etc/plymouth"
    theme=omarchy
    [[ -f $profile/airootfs/etc/pacman.d/hooks/60-omaboot-live-splash.hook ]] && theme=omaboot-live
    echo "Theme=$theme" >"$work/x86_64/airootfs/etc/plymouth/plymouthd.conf"
    ;;
  pacman)
    config='' root='' dbpath='' cachedir='' format='' ops=() targets=()
    while (($#)); do
      case $1 in
        --config) config=$2; shift ;;
        --root) root=$2; shift ;;
        --dbpath) dbpath=$2; shift ;;
        --cachedir) cachedir=$2; shift ;;
        --print-format) format=$2; shift ;;
        -*) ops+=("$1") ;;
        *) targets+=("$1") ;;
      esac
      shift
    done
    conf=-
    if [[ -n $config ]]; then
      conf=$(sha256sum <"$config" | cut -c1-12)
      cp "$config" "$state/confs/$conf.conf"
    fi
    log "pacman ${ops[*]} config=$conf root=${root:--} dbpath=${dbpath:--} cachedir=${cachedir:--} format=${format:--} targets(${#targets[@]}): $(printf '%s\n' "${targets[@]}" | sort | tr '\n' ' ')"
    op=" ${ops[*]} "
    if [[ $op == *" -Syw "* ]]; then
      for t in "${targets[@]}"; do
        f=${cachedir%/}/$(pkgfile "$t")
        [[ -e $f ]] && continue
        if [[ $t == "${OMARCHY_RUNTIME_PACKAGE:-}" ]]; then
          cp /tmp/dry-run-runtime.pkg.tar.zst "$f"
        else
          echo "dry run $t" >"$f"
        fi
      done
    elif [[ $op == *" --print "* ]]; then
      for t in "${targets[@]}"; do
        case $format in
          %f) pkgfile "$t" ;;
          %n) echo "$t" ;;
          '%n %v %r %f') echo "$t 1-1 dryrun $(pkgfile "$t")" ;;
          *) echo "$t" ;;
        esac
        echo
      done | sed '/^$/d'
    elif [[ $op == *" -Qq "* ]]; then
      # the image's packages: those in the repo mkarchiso installed from that no official ISO has
      find /var/cache/omarchy/mirror/offline/ -maxdepth 1 -name '*-1-1-x86_64.pkg.tar.zst' -printf '%f\n' |
        sed 's/-1-1-x86_64\.pkg\.tar\.zst$//' | sort |
        grep -vxF -f <(cut -f1 /builder/omaboot/release/pins/*/official-packages.tsv) | head -n 5 || true
    fi
    ;;
  *) echo "dry run: no stand-in for $tool" >&2; exit 1 ;;
esac
