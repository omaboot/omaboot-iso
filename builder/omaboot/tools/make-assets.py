#!/usr/bin/env python3
"""Make the OmaBoot? boot assets from our console font and Boot's sprite. Standard library only.

  make-assets.py OMABOOT_V_DIR TERMINUS_DIR OUT_DIR

OMABOOT_V_DIR has omaboot-v16n.psf.gz and omaboot-v24n.psf.gz (doesitomarchy/omaboot-spikes,
spike-look/fonts); TERMINUS_DIR has ter-v12n.psf.gz (the terminus-font package). Writes:

  OUT/grub/omaboot-v16.bdf, omaboot-v24.bdf   GRUB fonts (the build turns them into .pf2)
  OUT/grub/theme/                             theme.txt, wordmark.png, boot.png, select_c.png
  OUT/plymouth/live-<dev|release>/            OmaBoot? Live's boot splash: logo.png, waking.png,
                                              bye.png, byeline.png (also alone:
                                              --splash OMABOOT_V_DIR OUT)
  OUT/esp/<flavour>-<dev|release>/            per build type (see BUILDS): the Option-key startup
          .VolumeIcon.icns                    picker's icon and the stick's name in it
          .disk_label, .disk_label_2x, .disk_label.contentDetails
"""
import gzip, os, struct, sys, zlib

# OmaBoot? palette (console colours 0-15)
PAL = ["#0b0d10", "#c2453f", "#3fa173", "#c98f3a", "#5276b8", "#8a78e6", "#4fa6ad", "#b4bcc2",
       "#4a535b", "#f06a63", "#5fd39b", "#ffd479", "#89aef0", "#b8a9ff", "#8fe3e8", "#eef2f4"]
rgb = lambda h: tuple(int(h[i:i + 2], 16) for i in (1, 3, 5))
PIX = dict(zip("krgybmcwKRGYBMCW", range(16)))

# Boot, the "Sprite" draft, neutral face (two pixel rows per console cell in the tester).
BOOT = [
    ".......yy.......",
    "........c.......",
    "..cccccccccccc..",
    ".ckkkkkkkkkkkkc.",
    ".ckkWWWkkWWWkkc.",
    ".ckkWWWkkWWWkkc.",
    ".ckkkkkkkkkkkkc.",
    ".ckkkkkCCkkkkkc.",
    ".ckkkkkkkkkkkkc.",
    ".ckkkkkkkkkkkkc.",
    "..cccccccccccc..",
    "....cc....cc....",
]


def psf(path):
    """Glyphs and a code point map from a PSF1/PSF2 font: (w, h, [rows per glyph], {cp: index})."""
    b = gzip.open(path).read()
    if b[:2] == b'\x36\x04':
        mode, h = b[2], b[3]
        n = 512 if mode & 1 else 256
        w, bpr, off = 8, 1, 4
        glyph = lambda i: b[off + i * h: off + (i + 1) * h]
        cmap, p = {}, off + n * h
        for i in range(n):
            seq = True
            while True:
                u = struct.unpack('<H', b[p:p + 2])[0]; p += 2
                if u == 0xFFFF:
                    break
                if u == 0xFFFE:
                    seq = False
                elif seq:
                    cmap.setdefault(u, i)
    else:
        _, _, hs, flags, n, gs, h, w = struct.unpack('<IIIIIIII', b[:32])
        bpr = (w + 7) // 8
        glyph = lambda i: b[hs + i * gs: hs + (i + 1) * gs]
        cmap, p = {}, hs + n * gs
        for i in range(n):
            end = b.index(b'\xff', p)
            for ch in b[p:end].split(b'\xfe')[0].decode('utf-8'):
                cmap.setdefault(ord(ch), i)
            p = end + 1
    rows = []
    for i in range(n):
        g = glyph(i)
        rows.append([int.from_bytes(g[r * bpr:(r + 1) * bpr], 'big') >> (bpr * 8 - w) for r in range(h)])
    return w, h, rows, cmap


def bdf(path, name, size):
    w, h, rows, cmap = psf(path)
    descent = round(h / 5)
    out = [f"STARTFONT 2.1", f"FONT -omaboot-{name}-Medium-R-Normal--{h}-{h * 10}-75-75-C-{w * 10}-ISO10646-1",
           f"SIZE {h} 75 75", f"FONTBOUNDINGBOX {w} {h} 0 {-descent}", "STARTPROPERTIES 6",
           f'FAMILY_NAME "{name}"', 'WEIGHT_NAME "Regular"', f"PIXEL_SIZE {h}", f"FONT_ASCENT {h - descent}",
           f"FONT_DESCENT {descent}", "SPACING \"C\"", "ENDPROPERTIES"]
    cps = sorted(cp for cp in cmap if cp >= 32)
    out.append(f"CHARS {len(cps)}")
    bpr = (w + 7) // 8
    for cp in cps:
        out += [f"STARTCHAR U+{cp:04X}", f"ENCODING {cp}", f"SWIDTH {w * 1000 // h} 0", f"DWIDTH {w} 0",
                f"BBX {w} {h} 0 {-descent}", "BITMAP"]
        out += [f"{r << (bpr * 8 - w):0{bpr * 2}X}" for r in rows[cmap[cp]]]
        out.append("ENDCHAR")
    out.append("ENDFONT")
    return "\n".join(out) + "\n"


def png(w, h, px):
    """px: rows of (r, g, b, a) tuples."""
    raw = b''.join(b'\x00' + bytes(c for p in row for c in p) for row in px)
    chunk = lambda t, d: struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d))
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)) +
            chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))


# Boot asleep: the eyes shut to a line (the shutdown splash)
BOOT_ASLEEP = BOOT[:4] + [".ckkkkkkkkkkkkc.", ".ckWWWWkkWWWWkc."] + BOOT[6:]


def sprite(scale, size=None, asleep=False):
    """Boot as RGBA rows, nearest-neighbour scaled, centred on a transparent square of `size`."""
    art = BOOT_ASLEEP if asleep else BOOT
    sw, sh = len(art[0]) * scale, len(art) * scale
    size = size or max(sw, sh)
    ox, oy = (size - sw) // 2, (size - sh) // 2
    px = [[(0, 0, 0, 0)] * size for _ in range(size)]
    for y, row in enumerate(art):
        for x, ch in enumerate(row):
            if ch in PIX:
                c = rgb(PAL[PIX[ch]]) + (255,)
                for dy in range(scale):
                    for dx in range(scale):
                        px[oy + y * scale + dy][ox + x * scale + dx] = c
    return size, size, px


def text(fontpath, s, colours, scale=1):
    """Render s with a PSF font; colours[i] is the RGB for character i. Returns w, h, coverage, rgb rows."""
    w, h, rows, cmap = psf(fontpath)
    W, H = w * len(s) * scale, h * scale
    cov = [[0] * W for _ in range(H)]
    col = [[(0, 0, 0)] * W for _ in range(H)]
    for i, ch in enumerate(s):
        g = rows[cmap.get(ord(ch), cmap[ord('?')])]
        for y in range(h):
            for x in range(w):
                if g[y] >> (w - 1 - x) & 1:
                    for dy in range(scale):
                        for dx in range(scale):
                            cov[y * scale + dy][(i * w + x) * scale + dx] = 255
                            col[y * scale + dy][(i * w + x) * scale + dx] = colours[i]
    return W, H, cov, col


def packbits(data):
    """Apple's icns RLE: runs of 3-130 equal bytes as (0x80 + n - 3, byte), literals as (n - 1, bytes)."""
    out, i, n = bytearray(), 0, len(data)
    while i < n:
        j = i
        while j < n and j - i < 130 and data[j] == data[i]:
            j += 1
        if j - i >= 3:
            out += bytes([0x80 + j - i - 3, data[i]]); i = j; continue
        j = i
        while j < n and j - i < 128 and not (j + 2 < n and data[j] == data[j + 1] == data[j + 2]):
            j += 1
        out += bytes([j - i - 1]) + bytes(data[i:j]); i = j
    return bytes(out)


# The startup picker icon: one of the five designs in icon-options.py (reviewed on a design canvas).
# Owner's pick: option 3 "Boot stick" (2026-10-09 morning), then option 5 "Floppy" (2026-10-09).
ICON = '5-floppy'

# One floppy per image type (owner, 2026-10-09): the shell colour says the type, a DEV tag in the
# lower-right corner marks our internal test builds, and dev and release builds share the name.
# Omarchy Lite is dev only; Lab (candidate fixes) is planned.
BUILDS = {'live': ('#5a49c4', 'OmaBoot? Live'),                # purple: test this Mac
          'omarchy': ('#2f7c82', 'OmaBoot? Omarchy'),          # cyan: install Omarchy, tester in the menu
          'omarchy-lite': ('#7d878f', 'OmaBoot? Omarchy Lite'),  # silver: dev only, no installer packages
          'lab': ('#c98f3a', 'OmaBoot? Lab')}                  # amber: try candidate fixes
DEV_TAG = ["XX..XXX.X.X", "X.X.X...X.X", "X.X.XX..X.X", "X.X.X...X.X", "XX..XXX..X."]  # 3x5 letters


def picked_icon(shell, dev):
    src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'icon-options.py')).read()
    ns = {}
    exec(src.split('import json, os')[0], ns)  # the drawing part only, not its file output
    colours = dict(ns['C'], v=shell)
    g = [['v' if ch == 'n' else ch for ch in row] for row in ns['opts'][ICON][2]]  # the floppy's shell
    if dev:  # a dark 13x7 tag, flush with the lower-right corner, clear of Boot
        for y in range(52, 59):
            for x in range(46, 59):
                g[y][x] = 'k'
        for r, row in enumerate(DEV_TAG):
            for c, ch in enumerate(row):
                if ch == 'X':
                    g[53 + r][47 + c] = 'W'
    return g, colours


def icon_rgba(scale, shell, dev):
    g, colours = picked_icon(shell, dev)
    px = []
    for row in g:
        line = []
        for ch in row:
            c = colours.get(ch)
            line += [rgb(c) + (255,) if c else (0, 0, 0, 0)] * scale
        px += [line] * scale
    return len(px[0]), len(px), px


def icns(shell, dev):
    entries = []
    w, h, px = icon_rgba(2, shell, dev)  # 128x128 legacy it32 + t8mk: what 2009-era firmware understands
    chans = [bytes(p[c] for row in px for p in row) for c in range(4)]
    entries.append((b'it32', b'\x00\x00\x00\x00' + b''.join(packbits(chans[c]) for c in range(3))))
    entries.append((b't8mk', chans[3]))
    for t, scale in ((b'ic07', 2), (b'ic08', 4), (b'ic09', 8)):
        entries.append((t, png(*icon_rgba(scale, shell, dev))))
    body = b''.join(t + struct.pack('>I', len(d) + 8) + d for t, d in entries)
    return b'icns' + struct.pack('>I', len(body) + 8) + body


# Apple's disk label palette: coverage 0..15 -> palette index (OpenCorePkg Utilities/disklabel)
CLUT = [0x00, 0xF6, 0xF7, 0x2A, 0xF8, 0xF9, 0x55, 0xFA, 0xFB, 0x80, 0xFC, 0xFD, 0xAB, 0xFE, 0xFF, 0xD6]


def disk_label(fontpath, s, height):
    w, h, cov, _ = text(fontpath, s, [(0, 0, 0)] * len(s))
    W, pad = w + 4, 2  # a little room on the left, as Apple's labels have
    rows = [[0] * W for _ in range(height)]
    top = max(0, (height - h) // 2)
    for y in range(min(h, height)):
        for x in range(w):
            rows[top + y][pad + x] = cov[y][x]
    data = bytes(CLUT[v >> 4] for row in rows for v in row)
    return struct.pack('>BHH', 1, W, height) + data


def loading(v24, v16, W=1440, H=900):
    """Shown, stretched to the screen, while GRUB loads the kernel (10+ s from a USB 2 stick), and
    for a few seconds at least (grub-live-entries.cfg): Boot says hello, and warns that older Macs
    can then sit on a black screen for minutes before the next splash."""
    bg = rgb(PAL[0]) + (255,)
    px = [[bg] * W for _ in range(H)]

    def put(x0, y0, w, h, rows):
        for y in range(h):
            for x in range(w):
                if rows[y][x][3]:
                    px[y0 + y][x0 + x] = rows[y][x]

    sw, sh, spx = sprite(10)                       # Boot, 160 px wide
    put((W - sw) // 2, 250, sw, sh, spx)
    word = "OmaBoot?"
    w, h, cov, col = text(v24, word, [rgb(PAL[15])] * 7 + [rgb(PAL[13])], scale=3)
    put((W - w) // 2, 250 + sh + 36, w, h, [[c + (a,) for c, a in zip(cr, ar)] for cr, ar in zip(col, cov)])
    line = "Hello! Boot is waking up\u2026"
    w2, h2, cov2, col2 = text(v16, line, [rgb(PAL[15])] * 6 + [rgb(PAL[7])] * (len(line) - 6), scale=2)
    y2 = 250 + sh + 36 + h + 28
    put((W - w2) // 2, y2, w2, h2, [[c + (a,) for c, a in zip(cr, ar)] for cr, ar in zip(col2, cov2)])
    # older Macs (USB 2, slow GPUs) can sit on a black screen for minutes after this one
    note = "Older Macs can show a black screen for a few minutes while starting. That's normal."
    w3, h3, cov3, col3 = text(v24, note, [rgb(PAL[7])] * len(note))
    put((W - w3) // 2, y2 + h2 + 40, w3, h3, [[c + (a,) for c, a in zip(cr, ar)] for cr, ar in zip(col3, cov3)])
    return png(W, H, px)


def splash(v24, v16, out):
    """OmaBoot? Live's Plymouth theme images (builder/omaboot/plymouth): the purple floppy with the
    name under it, and Boot's line for boot and for shutdown. On the console's background colour, so
    the hand-over to boot-live doesn't flash."""
    def rgba(w, h, cov, col):
        return [[c + (a,) for c, a in zip(cr, ar)] for cr, ar in zip(col, cov)]

    shell, name = BUILDS['live']
    word = name                                      # "OmaBoot? Live": "?" and "Live" in violet
    colours = [rgb(PAL[15])] * 7 + [rgb(PAL[13])] * (len(word) - 7)
    ww, wh, wcov, wcol = text(v24, word, colours, scale=3)
    for kind in ('dev', 'release'):
        d = os.path.join(out, 'plymouth', f'live-{kind}')
        os.makedirs(d, exist_ok=True)
        iw, ih, ipx = icon_rgba(4, shell, kind == 'dev')
        W, gap = max(iw, ww), 40
        H = ih + gap + wh
        px = [[(0, 0, 0, 0)] * W for _ in range(H)]
        for y in range(ih):
            for x in range(iw):
                px[y][(W - iw) // 2 + x] = ipx[y][x]
        wpx = rgba(ww, wh, wcov, wcol)
        for y in range(wh):
            for x in range(ww):
                px[ih + gap + y][(W - ww) // 2 + x] = wpx[y][x]
        open(os.path.join(d, 'logo.png'), 'wb').write(png(W, H, px))
        # shutdown: Boot saying goodbye ("bye!") over the name, so the two splashes differ at a glance
        bw, bh, bpx = sprite(12)
        zw, zh, zcov, zcol = text(v24, "bye!", [rgb(PAL[13])] * 4, scale=2)
        W2, H2 = max(bw + zw, ww), bh + gap + wh
        px2 = [[(0, 0, 0, 0)] * W2 for _ in range(H2)]
        bx = (W2 - bw) // 2
        for y in range(bh):
            for x in range(bw):
                px2[y][bx + x] = bpx[y][x]
        zpx = rgba(zw, zh, zcov, zcol)
        for y in range(zh):
            for x in range(zw):
                if zpx[y][x][3] and bx + bw - 24 + x < W2:
                    px2[y][bx + bw - 24 + x] = zpx[y][x]
        for y in range(wh):
            for x in range(ww):
                px2[bh + gap + y][(W2 - ww) // 2 + x] = wpx[y][x]
        open(os.path.join(d, 'bye.png'), 'wb').write(png(W2, H2, px2))
        for f, line in (('waking.png', "Almost done loading\u2026"), ('byeline.png', "Goodbye! Boot is shutting down\u2026")):
            w, h, cov, col = text(v16, line, [rgb(PAL[7])] * len(line), scale=2)
            open(os.path.join(d, f), 'wb').write(png(w, h, rgba(w, h, cov, col)))
        # the black-screen note is on GRUB's loading splash, before the wait; this splash stays up
        # until boot-live draws (plymouth/omaboot-retain-splash.conf), so it needs none


def main():
    if sys.argv[1:2] == ['--splash']:  # only the Live splash: make-assets.py --splash OMABOOT_V_DIR OUT_DIR
        fdir, out = sys.argv[2:4]
        splash(os.path.join(fdir, 'omaboot-v24n.psf.gz'), os.path.join(fdir, 'omaboot-v16n.psf.gz'), out)
        return
    fdir, tdir, out = sys.argv[1:4]
    v16, v24, t12 = (os.path.join(fdir, 'omaboot-v16n.psf.gz'), os.path.join(fdir, 'omaboot-v24n.psf.gz'),
                     os.path.join(tdir, 'ter-v12n.psf.gz'))
    g, th = os.path.join(out, 'grub'), os.path.join(out, 'grub', 'theme')
    esps = {}
    for flavour, (shell, name) in BUILDS.items():
        for kind in ('dev', 'release') if flavour != 'omarchy-lite' else ('dev',):
            esps[os.path.join(out, 'esp', f'{flavour}-{kind}')] = (shell, kind == 'dev', name)
    for d in (g, th, *esps):
        os.makedirs(d, exist_ok=True)
    for path, size in ((v16, 16), (v24, 24)):
        open(os.path.join(g, f'omaboot-v{size}.bdf'), 'w').write(bdf(path, 'omaboot-v', size))
    # wordmark: "OmaBoot" in near-white, "?" in the violet accent, 2x pixels
    word = "OmaBoot?"
    w, h, cov, col = text(v24, word, [rgb(PAL[15])] * 7 + [rgb(PAL[13])], scale=2)
    open(os.path.join(th, 'wordmark.png'), 'wb').write(png(w, h, [[c + (a,) for c, a in zip(cr, ar)] for cr, ar in zip(col, cov)]))
    open(os.path.join(th, 'boot.png'), 'wb').write(png(*sprite(6)))
    for part in ('nw', 'n', 'ne', 'w', 'c', 'e', 'sw', 's', 'se'):  # GRUB's styled box wants all nine
        open(os.path.join(th, f'select_{part}.png'), 'wb').write(png(1, 1, [[rgb(PAL[5]) + (255,)]]))
        open(os.path.join(th, f'terminal_box_{part}.png'), 'wb').write(png(1, 1, [[(0, 0, 0, 0)]]))  # see-through
    open(os.path.join(th, 'loading.png'), 'wb').write(loading(v24, v16))
    splash(v24, v16, out)
    for esp, (shell, dev, name) in esps.items():
        open(os.path.join(esp, '.VolumeIcon.icns'), 'wb').write(icns(shell, dev))
        open(os.path.join(esp, '.disk_label'), 'wb').write(disk_label(t12, name, 12))
        open(os.path.join(esp, '.disk_label_2x'), 'wb').write(disk_label(v24, name, 24))
        open(os.path.join(esp, '.disk_label.contentDetails'), 'w').write(name)
    for d in (g, th, *esps):
        for f in sorted(os.listdir(d)):
            p = os.path.join(d, f)
            if os.path.isfile(p):
                print(f'{os.path.relpath(p, out):40} {os.path.getsize(p):8} bytes')


if __name__ == '__main__':
    main()
