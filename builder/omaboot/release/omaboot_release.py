#!/usr/bin/env python3
"""OmaBoot? release tooling: pin a release to the official Omarchy ISO, build the pinned package
repos from it, inventory an ISO, and compare two inventories. Standard library only; needs
`unsquashfs` (squashfs-tools 4.6+), `repo-add` (pinned-repo) and mtools (inventory, for the EFI
partition). See README.md next to this file.

  omaboot_release.py pin ISO --version V --iso-url URL --base-commit C --build-image IMG \
      --build-date YYYY/MM/DD --out DIR [--cache DIR]
  omaboot_release.py check-pin ISO PINDIR
  omaboot_release.py pinned-repo ISO PINDIR OUTDIR
  omaboot_release.py inventory ISO OUTDIR
  omaboot_release.py diff OFFICIAL_INV OURS_INV --rules FILE --fork-changes FILE --out DIR
"""
import argparse, fnmatch, gzip, hashlib, io, json, os, re, shutil, stat, subprocess, sys, tarfile, tempfile
import time, urllib.error, urllib.request

SECTOR = 2048
MIRROR = 'var/cache/omarchy/mirror/offline'  # the installer's package mirror inside the root fs
SFS = 'arch/x86_64/airootfs.sfs'
ARCH_REPOS = ('core', 'extra', 'multilib')
ALA = 'https://archive.archlinux.org/repos'
OMARCHY_DB = 'https://pkgs.omarchy.org/stable/x86_64/omarchy.db'
OMARCHY_FILES = 'https://pkgs.omarchy.org/stable/x86_64/'
MACT2_DB = 'https://mirror.funami.tech/arch-mact2/os/x86_64/arch-mact2.db'
MACT2_FILES = 'https://mirror.funami.tech/arch-mact2/os/x86_64/'
UA = {'User-Agent': 'omaboot-release (OmaBoot? release pinning; rare, cached requests)'}


def die(msg):
    print('omaboot-release: ' + msg, file=sys.stderr)
    sys.exit(1)


def sha256_file(path, offset=0, size=None):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        f.seek(offset)
        left = size
        while True:
            n = 1 << 20 if left is None else min(1 << 20, left)
            if n == 0:
                break
            b = f.read(n)
            if not b:
                break
            h.update(b)
            if left is not None:
                left -= len(b)
    return h.hexdigest()


# ---- ISO 9660 (with Rock Ridge names) and the EFI partition --------------------------------


def iso_files(path):
    """Every file in the ISO 9660 tree: {path: (byte offset, size)}. Multi-extent files (over
    4 GiB, like the official airootfs.sfs) must be contiguous, which xorriso writes them as."""
    out = {}
    with open(path, 'rb') as f:
        sector = 16
        while True:
            f.seek(sector * SECTOR)
            vd = f.read(SECTOR)
            if vd[0] == 1 and vd[1:6] == b'CD001':
                break
            if vd[0] == 255 or sector > 64:
                die(f'{path}: no ISO 9660 primary volume descriptor')
            sector += 1
        root = vd[156:190]

        def walk(lba, size, prefix):
            f.seek(lba * SECTOR)
            data = f.read(size)
            i, pending = 0, {}
            while i < len(data):
                ln = data[i]
                if ln == 0:
                    i = (i // SECTOR + 1) * SECTOR
                    continue
                rec = data[i:i + ln]
                i += ln
                extent = int.from_bytes(rec[2:6], 'little')
                dsize = int.from_bytes(rec[10:14], 'little')
                flags, nlen = rec[25], rec[32]
                raw = rec[33:33 + nlen]
                if raw in (b'\x00', b'\x01'):
                    continue
                su = rec[33 + nlen + (1 - nlen % 2):]
                nm, j = b'', 0
                while j + 4 <= len(su):
                    sig, sl = su[j:j + 2], su[j + 2]
                    if sl == 0:
                        break
                    if sig == b'NM':
                        nm += su[j + 5:j + sl]
                    j += sl
                name = nm.decode() if nm else raw.decode('ascii', 'replace').split(';')[0].rstrip('.').lower()
                p = prefix + name
                if flags & 2:
                    walk(extent, dsize, p + '/')
                    continue
                if p in pending:  # a further extent of a multi-extent file
                    off, sz = pending[p]
                    if off + -(-sz // SECTOR) * SECTOR != extent * SECTOR:
                        die(f'{path}: {p} is split into extents that are not contiguous')
                    pending[p] = (off, sz + dsize)
                else:
                    pending[p] = (extent * SECTOR, dsize)
            out.update(pending)

        walk(int.from_bytes(root[2:6], 'little'), int.from_bytes(root[10:14], 'little'), '')
    return out


def esp_offset(path):
    """Byte offset and size of the EFI system partition (MBR type 0xEF, else the GPT ESP)."""
    with open(path, 'rb') as f:
        mbr = f.read(512)
        for i in range(4):
            e = mbr[446 + 16 * i:462 + 16 * i]
            if e[4] == 0xEF:
                return int.from_bytes(e[8:12], 'little') * 512, int.from_bytes(e[12:16], 'little') * 512
        f.seek(512)
        hdr = f.read(92)
        if hdr[:8] == b'EFI PART':
            lba, count, esz = int.from_bytes(hdr[72:80], 'little'), int.from_bytes(hdr[80:84], 'little'), int.from_bytes(hdr[84:88], 'little')
            f.seek(lba * 512)
            esp_guid = bytes.fromhex('28732ac11ff8d211ba4b00a0c93ec93b')
            for _ in range(count):
                e = f.read(esz)
                if e[:16] == esp_guid:
                    first, last = int.from_bytes(e[32:40], 'little'), int.from_bytes(e[40:48], 'little')
                    return first * 512, (last - first + 1) * 512
    return None


def sfs(iso):
    files = iso_files(iso)
    if SFS not in files:
        die(f'{iso}: no {SFS}')
    return files[SFS][0]


def unsquash_cat(iso, member):
    r = subprocess.run(['unsquashfs', '-o', str(sfs(iso)), '-cat', iso, member], capture_output=True)
    if r.returncode != 0:
        die(f'unsquashfs -cat {member}: {r.stderr.decode(errors="replace").strip()}')
    return r.stdout


def unsquash_list(iso, member):
    r = subprocess.run(['unsquashfs', '-o', str(sfs(iso)), '-lc', iso, member], capture_output=True, text=True)
    return [l.split('squashfs-root/', 1)[1] for l in r.stdout.splitlines() if 'squashfs-root/' in l]


# ---- pacman databases ----------------------------------------------------------------------


def read_db(data):
    """A pacman sync db (bytes) -> {filename: {name, version, sha256, ...}}"""
    pkgs = {}
    with tarfile.open(fileobj=__import__('io').BytesIO(data)) as t:
        for m in t.getmembers():
            if not m.name.endswith('/desc'):
                continue
            d, key = {}, None
            for line in t.extractfile(m).read().decode().splitlines():
                if line.startswith('%') and line.endswith('%'):
                    key = line.strip('%')
                    d[key] = []
                elif line and key:
                    d[key].append(line)
            g = lambda k: (d.get(k) or [''])[0]
            pkgs[g('FILENAME')] = {'name': g('NAME'), 'version': g('VERSION'), 'filename': g('FILENAME'), 'sha256': g('SHA256SUMS') or g('SHA256SUM')}
    return pkgs


def fetch(url, cache=None, ttl=None):
    """GET url (cached in `cache` when given; a cache entry older than ttl seconds is refetched)."""
    if cache:
        os.makedirs(cache, exist_ok=True)
        cp = os.path.join(cache, re.sub(r'[^A-Za-z0-9._-]', '_', url))
        if os.path.exists(cp) and (ttl is None or time.time() - os.path.getmtime(cp) < ttl):
            return open(cp, 'rb').read()
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=120) as r:
        data = r.read()
    if cache:
        open(cp + '.part', 'wb').write(data)
        os.replace(cp + '.part', cp)
    return data


def exists(url):
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=UA, method='HEAD'), timeout=60) as r:
            return r.status == 200
    except Exception:
        return False


# ---- pin -----------------------------------------------------------------------------------


def official_packages(iso):
    return read_db(unsquash_cat(iso, MIRROR + '/offline.db.tar.gz'))


def cmd_pin(a):
    """Write pins/<version>: which archive dates and repos reproduce the official ISO's packages."""
    iso = a.iso
    print(f'pin: hashing {iso}')
    iso_sha = sha256_file(iso)
    files = iso_files(iso)
    with open(iso, 'rb') as f:
        off, size = files['arch/version']
        f.seek(off)
        iso_date = f.read(size).decode().strip()  # 2026.09.15
    pkgs = official_packages(iso)
    print(f'pin: official ISO {iso_date}, {len(pkgs)} packages in its offline mirror')
    by_file = {p['filename']: p for p in pkgs.values()}
    omarchy_names = {p['name'] for p in read_db(fetch(OMARCHY_DB, a.cache, ttl=3600)).values()}
    mact2_names = {p['name'] for p in read_db(fetch(MACT2_DB, a.cache, ttl=3600)).values()}
    # Packages that should come from Arch: everything the Omarchy and arch-mact2 repos don't name today.
    arch_wanted = {fn for fn, p in by_file.items() if p['name'] not in omarchy_names | mact2_names}
    # The Arch Linux Archive day whose core/extra/multilib hold the most of the official packages,
    # byte for byte (the latest such day on a tie): walk back up to two weeks from the ISO's build
    # day, stopping early once a day holds every package the Omarchy and arch-mact2 repos don't name.
    y, m, d = (int(x) for x in iso_date.split('.'))
    best = None
    seen = {}  # file -> the latest day (of those walked) whose core/extra/multilib hold it, same checksum
    for back in range(0, 15):
        day = time.strftime('%Y/%m/%d', time.gmtime(time.mktime((y, m, d, 12, 0, 0, 0, 0, 0)) - back * 86400))
        repo_of = {}
        try:
            dbs = {repo: read_db(fetch(f'{ALA}/{day}/{repo}/os/x86_64/{repo}.db', a.cache)) for repo in ARCH_REPOS}
        except urllib.error.HTTPError as e:
            if e.code != 404:
                raise
            print(f'pin:   ALA {day}: not in the archive yet')  # an ISO built the day it's pinned
            continue
        for repo in ARCH_REPOS:
            for fn, p in dbs[repo].items():
                if fn in by_file and by_file[fn]['sha256'] == p['sha256']:
                    repo_of[fn] = repo
                    seen.setdefault(fn, day)
        print(f'pin:   ALA {day}: {len(repo_of)} of the official packages, same checksums')
        if best is None or len(repo_of) > len(best[1]):
            best = (day, repo_of)
        if arch_wanted <= set(repo_of):
            break
    day, repo_of = best
    manual = dict(x.split('=', 1) for x in a.repo or [])  # packages no repo serves any more
    unknown, held = [], {}
    for fn, p in sorted(by_file.items()):
        if fn in repo_of:
            continue
        if p['name'] in manual:
            repo_of[fn] = manual[p['name']]
        elif p['name'] in omarchy_names:
            repo_of[fn] = 'omarchy'
        elif p['name'] in mact2_names or exists(MACT2_FILES + fn):
            repo_of[fn] = 'arch-mact2'
        elif exists(OMARCHY_FILES + fn):
            repo_of[fn] = 'omarchy'
        elif fn in seen:
            # An Arch package that another archive day holds, byte for byte, but the chosen day
            # doesn't: Omarchy's stable mirror froze between two archive snapshots, and Arch
            # replaced it in between. The pinned [arch-held] repo serves the ISO's copy, ahead of
            # core/extra/multilib (pacman takes a package from the first repo that has it).
            repo_of[fn] = 'arch-held'
            held[fn] = seen[fn]
        else:
            unknown.append(fn)
    if unknown:
        die('no repo found for: ' + ' '.join(unknown) + ' (name its repo with --repo NAME=REPO)')
    node = [p for p in unsquash_list(iso, 'opt/packages') if re.search(r'node-v[0-9.]+-linux-x64\.tar\.gz$', p)]
    os.makedirs(a.out, exist_ok=True)
    with open(os.path.join(a.out, 'official-packages.tsv'), 'w') as f:
        f.write('# The official Omarchy %s ISO\'s package mirror (made by omaboot_release.py pin): name, version, file, sha256, repo\n' % a.version)
        for fn, p in sorted(by_file.items(), key=lambda kv: (kv[1]['name'], kv[0])):
            f.write('\t'.join((p['name'], p['version'], fn, p['sha256'], repo_of[fn])) + '\n')
    counts = {r: sum(1 for v in repo_of.values() if v == r) for r in (*ARCH_REPOS, 'arch-held', 'omarchy', 'arch-mact2')}
    manual_note = ''.join(f'\n# {n}: no repo serves it any more; classified by hand as {r}' for n, r in manual.items())
    held_note = ''
    if held:
        held_note = (f'\n# Arch packages ({counts["arch-held"]}) the archive day above has newer builds of: Arch replaced them'
                     f'\n# after the official ISO\'s package snapshot, so they come from the ISO too, in [arch-held]'
                     f'\n# (ahead of core/extra/multilib), each the same file as on the archive day named')
        held_note += ''.join(f'\n# {by_file[fn]["name"]} {by_file[fn]["version"]}: as on {d}' for fn, d in sorted(held.items()))
    pinned_repos = ' '.join(r for r in ('arch-held', 'omarchy', 'arch-mact2') if r != 'arch-held' or held)
    with open(os.path.join(a.out, 'pin.env'), 'w') as f:
        f.write(f'''# OmaBoot? release pin for Omarchy {a.version} (made by omaboot_release.py pin; see ../../README.md)
OMARCHY_VERSION={a.version}
# The official ISO: where it is, its checksum (from {a.iso_url}.sha256) and the omarchy-iso commit it was built from
OFFICIAL_ISO_URL={a.iso_url}
OFFICIAL_ISO_SHA256={iso_sha}
OFFICIAL_ISO_DATE={iso_date}
OFFICIAL_ISO_COMMIT={a.base_commit}
# Arch packages: the Arch Linux Archive day that holds the most of the official ISO's (every one but
# any in [arch-held] below), same checksums
# ({counts["core"]} core, {counts["extra"]} extra, {counts["multilib"]} multilib)
ARCH_ARCHIVE_DATE={day}
# Omarchy ({counts["omarchy"]}) and t2linux arch-mact2 ({counts["arch-mact2"]}) packages: neither repo keeps a dated archive, so
# they come from the official ISO itself (official-packages.tsv, checked by sha256){manual_note}{held_note}
PINNED_REPOS="{pinned_repos}"
# The build container: the Arch image and archive day of the official ISO's build day (archiso, grub, ...)
BUILD_IMAGE={a.build_image}
BUILD_ARCHIVE_DATE={a.build_date}
# Node.js tarball the official ISO carries for offline mise installs
NODE_VERSION={re.search(r"node-(v[0-9.]+)-", node[0]).group(1) if node else ""}
''')
    print(f'pin: wrote {a.out}: ALA {day}, ' + ', '.join(f'{k} {v}' for k, v in counts.items()))


def load_pin(pindir):
    env = {}
    for line in open(os.path.join(pindir, 'pin.env')):
        line = line.strip()
        if line and not line.startswith('#') and '=' in line:
            k, v = line.split('=', 1)
            env[k] = v.strip('"')
    rows = []
    for line in open(os.path.join(pindir, 'official-packages.tsv')):
        if line.startswith('#') or not line.strip():
            continue
        name, version, fn, sha, repo = line.rstrip('\n').split('\t')
        rows.append({'name': name, 'version': version, 'filename': fn, 'sha256': sha, 'repo': repo})
    return env, rows


def cmd_check_pin(a):
    """The ISO is the pin's official ISO, and its package mirror is exactly the pinned list."""
    env, rows = load_pin(a.pindir)
    got = sha256_file(a.iso)
    if got != env['OFFICIAL_ISO_SHA256']:
        die(f'{a.iso}: sha256 {got}, the pin says {env["OFFICIAL_ISO_SHA256"]}')
    pkgs = official_packages(a.iso)
    want = {r['filename']: r['sha256'] for r in rows}
    have = {fn: p['sha256'] for fn, p in pkgs.items()}
    if want != have:
        die(f'the official ISO\'s package mirror differs from {a.pindir}/official-packages.tsv '
            f'({len(set(want.items()) ^ set(have.items()))} differences)')
    print(f'check-pin: {os.path.basename(a.iso)} is the pinned official ISO; its {len(have)} packages match the pin')


def cmd_pinned_repo(a):
    """Pacman repos (omarchy, arch-mact2, arch-held) holding exactly the pinned packages, from the official ISO."""
    env, rows = load_pin(a.pindir)
    cmd_check_pin(a)
    off = sfs(a.iso)
    for repo in env.get('PINNED_REPOS', 'omarchy arch-mact2').split():
        sel = [r for r in rows if r['repo'] == repo]
        dst = os.path.join(a.outdir, repo)
        if os.path.exists(dst):
            die(f'{dst} exists already')
        tmp = tempfile.mkdtemp(prefix=f'pinned-{repo}-')
        listing = os.path.join(tmp, 'extract.txt')
        wanted = [f'{MIRROR}/{r["filename"]}' for r in sel] + [f'{MIRROR}/{r["filename"]}.sig' for r in sel]
        open(listing, 'w').write('\n'.join(wanted) + '\n')
        subprocess.run(['unsquashfs', '-q', '-n', '-o', str(off), '-d', os.path.join(tmp, 'root'), '-ef', listing, a.iso], check=True,
                       stdout=subprocess.DEVNULL)
        os.makedirs(dst)
        for r in sel:
            src = os.path.join(tmp, 'root', MIRROR, r['filename'])
            if sha256_file(src) != r['sha256']:
                die(f'{r["filename"]}: checksum differs from the pin')
            shutil.move(src, os.path.join(dst, r['filename']))
            if os.path.exists(src + '.sig'):
                shutil.move(src + '.sig', os.path.join(dst, r['filename'] + '.sig'))
        subprocess.run(['repo-add', '-q', os.path.join(dst, f'{repo}.db.tar.gz')] + [os.path.join(dst, r['filename']) for r in sel], check=True)
        print(f'pinned-repo: [{repo}] {len(sel)} packages from the official ISO -> {dst}')


# ---- inventory -----------------------------------------------------------------------------


def walk_tree(root):
    """{path: (type, mode, uid, gid, size, sha256 or link target)} under root, relative paths."""
    out = {}
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for n in sorted(dirnames) + sorted(filenames):
            p = os.path.join(dirpath, n)
            rel = os.path.relpath(p, root)
            st = os.lstat(p)
            mode = stat.S_IMODE(st.st_mode)
            if stat.S_ISLNK(st.st_mode):
                out[rel] = ('l', mode, st.st_uid, st.st_gid, 0, os.readlink(p))
            elif stat.S_ISDIR(st.st_mode):
                out[rel] = ('d', mode, st.st_uid, st.st_gid, 0, '')
            elif stat.S_ISREG(st.st_mode):
                out[rel] = ('f', mode, st.st_uid, st.st_gid, st.st_size, sha256_file(p))
            else:
                out[rel] = ('o', mode, st.st_uid, st.st_gid, 0, oct(st.st_mode))
    return out


def write_tsv(path, entries):
    with open(path, 'w') as f:
        for p in sorted(entries):
            t, mode, uid, gid, size, x = entries[p]
            f.write(f'{p}\t{t}\t{mode:04o}\t{uid}\t{gid}\t{size}\t{x}\n')


def read_tsv(path):
    out = {}
    for line in open(path):
        p, t, mode, uid, gid, size, x = line.rstrip('\n').split('\t')
        out[p] = (t, int(mode, 8), int(uid), int(gid), int(size), x)
    return out


def cmd_inventory(a):
    """ISO -> OUTDIR: iso.tsv (ISO 9660 files), esp.tsv (EFI partition), rootfs.tsv (the root file
    system, without the installer's package mirror), packages.json (installed packages, their
    files and dependencies), mirror.json (the package mirror, if any), info.json."""
    iso = a.iso
    os.makedirs(a.outdir, exist_ok=True)
    files = iso_files(iso)
    with open(iso, 'rb') as f:
        ent = {}
        for p, (off, size) in files.items():
            if p == SFS:
                continue
            f.seek(off)
            h = hashlib.sha256()
            left = size
            while left:
                b = f.read(min(1 << 20, left))
                h.update(b)
                left -= len(b)
            ent[p] = ('f', 0o444, 0, 0, size, h.hexdigest())
    write_tsv(os.path.join(a.outdir, 'iso.tsv'), ent)
    work = tempfile.mkdtemp(prefix='inventory-')
    esp = esp_offset(iso)
    esp_ent = {}
    if esp:
        d = os.path.join(work, 'esp')
        os.makedirs(d)
        subprocess.run(['mcopy', '-s', '-n', '-p', '-i', f'{iso}@@{esp[0]}', '::/', d], check=True, env={**os.environ, 'MTOOLS_SKIP_CHECK': '1'})
        esp_ent = {p: (t, 0o644 if t == 'f' else 0o755, 0, 0, s, x) for p, (t, _, _, _, s, x) in walk_tree(d).items()}
    write_tsv(os.path.join(a.outdir, 'esp.tsv'), esp_ent)
    root = os.path.join(work, 'root')
    excl = os.path.join(work, 'exclude.txt')
    open(excl, 'w').write(MIRROR + '\n')
    off = files[SFS][0]
    subprocess.run(['unsquashfs', '-q', '-n', '-no-xattrs', '-o', str(off), '-d', root, '-exclude-file', excl, iso], check=True, stdout=subprocess.DEVNULL)
    tree = walk_tree(root)
    write_tsv(os.path.join(a.outdir, 'rootfs.tsv'), tree)
    pk = {}
    local = os.path.join(root, 'var/lib/pacman/local')
    for d in sorted(os.listdir(local)) if os.path.isdir(local) else []:
        desc = os.path.join(local, d, 'desc')
        if not os.path.exists(desc):
            continue
        fields, key = {}, None
        for fn in ('desc', 'files'):
            if not os.path.exists(os.path.join(local, d, fn)):
                continue
            for line in open(os.path.join(local, d, fn), errors='replace').read().splitlines():
                if line.startswith('%') and line.endswith('%'):
                    key = line.strip('%')
                    fields[key] = []
                elif line and key:
                    fields[key].append(line)
        strip = lambda deps: sorted({re.split(r'[<>=:]', x, maxsplit=1)[0].strip() for x in deps})
        pk[fields['NAME'][0]] = {'version': fields['VERSION'][0], 'files': [x.rstrip('/') for x in fields.get('FILES', [])],
                                 'depends': strip(fields.get('DEPENDS', [])), 'provides': strip(fields.get('PROVIDES', [])),
                                 'reason': 'dependency' if fields.get('REASON', ['0'])[0] == '1' else 'explicit'}
    json.dump(pk, open(os.path.join(a.outdir, 'packages.json'), 'w'), indent=0, sort_keys=True)
    mirror = {}
    r = subprocess.run(['unsquashfs', '-o', str(off), '-cat', iso, MIRROR + '/offline.db.tar.gz'], capture_output=True)
    if r.returncode == 0 and r.stdout:
        mirror = {p['name']: {'version': p['version'], 'filename': fn, 'sha256': p['sha256']} for fn, p in read_db(r.stdout).items()}
    json.dump(mirror, open(os.path.join(a.outdir, 'mirror.json'), 'w'), indent=0, sort_keys=True)
    info = {'iso': os.path.basename(iso), 'sha256': sha256_file(iso), 'bytes': os.path.getsize(iso),
            'rootfs_entries': len(tree), 'iso_files': len(ent), 'esp_files': len(esp_ent), 'packages': len(pk), 'mirror_packages': len(mirror)}
    json.dump(info, open(os.path.join(a.outdir, 'info.json'), 'w'), indent=1, sort_keys=True)
    print(f'inventory: {info["iso"]}: {len(tree)} root fs entries, {len(ent)} ISO files, {len(esp_ent)} EFI files, {len(pk)} packages'
          + (f', {len(mirror)} in its package mirror' if mirror else ''))


# ---- diff ----------------------------------------------------------------------------------


def load_rules(path):
    """explain.tsv: AREA <tab> PATTERN <tab> CATEGORY <tab> EXPLANATION (AREA: rootfs, iso, esp,
    package); patterns are fnmatch patterns, the first match wins."""
    rules = []
    for line in open(path):
        if line.startswith('#') or not line.strip():
            continue
        area, pat, cat, why = line.rstrip('\n').split('\t')
        rules.append((area, pat, cat, why))
    return rules


def match_rule(rules, area, path):
    for ar, pat, cat, why in rules:
        if ar == area and fnmatch.fnmatchcase(path, pat):
            return cat, why
    return None


def describe(a, b):
    if a is None:
        return 'added'
    if b is None:
        return 'removed'
    what = []
    if a[0] != b[0]:
        what.append(f'type {a[0]}->{b[0]}')
    if a[1] != b[1]:
        what.append(f'mode {a[1]:04o}->{b[1]:04o}')
    if (a[2], a[3]) != (b[2], b[3]):
        what.append(f'owner {a[2]}:{a[3]}->{b[2]}:{b[3]}')
    if a[5] != b[5] or a[4] != b[4]:
        what.append('link target' if a[0] == 'l' else 'content')
    return 'changed: ' + ', '.join(what)


def cmd_diff(a):
    O, U = a.official, a.ours
    rules = load_rules(a.rules)
    fork = {}
    if a.fork_changes and os.path.exists(a.fork_changes):
        for line in open(a.fork_changes):
            if line.strip():
                area, path, why = line.rstrip('\n').split('\t', 2)
                fork[(area, path)] = why
    po, pu = json.load(open(f'{O}/packages.json')), json.load(open(f'{U}/packages.json'))
    info_o, info_u = json.load(open(f'{O}/info.json')), json.load(open(f'{U}/info.json'))
    mirror_o = json.load(open(f'{O}/mirror.json'))

    # packages: added, removed, changed (live root fs package sets)
    added = sorted(set(pu) - set(po))
    removed = sorted(set(po) - set(pu))
    changed = sorted(n for n in set(po) & set(pu) if po[n]['version'] != pu[n]['version'])
    roots = {}
    for n in added:
        r = match_rule(rules, 'package', n)
        if r:
            roots[n] = r
    # the dependency closure of each explained root, over our packages (by name or provides)
    provider = {}
    for n, p in pu.items():
        provider.setdefault(n, n)
        for v in p['provides']:
            provider.setdefault(v, n)
    why_pkg = {}
    for root, (cat, why) in roots.items():
        why_pkg.setdefault(root, (cat, why))
        stack = [root]
        seen = {root}
        while stack:
            for dep in pu[stack.pop()]['depends']:
                q = provider.get(dep)
                if q and q not in seen:
                    seen.add(q)
                    stack.append(q)
                    if q in added:
                        why_pkg.setdefault(q, ('ours', f'dependency of {root}'))
    # and the packages the live edition leaves out: each one a rule names, with the dependencies
    # only left-out packages needed (over the official set, by name or provides)
    provider_o = {}
    for n, p in po.items():
        provider_o.setdefault(n, n)
        for v in p['provides']:
            provider_o.setdefault(v, n)
    why_gone = {}
    for n in removed:
        r = match_rule(rules, 'package-removed', n)
        if r:
            why_gone[n] = r
    for root in [n for n in removed if n in why_gone]:
        stack, seen = [root], {root}
        while stack:
            for dep in po[stack.pop()]['depends']:
                q = provider_o.get(dep)
                if q and q not in seen:
                    seen.add(q)
                    stack.append(q)
                    if q in removed:
                        why_gone.setdefault(q, ('ours', f'only packages the live edition leaves out needed it (e.g. {root})'))
    pkg_rows = []
    for n in added:
        cat, why = why_pkg.get(n, ('unexplained', 'added, but no OmaBoot? package needs it'))
        pkg_rows.append((n, '', pu[n]['version'], 'added', cat, why))
    for n in removed:
        cat, why = why_gone.get(n, ('unexplained', 'in the official live system, not in ours'))
        pkg_rows.append((n, po[n]['version'], '', 'removed', cat, why))
    for n in changed:
        pkg_rows.append((n, po[n]['version'], pu[n]['version'], 'changed', 'unexplained', 'version differs from the official ISO: the pin failed'))

    # files
    owner_o = {f: n for n, p in po.items() for f in p['files']}
    owner_u = {f: n for n, p in pu.items() for f in p['files']}
    rows = []
    for area in ('iso', 'esp', 'rootfs'):
        A, B = read_tsv(f'{O}/{area}.tsv'), read_tsv(f'{U}/{area}.tsv')
        for path in sorted(set(A) | set(B)):
            x, y = A.get(path), B.get(path)
            if x == y:
                continue
            if area != 'rootfs' and x and y and x[4:] == y[4:]:
                continue  # same content; the FAT/ISO metadata isn't compared
            status = describe(x, y)
            cat = why = None
            if area == 'rootfs':
                ou, oo = owner_u.get(path), owner_o.get(path)
                # a path several packages own (a shared directory) is the left-out package's when
                # that's what the official owner was
                pkg = oo if oo in removed and ou not in added else (ou or oo)
                if pkg and ((ou and ou in added) or (oo and oo in removed) or (pkg in changed)):
                    pcat, pwhy = why_pkg.get(pkg, ('unexplained', 'package change')) if pkg in added else \
                        (('ours', 'package not in the live edition') if pkg in removed else ('unexplained', 'package version differs'))
                    cat = 'package' if pcat != 'unexplained' else 'unexplained'
                    why = f'{"added" if pkg in added else "removed" if pkg in removed else "changed"} package {pkg}: {pwhy}'
                    if cat == 'unexplained':
                        cat = why = None  # a rule may still explain it (a directory NoExtract emptied)
            if cat is None:
                r = match_rule(rules, area, path)
                if r:
                    cat, why = r
            if cat is None and (area, path) in fork:
                cat, why = 'ours', fork[(area, path)]
            if cat is None:
                cat, why = 'unexplained', 'no rule explains this difference'
            rows.append((area, path, status, cat, why))

    os.makedirs(a.out, exist_ok=True)
    # gzip'd: one row per path is tens of thousands of rows (owner, 2026-10-14); no name or date in
    # the header, so the same report makes the same file
    with open(os.path.join(a.out, 'diff-report.tsv.gz'), 'wb') as raw, \
            gzip.GzipFile(filename='', fileobj=raw, mode='wb', compresslevel=9, mtime=0) as gz, \
            io.TextIOWrapper(gz, encoding='utf-8') as f:
        f.write('# area\tpath\tdifference\tcategory\texplanation\n')
        for r in pkg_rows:
            f.write(f'package\t{r[0]}\t{r[3]} {r[1] or "-"} -> {r[2] or "-"}\t{r[4]}\t{r[5]}\n')
        for r in rows:
            f.write('\t'.join(r) + '\n')
    unexplained = [r for r in rows if r[3] == 'unexplained'] + [r for r in pkg_rows if r[4] == 'unexplained']
    ctx = dict(kv.split('=', 1) for kv in a.context or [])
    md = []
    w = md.append
    w(f'# OmaBoot? Live {ctx.get("tag", "")} against the official Omarchy {ctx.get("omarchy", "")} ISO\n')
    w('| | Official Omarchy ISO | OmaBoot? Live |')
    w('|---|---|---|')
    w(f'| File | `{info_o["iso"]}` | `{info_u["iso"]}` |')
    w(f'| SHA-256 | `{info_o["sha256"]}` | `{info_u["sha256"]}` |')
    w(f'| Size | {info_o["bytes"]:,} bytes | {info_u["bytes"]:,} bytes |')
    w(f'| omarchy-iso commit | {ctx.get("official_commit", "?")} | {ctx.get("fork_commit", "?")} (fork of {ctx.get("official_commit", "?")}) |')
    w(f'| Packages in the live root file system | {len(po)} | {len(pu)} |')
    w(f'| Installer package mirror | {len(mirror_o)} packages | none (the live edition has no installer) |\n')
    if ctx.get('official_signature'):
        w(f'Official ISO signature: {ctx["official_signature"]}\n')
    cats = {}
    for r in rows:
        cats[r[3]] = cats.get(r[3], 0) + 1
    w('## Summary\n')
    w(f'- Packages: {len(added)} added, {len(removed)} removed, {len(changed)} with a different version.')
    w(f'- Files that differ: {len(rows)} ({", ".join(f"{v} {k}" for k, v in sorted(cats.items()))}).')
    w(f'- **Unexplained: {len(unexplained)}.**' + (' Every difference is accounted for.' if not unexplained else ' See below.'))
    w(f'- Not compared file by file: the official ISO\'s installer package mirror (`/{MIRROR}`, {len(mirror_o)} packages); every '
      'package in our image is checked against it by checksum instead (packages.tsv).')
    w('- Ignored everywhere: timestamps. Compared: type, permissions, owner, size, content (SHA-256), link targets.\n')
    w('Categories: **ours** = an OmaBoot? change (the tester, patched modules, boot menu, splash, configuration); **package** = '
      'a file of a package the live edition adds or leaves out; **generated** = written at build time from the installed '
      'packages (caches, indexes, keyrings, initramfs); **unexplained** = no rule accounts for it.\n')
    if unexplained:
        w('## Unexplained\n')
        w('| Area | Path | Difference | Note |')
        w('|---|---|---|---|')
        for r in unexplained:
            if len(r) == 5:
                w(f'| {r[0]} | `{r[1]}` | {r[2]} | {r[4]} |')
            else:
                w(f'| package | `{r[0]}` | {r[3]} {r[1] or "-"} → {r[2] or "-"} | {r[5]} |')
        w('')
    w('## Packages\n')
    if pkg_rows:
        w('Compared: the packages installed in each live root file system. "Official ISO" says whether the official ISO '
          'carries the same version in its installer mirror (packages.tsv checks the very file, by SHA-256).\n')
        w('| Package | Official live | Ours | | In the official ISO | Why |')
        w('|---|---|---|---|---|---|')
        for n, vo, vu, st, cat, why in pkg_rows:
            m = mirror_o.get(n)
            inofficial = 'installer mirror, same version' if m and vu and m['version'] == vu else ('installer mirror, other version' if m else 'no')
            w(f'| {n} | {vo or "—"} | {vu or "—"} | {st} | {inofficial} | {why} |')
    else:
        w('Same packages, same versions.')
    w('')
    for area, title in (('iso', 'ISO 9660 files'), ('esp', 'EFI system partition'), ('rootfs', 'Root file system')):
        sub = [r for r in rows if r[0] == area]
        w(f'## {title}\n')
        if not sub:
            w('No differences.\n')
            continue
        # one row per difference; a reason shared by more than 6 (package files, pacman's records)
        # gets one row here, and every path is in diff-report.tsv.gz
        by_why = {}
        for r in sub:
            by_why.setdefault((r[3], r[4]), []).append(r)
        w('| Path | Difference | Category | Explanation |')
        w('|---|---|---|---|')
        for r in sub:
            group = by_why[(r[3], r[4])]
            if r[3] != 'unexplained' and (r[3] == 'package' or len(group) > 6):
                if group[0] is r:
                    kinds = sorted({x[2] for x in group})
                    w(f'| {len(group)} paths, e.g. `{group[0][1]}` | {", ".join(kinds)} | {r[3]} | {r[4]} |')
                continue
            w(f'| `{r[1]}` | {r[2]} | {r[3]} | {r[4]} |')
        w('')
    open(os.path.join(a.out, 'diff-report.md'), 'w').write('\n'.join(md) + '\n')
    print(f'diff: {len(rows)} file differences, {len(pkg_rows)} package differences, {len(unexplained)} unexplained')
    for r in unexplained[:40]:
        print('  unexplained: ' + ' | '.join(str(x) for x in r))
    if unexplained and a.strict:
        sys.exit(2)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest='cmd', required=True)
    p = sp.add_parser('pin')
    p.add_argument('iso')
    for k in ('--version', '--iso-url', '--base-commit', '--build-image', '--build-date', '--out'):
        p.add_argument(k, required=True)
    p.add_argument('--cache')
    p.add_argument('--repo', action='append', help='NAME=REPO for a package no repo serves any more')
    p = sp.add_parser('check-pin')
    p.add_argument('iso')
    p.add_argument('pindir')
    p = sp.add_parser('pinned-repo')
    p.add_argument('iso')
    p.add_argument('pindir')
    p.add_argument('outdir')
    p = sp.add_parser('inventory')
    p.add_argument('iso')
    p.add_argument('outdir')
    p = sp.add_parser('diff')
    p.add_argument('official')
    p.add_argument('ours')
    p.add_argument('--rules', required=True)
    p.add_argument('--fork-changes')
    p.add_argument('--out', required=True)
    p.add_argument('--context', action='append')
    p.add_argument('--strict', action='store_true', help='exit 2 when anything is unexplained')
    a = ap.parse_args()
    {'pin': cmd_pin, 'check-pin': cmd_check_pin, 'pinned-repo': cmd_pinned_repo, 'inventory': cmd_inventory, 'diff': cmd_diff}[a.cmd](a)


if __name__ == '__main__':
    main()
