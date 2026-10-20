# Five OmaBoot? startup-picker icon options: drive shapes with Boot, as 64x64 pixel art.
import struct, zlib
C = {'.': None, 'k': '#0b0d10', 'n': '#13171c', 'd': '#2a3036', 'K': '#4a535b', 's': '#8a949c', 'w': '#b4bcc2',
     'S': '#d6dbe0', 'W': '#eef2f4', 'c': '#4fa6ad', 'C': '#8fe3e8', 't': '#2f7c82', 'y': '#c98f3a', 'Y': '#ffd479',
     'm': '#8a78e6', 'M': '#b8a9ff'}
BOOT = [".......yy.......", "........c.......", "..cccccccccccc..", ".ckkkkkkkkkkkkc.", ".ckkWWWkkWWWkkc.",
        ".ckkWWWkkWWWkkc.", ".ckkkkkkkkkkkkc.", ".ckkkkkCCkkkkkc.", ".ckkkkkkkkkkkkc.", ".ckkkkkkkkkkkkc.",
        "..cccccccccccc..", "....cc....cc...."]
N = 64
def new(): return [['.'] * N for _ in range(N)]
def rect(g, x0, y0, x1, y1, ch, r=0):
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            dx = max(x0 + r - x, x - (x1 - r), 0); dy = max(y0 + r - y, y - (y1 - r), 0)
            if r and dx and dy and (dx - .5) ** 2 + (dy - .5) ** 2 > r * r: continue
            g[y][x] = ch
def outline(g, x0, y0, x1, y1, ch, r=0):
    m = new(); rect(m, x0, y0, x1, y1, '#', r)
    for y in range(N):
        for x in range(N):
            if m[y][x] == '#' and any(not (0 <= y + dy < N and 0 <= x + dx < N) or m[y + dy][x + dx] != '#' for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))):
                g[y][x] = ch
def poly(g, pts, ch):  # scanline fill
    for y in range(N):
        xs = []
        for (x1, y1), (x2, y2) in zip(pts, pts[1:] + pts[:1]):
            if (y1 <= y < y2) or (y2 <= y < y1): xs.append(x1 + (y - y1) * (x2 - x1) / (y2 - y1))
        xs.sort()
        for a, b in zip(xs[::2], xs[1::2]):
            for x in range(round(a), round(b)): g[y][x] = ch
def blit(g, rows, ox, oy, s=1):
    for y, row in enumerate(rows):
        for x, ch in enumerate(row):
            if ch != '.':
                for dy in range(s):
                    for dx in range(s): g[oy + y * s + dy][ox + x * s + dx] = ch
def face(g, x0, y0, x1, y1, eye=6):  # Boot's face on a dark screen: two eyes, a mouth
    rect(g, x0, y0, x1, y1, 'k', 2)
    cx, w = (x0 + x1) // 2, x1 - x0
    ey = y0 + (y1 - y0) // 3
    for ex in (cx - w // 4 - eye // 2, cx + w // 4 - eye // 2):
        rect(g, ex, ey, ex + eye - 1, ey + eye * 5 // 6 - 1, 'W')
    my = y1 - (y1 - y0) // 4
    rect(g, cx - eye // 2, my, cx + eye // 2 - 1, my + 1, 'C')
def antenna(g, x, ytop, ybody):
    rect(g, x, ytop + 3, x + 1, ybody - 1, 'c'); rect(g, x - 1, ytop, x + 2, ytop + 2, 'y')

opts = {}
# 1 Night drive: a dark external drive in 3/4 view, Boot on its front
g = new()
poly(g, [(14, 10), (58, 10), (50, 17), (6, 17)], 'd'); rect(g, 14, 10, 57, 10, 'K')
poly(g, [(50, 17), (58, 10), (58, 47), (50, 55)], 'k')
rect(g, 6, 17, 50, 55, 'n', 2); outline(g, 6, 17, 50, 55, 'K', 2)
blit(g, BOOT, 12, 20, 2)
for y in (49, 51): rect(g, 10, y, 30, y, 'K')
rect(g, 43, 49, 45, 50, 'Y')
opts['1-night-drive'] = ('Night drive', 'A dark external drive in three-quarter view, Boot on its front panel, an amber activity light.', g)
# 2 Silver drive: a flat silver drive whose front is Boot's screen face, antenna on top
g = new()
rect(g, 4, 14, 59, 54, 'S', 6); outline(g, 4, 14, 59, 54, 's', 6); rect(g, 9, 15, 54, 15, 'W')
face(g, 11, 19, 52, 44, 7)
antenna(g, 31, 4, 14)
for y in (48, 50): rect(g, 11, y, 34, y, 'w')
rect(g, 48, 48, 51, 49, 'y')
opts['2-silver-drive'] = ('Silver drive', 'A light silver drive that sits with Apple\'s icons; its front is Boot\'s screen face, antenna on top.', g)
# 3 Boot stick: a USB stick whose body is Boot
g = new()
rect(g, 2, 25, 13, 39, 'w'); outline(g, 2, 25, 13, 39, 's'); rect(g, 5, 29, 7, 30, 'K'); rect(g, 5, 34, 7, 35, 'K')
rect(g, 13, 16, 61, 48, 'c', 6); outline(g, 13, 16, 61, 48, 't', 6)
face(g, 20, 21, 55, 43, 6)
antenna(g, 37, 6, 16)
opts['3-boot-stick'] = ('Boot stick', 'A USB stick whose body is Boot: cyan shell, screen face, antenna. Says "this is the stick you plugged in".', g)
# 4 Boot on a drive: Boot standing on a flat dark drive
g = new()
rect(g, 4, 41, 59, 57, 'n', 3); outline(g, 4, 41, 59, 57, 'K', 3); rect(g, 7, 42, 56, 42, 'd')
rect(g, 9, 49, 26, 50, 'm'); rect(g, 52, 49, 54, 50, 'Y')
blit(g, BOOT, 16, 17, 2)
opts['4-boot-on-drive'] = ('Boot on a drive', 'Boot standing on a flat dark drive with a violet stripe: the character first, the drive as its stage.', g)
# 5 Floppy: Boot on the label of a floppy disk
g = new()
poly(g, [(6, 6), (52, 6), (58, 12), (58, 58), (6, 58)], 'n'); rect(g, 6, 6, 51, 6, 'K')
rect(g, 18, 6, 44, 22, 'w'); rect(g, 34, 9, 39, 19, 'K'); rect(g, 18, 22, 44, 22, 's')
rect(g, 11, 28, 53, 57, 'W', 1)
blit(g, BOOT, 16, 31, 2)
opts['5-floppy'] = ('Floppy', 'Boot on the label of a floppy disk: the "Floppy" draft as a disk icon. Retro; least like a modern drive.', g)

def png(grid, s):
    rows = []
    for row in grid:
        line = []
        for ch in row:
            c = C[ch]
            p = (0, 0, 0, 0) if c is None else tuple(int(c[i:i + 2], 16) for i in (1, 3, 5)) + (255,)
            line += [p] * s
        rows += [line] * s
    raw = b''.join(b'\x00' + bytes(v for p in r for v in p) for r in rows)
    ck = lambda t, d: struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d))
    w = len(rows[0])
    return b'\x89PNG\r\n\x1a\n' + ck(b'IHDR', struct.pack('>IIBBBBB', w, len(rows), 8, 6, 0, 0, 0)) + ck(b'IDAT', zlib.compress(raw, 9)) + ck(b'IEND', b'')
import json, os
out = os.path.dirname(os.path.abspath(__file__))
meta = {}
for k, (name, note, g) in opts.items():
    open(f'{out}/{k}-128.png', 'wb').write(png(g, 2))
    open(f'{out}/{k}-512.png', 'wb').write(png(g, 8))
    meta[k] = {'name': name, 'note': note}
json.dump(meta, open(f'{out}/meta.json', 'w'), indent=1)
print(list(meta))
