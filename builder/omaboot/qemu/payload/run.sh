#!/bin/bash
# QEMU smoke-test payload for omaboot-bootlive: prove the hook verified and ran signed code.
msg="OMABOOT-SMOKE: hook ran signed payload on $(uname -r) from $(pwd)"
echo "$msg" >/dev/ttyS0 2>/dev/null
mkdir -p results && date -u +%FT%TZ >results/smoke.txt && sync
clear
printf '\n\n   OmaBoot? smoke test: the signed BOOTLIVE payload ran.\n   %s\n\n   Continuing to the installer.\n' "$(uname -r)"
sleep 5
