#!/usr/bin/env python3
"""Boot a dev ISO in QEMU (UEFI, KVM) with a signed BOOTLIVE test drive and screenshot the boot.

  smoke.py ISO OUTDIR

The ISO and a small FAT drive labelled BOOTLIVE (holding the signed payload from payload/) are
attached as USB sticks, like on a Mac. GRUB picks its default "OmaBoot? Live" entry after its 5 s
countdown; the hook should verify and run the payload, which prints a marker on the serial port
and writes results/smoke.txt to the drive; then the installer starts.

The payload is signed afresh with the dev key when this machine has it (OMABOOT_DEV_KEY, default
/etc/omaboot/omaboot-dev on the dev build runner), so every build exercises dev signing; otherwise the
committed signature is used.

Writes OUTDIR/shot-SSS.png every 2 s whenever the screen changed, serial.log and summary.txt.
Exits 0 when the marker appeared and the drive got its results file.

Options (environment): OMABOOT_SMOKE_PRODUCT=MacBookPro16,1 reports that SMBIOS model, to check
the live image's kernel pick; OMABOOT_SMOKE_NO_DRIVE=1 boots without the BOOTLIVE drive and just
takes screenshots for SECONDS (default 150), to see what runs without a stick. Without access to
/dev/kvm it falls back to (slow) software emulation.

OMABOOT_SMOKE_TOOL=1 tests the boot-live tester on a live image instead: an empty BOOTLIVE drive
(so the hook finds nothing signed and the built-in tester runs), a firmware flag that makes it run
unattended (--auto), and the SMBIOS of a MacBookAir5,2 (or OMABOOT_SMOKE_PRODUCT / _BOARD). PASS
when it reports "OMABOOT-AUTO: submitted" (to staging, through QEMU's user network) or "saved" on
the serial port. With OMABOOT_SMOKE_ROOM=1 as well, the stick is a writable copy of the ISO with
room after it, and there's no network and no BOOTLIVE drive: PASS when the tester made the OMABOOT
partition on the stick itself (at its end) and saved its report there, and, after the image is
written over the stick again, a second boot found that partition, put it back in the table and
saved a second report beside the first (serial-2.log, b2-shot-SSS.png).

Release images (builder/omaboot/release): OMABOOT_SMOKE_NO_SUBMIT=1 keeps every report in the VM:
the network is QEMU's user network with restrict=on (a link and DHCP, no way out), and a run that says
"submitted" fails. OMABOOT_SMOKE_EXPECT_REFUSE=1 (with OMABOOT_SMOKE_TOOL=1) puts the dev-signed
payload on the BOOTLIVE drive of an image that trusts only the release keys: PASS when the hook
refused it (no marker, no results/smoke.txt) and the built-in tester then ran and saved its report.
"""
import hashlib, json, os, shutil, socket, subprocess, sys, time

ISO, OUT = sys.argv[1], sys.argv[2]
HERE = os.path.dirname(os.path.abspath(__file__))
OVMF_CODE, OVMF_VARS = '/usr/share/OVMF/OVMF_CODE_4M.fd', '/usr/share/OVMF/OVMF_VARS_4M.fd'
MARKER = 'OMABOOT-SMOKE'
LIMIT, AFTER_MARKER = 240, 45  # seconds: give up after LIMIT; keep shooting AFTER_MARKER for the installer
TOOL = os.environ.get('OMABOOT_SMOKE_TOOL', '') == '1'
PRODUCT = os.environ.get('OMABOOT_SMOKE_PRODUCT', 'MacBookAir5,2' if TOOL else '')
BOARD = os.environ.get('OMABOOT_SMOKE_BOARD', 'Mac-2E6FAB96566FE58C' if TOOL else '')
if TOOL:
    MARKER, LIMIT, AFTER_MARKER = 'OMABOOT-AUTO:', 420, 15
NO_DRIVE = os.environ.get('OMABOOT_SMOKE_NO_DRIVE', '') == '1'
ROOM = TOOL and os.environ.get('OMABOOT_SMOKE_ROOM', '') == '1'
NO_SUBMIT = os.environ.get('OMABOOT_SMOKE_NO_SUBMIT', '') == '1'
REFUSE = TOOL and os.environ.get('OMABOOT_SMOKE_EXPECT_REFUSE', '') == '1'
KVM = os.access('/dev/kvm', os.R_OK | os.W_OK)
if NO_DRIVE:
    LIMIT = int(os.environ.get('OMABOOT_SMOKE_SECONDS', '150'))
if not KVM:
    LIMIT *= 4

os.makedirs(OUT, exist_ok=True)
work = os.path.join(OUT, 'work')
os.makedirs(work, exist_ok=True)
drive, vars_, sock, serial = (os.path.join(work, n) for n in ('bootlive.img', 'vars.fd', 'qmp.sock', 'serial.log'))

# the BOOTLIVE drive: FAT32 with the signed payload
payload = os.path.join(work, 'payload')
shutil.copytree(os.path.join(HERE, 'payload'), payload, dirs_exist_ok=True)
dev_key = os.environ.get('OMABOOT_DEV_KEY', '/etc/omaboot/omaboot-dev')
signed_with = 'committed signature'
if os.access(dev_key, os.R_OK):
    signed_with = f'signed now with {dev_key}'
    subprocess.run(['bash', os.path.join(HERE, '..', 'tools', 'sign-bootlive.sh'), payload, dev_key], check=True)
subprocess.run(['mkfs.fat', '-C', '-F', '32', '-n', 'BOOTLIVE', drive, str(64 * 1024)], check=True, capture_output=True)
for f in [] if TOOL and not REFUSE else sorted(os.listdir(payload)):
    subprocess.run(['mcopy', '-i', drive, os.path.join(payload, f), '::/'], check=True)
shutil.copy(OVMF_VARS, vars_)
stick = ISO
if ROOM:  # a 4 GB "stick": the image, then free space
    stick = os.path.join(work, 'stick.img')
    shutil.copy(ISO, stick)
    os.truncate(stick, 4 << 30)


def boot(serial, tag=''):
    """One boot of the VM: its serial port to serial, screenshots as OUT/<tag>shot-SSS.png.
    Returns when the marker was seen, the screenshots and QEMU's stderr."""
    for f in (sock, serial):
        if os.path.exists(f):
            os.remove(f)
    args = ['qemu-system-x86_64'] + (['-enable-kvm', '-cpu', 'host'] if KVM else ['-accel', 'tcg', '-cpu', 'max']) + [
        '-machine', 'q35', '-smp', '2', '-m', '4096',
        '-drive', f'if=pflash,format=raw,readonly=on,file={OVMF_CODE}', '-drive', f'if=pflash,format=raw,file={vars_}',
        '-device', 'qemu-xhci',
        '-drive', f'if=none,id=iso,format=raw,readonly={"off" if ROOM else "on"},file={stick}', '-device', 'usb-storage,drive=iso,bootindex=1',
        '-vga', 'std', '-display', 'none', '-serial', f'file:{serial}', '-qmp', f'unix:{sock},server=on,wait=off',
    ]
    if ROOM:
        args += ['-nic', 'none']
    elif NO_SUBMIT:
        args += ['-nic', 'user,restrict=on']
    if not ROOM and not NO_DRIVE:
        args += ['-drive', f'if=none,id=bl,format=raw,file={drive}', '-device', 'usb-storage,drive=bl']
    if PRODUCT:
        args += ['-smbios', 'type=1,manufacturer=QEMU,product=' + PRODUCT.replace(',', ',,')]
    if BOARD:
        args += ['-smbios', 'type=2,manufacturer=QEMU,product=' + BOARD.replace(',', ',,')]
    if TOOL:
        args += ['-fw_cfg', 'name=opt/omaboot/auto,string=1']
    qemu = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

    for _ in range(50):
        if os.path.exists(sock):
            break
        time.sleep(0.1)
    q = socket.socket(socket.AF_UNIX)
    q.connect(sock)
    qf = q.makefile('rw')


    def qmp(cmd, **args):
        qf.write(json.dumps({'execute': cmd, 'arguments': args} if args else {'execute': cmd}) + '\n')
        qf.flush()
        while True:
            r = json.loads(qf.readline())
            if 'return' in r or 'error' in r:
                return r


    json.loads(qf.readline())  # greeting
    qmp('qmp_capabilities')

    start, last, marker_at, shots = time.time(), None, None, []
    while time.time() - start < LIMIT:
        t = int(time.time() - start)
        tmp = os.path.join(work, 'shot.png')
        if 'return' in qmp('screendump', filename=tmp, format='png') and os.path.exists(tmp):
            h = hashlib.sha256(open(tmp, 'rb').read()).hexdigest()
            if h != last:
                dst = os.path.join(OUT, f'{tag}shot-{t:03d}.png')
                os.replace(tmp, dst)
                shots.append(os.path.basename(dst))
                last = h
        if marker_at is None and os.path.exists(serial) and MARKER in open(serial, errors='replace').read():
            marker_at = t
        if marker_at is not None and t - marker_at >= AFTER_MARKER:
            break
        if qemu.poll() is not None:
            break
        time.sleep(2)

    try:
        qmp('quit')
    except Exception:
        pass
    try:
        qemu.wait(10)
    except subprocess.TimeoutExpired:
        qemu.kill()

    qerr = qemu.stderr.read().decode(errors='replace').strip() if qemu.stderr else ''
    return marker_at, shots, qerr


marker_at, shots, qerr = boot(serial)
shutil.copy(serial, os.path.join(OUT, 'serial.log')) if os.path.exists(serial) else None
results = subprocess.run(['mtype', '-i', drive, '::/results/smoke.txt'], capture_output=True, text=True)
ok = marker_at is not None and results.returncode == 0
auto_line = ''
if TOOL:  # the tester's own verdict line on the serial port
    seen = open(os.path.join(OUT, 'serial.log'), errors='replace').read() if os.path.exists(os.path.join(OUT, 'serial.log')) else ''
    lines = [l.strip() for l in seen.splitlines() if 'OMABOOT-AUTO:' in l]
    auto_line = lines[-1] if lines else ''
    ok = bool(auto_line) and (' submitted ' in auto_line + ' ' or ' saved ' in auto_line + ' ')
    if NO_SUBMIT and ' submitted ' in auto_line + ' ':
        ok = False
        auto_line += '  [FAIL: submitted although this run must not]'
refused = ''
if REFUSE:  # the dev-signed payload must not have run
    hook_ran = 'OMABOOT-SMOKE' in (open(os.path.join(OUT, 'serial.log'), errors='replace').read() if os.path.exists(os.path.join(OUT, 'serial.log')) else '')
    refused = 'yes' if not hook_ran and results.returncode != 0 else 'NO: the image ran a payload signed with the dev key'
    ok = ok and refused == 'yes'
room = ''


def room_state():
    """Slot 3 of the stick's MBR, its FAT label and the reports in its results/."""
    e = open(stick, 'rb').read(512)[446 + 32:446 + 48]
    start, count = int.from_bytes(e[8:12], 'little'), int.from_bytes(e[12:16], 'little')
    found = subprocess.run(['mdir', '-b', '-i', f'{stick}@@{start * 512}', '::/results'], capture_output=True, text=True) if count else None
    files = [l for l in (found.stdout.splitlines() if found and found.returncode == 0 else []) if l.endswith('.json')]
    label = subprocess.run(['mlabel', '-s', '-i', f'{stick}@@{start * 512}', '::'], capture_output=True, text=True).stdout.strip() if count else ''
    return e[4], start, count, label, files


if ROOM:  # the tester made OMABOOT on the stick itself and saved its report there
    kind, start, count, label, files = room_state()
    room = f'slot 3: type 0x{kind:02x}, {count * 512 >> 20} MiB at sector {start}; {label or "no label"}; reports: {" ".join(files) or "none"}'
    ok = ok and ' saved ' in auto_line + ' ' and kind in (0x0c, 0x0e) and 'OMABOOT' in label and bool(files)  # FAT16 since boot-live 0.6.5 (32 MiB), FAT32 before
    ok = ok and start * 512 >= os.path.getsize(ISO)  # at the stick's end (0.8.6), past the image
    # The image written again over the stick, as any writing tool does (owner, 2026-10-19): its
    # partition table leaves OMABOOT out, the partition stays where it is, and the next run finds
    # it, puts it back in the table and saves beside the first report.
    if ok:
        with open(stick, 'r+b') as dst, open(ISO, 'rb') as src:
            shutil.copyfileobj(src, dst, 16 << 20)
        dropped = room_state()[2] == 0
        serial2 = os.path.join(work, 'serial-2.log')
        marker2, shots2, qerr2 = boot(serial2, 'b2-')
        shots += shots2
        qerr = '\n'.join(x for x in (qerr, qerr2) if x)
        shutil.copy(serial2, os.path.join(OUT, 'serial-2.log')) if os.path.exists(serial2) else None
        seen = open(serial2, errors='replace').read() if os.path.exists(serial2) else ''
        lines = [l.strip() for l in seen.splitlines() if 'OMABOOT-AUTO:' in l]
        auto2 = lines[-1] if lines else ''
        kind2, start2, count2, label2, files2 = room_state()
        kept = set(files) <= set(files2) and len(files2) > len(files)
        room += (f'; image written again: slot 3 {"dropped" if dropped else "STILL THERE"}; second run: '
                 f'{auto2[auto2.find("OMABOOT-AUTO:"):] or "no OMABOOT-AUTO line"}; slot 3 at sector {start2}, '
                 f'{label2 or "no label"}; reports: {" ".join(files2) or "none"} ({"kept" if kept else "NOT KEPT"})')
        ok = dropped and ' saved ' in auto2 + ' ' and (start2, count2) == (start, count) and 'OMABOOT' in label2 and kept
summary = [
    f'iso: {os.path.basename(ISO)}',
    f'result: {"screenshots only (no drive)" if NO_DRIVE else "PASS" if ok else "FAIL"}',
    f'qemu: {"KVM" if KVM else "software emulation"}{", SMBIOS product " + PRODUCT if PRODUCT else ""}',
    f'payload: {signed_with}',
    *([f'boot-live: {auto_line[auto_line.find("OMABOOT-AUTO:"):] or "no OMABOOT-AUTO line"}'] if TOOL else []),
    *([f'reports partition: {room}'] if ROOM else []),
    *([f'dev-signed payload refused: {refused}'] if REFUSE else []),
    *(['network: restricted (no way out; must not submit)'] if NO_SUBMIT and not ROOM else []),
    f'hook marker on serial: {"at %d s" % marker_at if marker_at is not None else "never"}',
    f'results/smoke.txt on the drive: {results.stdout.strip() or "missing"}',
    f'screenshots ({len(shots)}): {" ".join(shots)}',
]
if qerr:
    summary.append('qemu: ' + qerr[-400:])
open(os.path.join(OUT, 'summary.txt'), 'w').write('\n'.join(summary) + '\n')
print('\n'.join(summary))
shutil.rmtree(work, ignore_errors=True)
sys.exit(0 if ok or NO_DRIVE else 1)
