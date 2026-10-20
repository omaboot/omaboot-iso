#!/bin/bash
#
# Unit tests for omaboot-bootlive's signature and manifest checks. Each case builds a fake
# BOOTLIVE drive in a throwaway directory (OMABOOT_BOOTLIVE_DIR), signs it with throwaway keys and
# asserts whether the hook ran the tester. The tester records what it saw in results/ on the drive.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
HOOK="$ROOT/builder/omaboot/airootfs/usr/local/bin/omaboot-bootlive"
SIGN="$ROOT/builder/omaboot/tools/sign-bootlive.sh"

pass() {
  printf 'ok - %s\n' "$1"
}

fail() {
  local description="$1"
  local detail="${2:-}"

  [[ -n $detail ]] && printf '%s\n' "$detail" >&2
  printf 'not ok - %s\n' "$description" >&2
  exit 1
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

ssh-keygen -q -t ed25519 -N '' -C trusted -f "$work/trusted"
ssh-keygen -q -t ed25519 -N '' -C stranger -f "$work/stranger"
read -r key_type key_blob _ <"$work/trusted.pub"
printf 'omaboot namespaces="omaboot-bootlive" %s %s\n' "$key_type" "$key_blob" >"$work/allowed_signers"

new_drive() {
  drive=$(mktemp -d "$work/drive.XXXXXX")
  cat >"$drive/run.sh" <<'TESTER'
#!/bin/bash
ls -A >results/ran.txt
TESTER
  printf 'data\n' >"$drive/data.txt"
}

run_hook() {
  OMABOOT_BOOTLIVE_DIR="$drive" OMABOOT_BOOTLIVE_SIGNERS="$work/allowed_signers" \
    OMABOOT_BOOTLIVE_RUN="$work/run" OMABOOT_BOOTLIVE_REFUSE_PAUSE=0 \
    bash "$HOOK" >"$work/out.txt" 2>&1
}

expect_ran() {
  local description="$1"
  run_hook || fail "$description" "hook exited $?: $(cat "$work/out.txt")"
  [[ -f $drive/results/ran.txt ]] || fail "$description" "tester did not run"
  [[ ! -e $work/run ]] || fail "$description" "RAM copy left behind"
  pass "$description"
}

expect_refused() {
  local description="$1" message="$2"
  if run_hook; then fail "$description" "hook accepted the drive"; fi
  [[ ! -f $drive/results/ran.txt ]] || fail "$description" "tester ran"
  grep -q "$message" "$work/out.txt" || fail "$description" "expected '$message', got: $(cat "$work/out.txt")"
  [[ ! -e $work/run ]] || fail "$description" "RAM copy left behind"
  pass "$description"
}

sign_manifest() { # sign the drive's manifest as it is, with KEY and NAMESPACE
  rm -f "$drive/manifest.sig"
  ssh-keygen -q -Y sign -f "$1" -n "$2" "$drive/manifest"
}

new_drive
bash "$SIGN" "$drive" "$work/trusted" >/dev/null
printf 'not listed\n' >"$drive/extra.txt"
expect_ran "a drive signed by a trusted key runs"
grep -qx data.txt "$drive/results/ran.txt" || fail "listed files are copied to RAM"
! grep -qx extra.txt "$drive/results/ran.txt" || fail "unlisted files stay off the RAM copy"
pass "only listed files are copied to RAM"

new_drive
expect_refused "an unsigned drive is refused" "no signed manifest"

new_drive
bash "$SIGN" "$drive" "$work/stranger" >/dev/null
expect_refused "a drive signed by an untrusted key is refused" "isn't signed by OmaBoot"

new_drive
bash "$SIGN" "$drive" "$work/trusted" >/dev/null
sign_manifest "$work/trusted" omaboot-release
expect_refused "a trusted key's signature in another namespace is refused" "isn't signed by OmaBoot"

new_drive
bash "$SIGN" "$drive" "$work/trusted" >/dev/null
printf 'changed\n' >"$drive/data.txt"
expect_refused "a file changed after signing is refused" "doesn't match its signed manifest"

new_drive
bash "$SIGN" "$drive" "$work/trusted" >/dev/null
printf 'tampered\n' >>"$drive/manifest"
expect_refused "a manifest changed after signing is refused" "isn't signed by OmaBoot"

for bad_path in ../escape /etc/passwd manifest results/x; do
  new_drive
  bash "$SIGN" "$drive" "$work/trusted" >/dev/null
  printf '%s  %s\n' "$(sha256sum <"$drive/data.txt" | cut -d' ' -f1)" "$bad_path" >>"$drive/manifest"
  sign_manifest "$work/trusted" omaboot-bootlive
  expect_refused "a signed manifest naming '$bad_path' is refused" "unsafe path"
done

new_drive
rm "$drive/run.sh"
bash "$SIGN" "$drive" "$work/trusted" >/dev/null
expect_refused "signed files without run.sh are refused" "no run.sh"
