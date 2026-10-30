# OmaBoot? release builds

A release of OmaBoot? Live is the stand-alone tester image, built from a release tag of this repo,
**pinned to the packages of the official Omarchy ISO of the same release**, smoke-tested in QEMU,
compared file by file with that official ISO, and signed by the owner. Dev builds (the
`omaboot-dev` branch on the private Forgejo, `.forgejo/workflows/build-iso.yml`) are unchanged by
any of this: everything here switches on `OMABOOT_RELEASE`.

```
git tag v4.0.4-1 && git push --tags            (public repo omaboot/omaboot-iso)
  └─ .github/workflows/release.yml              GitHub-hosted runner, never self-hosted
       builder/omaboot/release/build.sh         official ISO → pinned repos → boot-live → image
                                                → 3 QEMU smoke tests (nothing submitted) → diff report
       draft GitHub release: SHA256SUMS + small files; the ISO stays a workflow artifact (30 days)
owner, on the laptop: sign SHA256SUMS with the release key (1Password), attach SHA256SUMS.sig
  └─ .github/workflows/publish.yml (manual, tag)   refuses without a valid SHA256SUMS.sig
       verify signature + every file → upload to R2 (current + 2 previous per edition) → publish
```

## Where the official ISO's packages come from (research, 2026-10-12)

The official Omarchy ISO is built by `bin/omarchy-iso-release` → `omarchy-iso-make --no-cache` on a
maintainer's machine, from omacom/omarchy-iso's `quattro` branch. It pins nothing by date: it
downloads whatever its channel's pacman config (`configs/pacman-online-stable.conf`) serves at that
moment. For **Omarchy 4.0.4** (`omarchy-4.0.4.iso`, 6,185,304,064 bytes, sha256 `ddeded27…f92d`,
published 2026-09-15 21:35 UTC):

- **Build date and source:** `arch/version` on the ISO says 2026.09.15; the squashfs was made
  2026-09-15 ~21:11 UTC; the `omarchy` 4.0.4-1 package was built 21:04 UTC that day. The last
  `quattro` commit before it is `7cfb711` (2026-09-15 05:35 UTC; the next is 2026-09-21), the commit
  this fork is based on.
- **The package set:** the ISO carries its installer's whole package mirror,
  `/var/cache/omarchy/mirror/offline` (1248 packages, each with its `.sig`), and `offline.db` lists
  every file's SHA-256. That is the authoritative list: `pins/4.0.4/official-packages.tsv`.
- **Arch packages** come from `stable-mirror.omarchy.org`, Omarchy's own frozen Arch snapshot, not a
  live Arch mirror. Its `lastupdate` is 1788799390 (2026-09-07 16:43 UTC) and it hasn't moved since
  (files dated 2026-09-08), so today it still serves 4.0.4's Arch packages: all 1204 match by
  checksum. It keeps no history, though. The **Arch Linux Archive** day `2026/09/07` holds all 1204
  with the same SHA-256 (core and multilib dbs are byte-identical to the stable mirror's; extra
  differs in 24 packages the ISO doesn't use). The days around it don't (09/06: 1188, 09/08: 1185).
- **Omarchy packages** (39, from `pkgs.omarchy.org/stable`): the channel serves only the newest
  build of each package and keeps no archive; 2 of the 39 (aether 4.29.8-1, mise-bin 2026.9.7-1)
  have already moved on.
- **t2linux packages** (5, `arch-mact2`): no dated archive either. The funami mirror keeps old
  `linux-t2` files but its database is current (linux-t2 7.2.9 today; 4.0.4 has 7.2.4.arch1-3),
  `t2fanrd r16.48baf96-1` was republished under the same name with a different checksum, and
  `apple-bcm-firmware` was dropped on 2026-09-16 (no repo serves it any more; classified by hand).
- **The build container** (`archlinux/archlinux:latest`, then `pacman -Syu` from the default
  mirrors) is not recorded anywhere; archiso 90-1, grub 2:2.14-1 etc. are the same on the archive
  days 2026/09/15 and 09/16. We use the Docker Hub image `base-20260915.0.594185` (by digest) and the
  archive day 2026/09/15.
- **Node.js** for offline mise installs: `nodejs.org/dist/latest` at build time; the ISO has v26.8.2.

So a release build pins: **Arch packages to archive.archlinux.org/repos/2026/09/07**, and **Omarchy +
arch-mact2 packages to the official ISO itself** (the pinned repos are made from its package mirror,
each file checked against `official-packages.tsv`), with the official channel's repo order and
SigLevels. The databases and the package files both come from the archive day, and pacman checks
each file against the archive's checksum and its Arch signature. (Until 4.0.6-1, files were tried
first on `stable-mirror.omarchy.org` as pacman 7's `CacheServer`. Once that mirror moved past the
release's snapshot it answered a missing `.sig` with a 27 KB HTML page, which pacman's 16 KiB
signature limit turned into a failed download instead of a fall-back to the archive.) After the build, every package in the image is checked: if the official ISO has that
package, ours must be the very same file (same SHA-256), or the build fails. The official ISO is
verified by the SHA-256 in the pin (from iso.omarchy.org) and its GPG signature
(`builder/omarchy.gpg`; the result is in the difference report).

`omaboot_release.py pin` does this research for a new Omarchy release (below).

## Files

| File | What it does |
|---|---|
| `release.env` | What a release tag builds: the Omarchy version (pin), the edition, the boot-live repo + tag, the Go image (digest). |
| `pins/<omarchy>/pin.env` | The official ISO (URL, SHA-256, date, omarchy-iso commit), the archive days, the build image, Node.js version. |
| `pins/<omarchy>/official-packages.tsv` | The official ISO's 1248 packages: name, version, file, SHA-256, repo. |
| `omaboot_release.py` | `pin` (make a pin from an official ISO), `check-pin`, `pinned-repo` (the [omarchy]/[arch-mact2] repos from the ISO), `inventory` (an ISO's files: ISO 9660, EFI partition, root file system, packages), `diff` (the difference report). Standard library only; needs unsquashfs, mtools, repo-add. |
| `explain.tsv` | Why each difference is ours: the rules the report applies. |
| `build.sh` | The whole release build (both CI systems run it). |
| `verify-sums.sh` | Checks `SHA256SUMS.sig` against the release keys, then the files. `--signers` prints the `allowed_signers` file. |
| `publish-r2.sh` | Uploads a verified release to R2, updates `<edition>/releases.json`, drops all but the newest 3. |

Changes outside this folder: `builder/build-iso.sh` (the release mode: pinned pacman config,
`-Syuu` to the archive day, pinned Node.js, image name, the package manifest and pin check),
`bin/omarchy-iso-make` (mounts the pinned repos, passes `SOURCE_DATE_EPOCH`, a package cache of its
own per release, no module cache so the log shows the stock module rebuilds), and
`builder/omaboot/qemu/smoke.py` (`OMABOOT_SMOKE_NO_SUBMIT`, `OMABOOT_SMOKE_EXPECT_REFUSE`).

## Release outputs

All in `SHA256SUMS`, which the owner signs:

| File | |
|---|---|
| `omaboot-live-<tag>.iso` | The image (R2 only). Trusts only the release + backup keys for BOOTLIVE sticks. |
| `packages.tsv` | Every package in the image: name, version, repo, file, SHA-256 of the file installed, and `same` (the official ISO's own file) or `added`. |
| `diff-report.md` / `.tsv.gz` | Against the official ISO: packages added/removed/changed and every differing file (ISO 9660 volume, EFI partition, root file system), each explained as ours, a package we add, generated at build time, or **unexplained** (a release fails on any). |
| `smoke-summary.txt` | The three QEMU runs: a dev-signed stick is refused; the tester's unattended quick pass saves its report; the tester makes its reports partition on the stick. No run can submit (restricted network; a "submitted" fails the test). |
| `boot-live.txt` | boot-live repo, tag, commit, Go image, binary SHA-256, `--version`, report target. |
| `build-info.json` | Tag, edition, Omarchy version, official ISO, fork commit, pins, boot-live, CI run (publish.yml finds the ISO artifact through it). |
| `build.log` | The whole build, including the unpatched module rebuilds matching the official modules. |

Not published: `smoke/` (screenshots, serial logs), `inventory/` (our ISO's inventory), `release-notes.md` (the draft's text).

## Signing and publishing (owner)

The draft release on GitHub has `SHA256SUMS`. On the laptop, with the release key in 1Password's SSH agent:

```bash
gh release download v4.0.4-1 -R omaboot/omaboot-iso -p SHA256SUMS -D /tmp/omaboot-v4.0.4-1
cd /tmp/omaboot-v4.0.4-1 && cat SHA256SUMS      # compare with the run's log
SSH_AUTH_SOCK=~/.1password/agent.sock ssh-keygen -Y sign -n omaboot-release \
  -f /path/to/omaboot-release.pub SHA256SUMS    # 1Password asks; writes SHA256SUMS.sig
gh release upload v4.0.4-1 -R omaboot/omaboot-iso SHA256SUMS.sig
gh workflow run publish.yml -R omaboot/omaboot-iso -f tag=v4.0.4-1
```

publish.yml refuses without `SHA256SUMS.sig`, verifies it (`verify-sums.sh`), fetches the ISO
artifact of the build run and checks every file against `SHA256SUMS`, uploads to R2
(`live/<tag>/…`, `live/releases.json`), and publishes the GitHub release. Old releases leave R2 but
keep their GitHub release (checksums, signature, reports) for good.

**Verifying a download** (for the download page): `verify-sums.sh --signers > allowed_signers`
(or the `allowed_signers` next to the files), then
`ssh-keygen -Y verify -f allowed_signers -I omaboot -n omaboot-release -s SHA256SUMS.sig < SHA256SUMS && sha256sum -c --ignore-missing SHA256SUMS`.

## Pinned dev builds

The dev workflow (`.forgejo/workflows/build-iso.yml`) builds on today's packages by default. With
`[pinned]` in the commit subject, or a manual run with `packages: pinned`, it uses the pins of
`release.env`'s Omarchy release instead (`OMABOOT_PIN`): the same package set as a release build,
kernels included, prepared by `prepare-pin.sh` from the official ISO cached on the share, but with the
dev keys and the dev report target. The ISO is named `omaboot-dev-<flavour>-pinned-…` and its
package manifest (the pin check's) lands next to it as `….packages.tsv`.

## Dry run on the private runner

`.forgejo/workflows/release-dryrun.yml` (manual only) runs `build.sh` on the private runner with no
report target, boot-live from the private Forgejo repo, and outputs in `release-dryrun/dryrun-<run>/` on
the runner's share. The official ISO and what's made from it are cached in `official/` there
(downloaded once).
Dispatch: `POST /api/v1/repos/boot-live/omarchy-iso/actions/workflows/release-dryrun.yml/dispatches`
with `{"ref": "<branch>"}`. The job's log: `GET /api/v1/repos/boot-live/omarchy-iso/actions/jobs/<id>/logs`;
its artifact (reports, smoke tests, both inventories; no ISOs): `GET …/actions/runs/<id>/artifacts`.

The job's token can't read the private boot-live repo and the Forgejo SSH port isn't reachable from
the runner, so the dry run clones boot-live from a git bundle on the share
(`git -C boot-live bundle create boot-live.bundle --branches --tags`, copied to
`release-dryrun/boot-live.bundle` there), still by tag. A `BOOT_LIVE_TOKEN` repo secret (a
read-only token) switches it to cloning over HTTP. On GitHub the public repo needs neither.

The refuse smoke test only shows that a dev-signed stick doesn't run on a release image; its positive
control is the dev pipeline's boot test, where the same payload runs on a dev image.

## Dry runs

**dryrun-74 (branch `release-pipeline-0.6`, fork 1ecd833, 2026-10-14): PASS** in 12 min (pinned repos
and official inventory from the cache; the image 9.5 min; smoke tests 1.7 min, refuse/tester/room all
PASS, nothing submitted: restricted network or none, no key). boot-live v0.6.3-dev (aaa7947), binary
sha256 12b15a88…, identical in runs 73 and 74; packages.tsv byte-identical to dryrun-59's; ISO
2,087,747,584 bytes. 0 unexplained differences out of 8764: new since dryrun-59 are
`arch/x86_64/airootfs.chunks` (the USB read test's checksum list), `usr/lib/systemd/system-sleep/omaboot-lid-wake`
(the lid-wake sleep hook; dryrun-73 failed on it, now in explain.tsv) and `usr/share/omaboot/target.conf`
(now always written: `watch=https://boot.watch`). The branch is omaboot-dev ec117d3 plus this
directory's commits replayed; `release-pipeline` (head 22248de) keeps the 4.0.4 / boot-live
v0.4.0-dev state of dryrun-59.

### 2026-10-12

**dryrun-59 (fork b740e0c): PASS** in 18 min (the official ISO's repos and inventory rebuilt, 2.6
min; the image 13 min; smoke tests 1.7 min; difference report 0.5 min). ISO 2,087,747,584 bytes;
0 unexplained differences; outputs in `release-dryrun/dryrun-59/` on the share. The
boot-live binary and packages.tsv came out byte-identical in runs 57–59.

The first complete one, dryrun-58 (fork 0f30c0c):

- **Pinning:** 496 packages in the image; 495 are the official ISO's own files (same SHA-256), 1 added
  (`mesa-utils` 9.0.0-7 from the 2026/09/07 archive). linux-t2 7.2.4.arch1-3 (the official ISO's, not
  today's 7.2.9) and linux-omarchy 7.2.5-3.
- **Patched modules:** applesmc's stock rebuild matched the shipped module (t2linux patches 794069f),
  radeon's matched for both kernels; both patches applied.
- **Smoke tests:** refuse, tester, room all PASS; reports saved, none submitted.
- **Difference report:** 14 packages added (linux-omarchy, mesa, mesa-utils and 11 dependencies; 13 of
  the 14 are in the official ISO's installer mirror at the same version), none removed or changed;
  8761 differing paths, 15 unexplained on the first run (random keys made by package install
  scripts, the image version mkarchiso writes, archiso's dated UUID file, and Python bytecode the
  official build machine left in its checkout). Rules added; 0 unexplained after.
- **Size and time:** 2,087,747,584 bytes; 12 min with the package cache warm (the first run spent
  ~20 min downloading ~1.2 GB from the archive at ~1.4 MB/s, before the CacheServer change).
- **The official ISO:** downloaded once to `official/omarchy-4.0.4.iso` on the share (2026-10-12); GPG
  signature good (Omarchy <pkgs@omarchy.org>, key 40DFB630…0CAC571, `builder/omarchy.gpg`).

## A new Omarchy release

1. Get the official ISO once (`curl -O https://iso.omarchy.org/omarchy-X.Y.Z.iso`; check its `.sha256`).
2. Find the omarchy-iso commit it was built from (the last first-parent `quattro` commit before the
   ISO's Last-Modified time) and merge it into `omaboot-dev` (`git merge`; rerere is on, so a
   conflict settled once is settled again). Since 4.0.6 the release watch does steps 1–4 but the
   tag by itself, on a branch `upstream-X.Y.Z` (below).
3. `make-pin.sh X.Y.Z CACHE refs/remotes/upstream/quattro OUT` works out the commit, the build
   image and the day by itself and runs the pin in that image (only docker needed; the dev box's
   `make-pin` workflow runs it), or by hand:
   `omaboot_release.py pin omarchy-X.Y.Z.iso --version X.Y.Z --iso-url https://iso.omarchy.org/omarchy-X.Y.Z.iso --base-commit <sha> --build-image 'archlinux/archlinux:base-YYYYMMDD.0.N@sha256:…' --build-date YYYY/MM/DD --out pins/X.Y.Z --cache /tmp/pin-cache`
   (needs unsquashfs; reads a few weeks of Arch Linux Archive databases once). A package no repo
   serves any more needs `--repo NAME=REPO`. An Arch package the chosen archive day has a newer
   build of, while an earlier day holds the ISO's file, goes into `[arch-held]` by itself (below).
4. Point `release.env` at it, run the dry run, read `diff-report.md`, tag.

**The release watch** (`.forgejo/workflows/release-watch.yml`, daily on the dev box;
`builder/omaboot/tools/release-watch.sh`): when iso.omarchy.org has a version newer than
`release.env`'s, it makes the pin (`make-pin.sh`), a branch `upstream-X.Y.Z` with upstream's
commit merged in and the pin committed, and checks it (test/all, the build's dry runs). A branch
that passes is pushed, which starts its pinned live build, and a release dry run starts on it;
one that doesn't is reported and waits for a maintainer. Either way a maintainer reads it and
merges it into `omaboot-dev`; nothing is merged or tagged by itself.

## Owner setup before the first public release

1. The `omaboot` org and the public `omaboot/omaboot-iso` repo (this fork); push the branch, then a tag.
   Remove or disable upstream's `.github/workflows/nightly-build.yml` there: it builds an Omarchy ISO
   every night on a schedule.
2. Secrets: `OMABOOT_REPORT_KEY` (doesitomarchy.com source key for boot-live; a doesitomarchy.com
   change), `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_BUCKET`. Variable
   `OMABOOT_REPORT_URL` only if not `https://doesitomarchy.com`.
3. An environment `release` with the owner as required reviewer (publish.yml waits for it).
4. The release key in 1Password (its public half is `builder/omaboot/keys/omaboot-release.pub`) and
   the paper backup (`omaboot-release-backup.pub`): both public halves are already committed, so the
   private halves must be the ones made with them.
5. The R2 bucket and a token scoped to it; the custom domain on its zone.
6. boot-live public at `omaboot/boot-live` with a release tag whose built-in catalog snapshot comes
   from production (the dev tags' snapshots, v0.6.3-dev's included, come from staging); set
   `BOOT_LIVE_TAG` in `release.env` (now v0.6.3-dev, for dry runs).
7. Optional variable `OMABOOT_WATCH_URL` only if the images shouldn't test through
   `https://boot.watch` (target.conf `watch=`).

## Decisions made while building this (for review)

1. Omarchy and arch-mact2 packages come from the official ISO's own mirror: neither repo keeps an
   archive, and 2 Omarchy and 3 arch-mact2 packages of 4.0.4 are already gone or changed upstream.
2. Arch packages are pinned to the archive day that reproduces the official set (2026/09/07, the
   stable mirror's snapshot), not the ISO's build day (2026/09/15), which would give different files.
3. Release tags look like `v4.0.4-1` (Omarchy version, OmaBoot? build); the ISO is
   `omaboot-live-4.0.4-1.iso`. Nothing depends on the scheme beyond `v*`.
4. The ISO is never attached to the GitHub release, even while it fits under 2 GiB (it's at 1.94 GiB):
   R2 is the one download place. It waits as a workflow artifact for 30 days; publish within that or
   rebuild.
5. A difference nobody explained fails the release build; the rules live in `explain.tsv`.
6. **`[arch-held]`** (since 4.0.5): Omarchy's stable mirror can freeze between two archive snapshots.
   4.0.5's froze at 2026-10-18 00:22 UTC: the archive's 2026/10/17 day lacks 13 of its packages
   (linux 7.2.11, Mesa 26.2.5, LLVM …), and its 2026/10/18 day already has newer builds of 4
   (avahi, libcolord, libnotify, nmap), replaced that morning. So no day holds the whole set. The pin
   takes the day that holds the most, and puts each package it lacks that another walked day holds
   byte for byte into `[arch-held]`: a repo made from the ISO's own copy, listed ahead of
   core/extra/multilib (pacman takes a package from the first repo that has it). Arch-signed, checked
   with the default SigLevel. `pin.env` names each one and the day that holds it.
6. Release builds don't use the module cache, so every release log shows the stock module rebuilds
   matching the shipped modules (about 2 minutes).
7. `SOURCE_DATE_EPOCH` is the tagged commit's time (dates inside the image follow the commit).
8. publish.yml takes the trusted keys and scripts from the branch it runs on, not from the tag.
9. Three smoke tests, in parallel (3 VMs, 2 CPUs and 4 GB each: fits GitHub's 4-CPU/16 GB runners).
   No T2-kernel boot in QEMU yet.
