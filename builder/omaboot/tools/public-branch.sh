#!/bin/bash
#
# The public branch: our changes as the public repo (omaboot/omaboot-iso) carries them. One commit
# on upstream omarchy-iso's commit, holding HEAD's tree without the files listed in
# builder/omaboot/private-only.txt (our dev box's) and builder/omaboot/public-drop.txt (upstream's
# CI jobs we don't run). Its history is upstream's plus that commit, so the release build's
# difference report and the scrub check read our changes against the official ISO's commit.
#
# Later: run it again on a newer HEAD. The new commit's parents are the branch's last commit and,
# when upstream moved (a newer pin), the new upstream commit, so the public history only grows.
#
# Usage: public-branch.sh [-b BASE] [-m MESSAGE] BRANCH
#   -b  the upstream commit (default: OFFICIAL_ISO_COMMIT of release.env's pin)
#   -m  the commit message (default: names the Omarchy release and HEAD)
# Run in a clone whose HEAD is our branch; HEAD and the working tree are left as they are. Commits
# as Carl Hoyer <carl@hoyer.ca>. Prints the new commit.

set -euo pipefail
base= message=
while getopts b:m: opt; do
  case $opt in
    b) base=$OPTARG ;;
    m) message=$OPTARG ;;
    *) sed -n 's/^# \{0,1\}//; /^Usage:/,/^Run in/p' "$0" >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
(($# == 1)) || { sed -n 's/^# \{0,1\}//; /^Usage:/,/^Run in/p' "$0" >&2; exit 2; }
branch=$1
top=$(git rev-parse --show-toplevel)
cd "$top"
rel=builder/omaboot/release
pin=$(git show "HEAD:$rel/release.env" | sed -n 's/^OMABOOT_RELEASE=//p')
if [[ -z $base ]]; then
  base=$(git show "HEAD:$rel/pins/$pin/pin.env" | sed -n 's/^OFFICIAL_ISO_COMMIT=//p')
fi
base=$(git rev-parse --verify "$base^{commit}")
git merge-base --is-ancestor "$base" HEAD || { echo "public-branch: HEAD isn't based on ${base:0:7}" >&2; exit 1; }

# HEAD's tree without the left-out paths, in an index of its own
export GIT_INDEX_FILE=$(git rev-parse --absolute-git-dir)/public-branch.index # (kept; read afresh each run)
git read-tree HEAD
mapfile -t leave_out < <(cat <(git show HEAD:builder/omaboot/private-only.txt) <(git show HEAD:builder/omaboot/public-drop.txt) | sed '/^#/d; /^$/d')
for p in "${leave_out[@]}"; do
  git rm -r -q --cached --ignore-unmatch -- "$p"
done
tree=$(git write-tree)
unset GIT_INDEX_FILE

parents=()
if prev=$(git rev-parse -q --verify "refs/heads/$branch"); then
  [[ $(git rev-parse "$prev^{tree}") != "$tree" ]] || { echo "public-branch: $branch already holds this tree" >&2; echo "$prev"; exit 0; }
  parents+=(-p "$prev")
  git merge-base --is-ancestor "$base" "$prev" || parents+=(-p "$base")
else
  parents+=(-p "$base")
fi
message=${message:-"OmaBoot? on Omarchy $pin (omarchy-iso ${base:0:7})

The OmaBoot? images (builder/omaboot): the stand-alone tester image, its boot menu and splash, the
signed BOOTLIVE hook, the patched modules and the release pipeline pinned to the official Omarchy
$pin ISO. From our branch at $(git rev-parse --short HEAD)."}
commit=$(GIT_AUTHOR_NAME='Carl Hoyer' GIT_AUTHOR_EMAIL=carl@hoyer.ca GIT_COMMITTER_NAME='Carl Hoyer' GIT_COMMITTER_EMAIL=carl@hoyer.ca \
  git commit-tree "$tree" "${parents[@]}" -m "$message")
git update-ref "refs/heads/$branch" "$commit"
echo "$commit"
