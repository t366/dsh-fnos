"""
生成 fpk 需要的图标，不依赖 Pillow（只用标准库 zlib/struct/math）。

图形：深色圆角方块 + 一个发光感的终端提示符 ">_"。
64px 下也能看清，所以线宽按尺寸等比缩放。

用法（在项目根执行）：
    python scripts/make-icons.py
"""

import math
import os
import struct
import zlib

BG_TOP = (0x18, 0x2A, 0x46)
BG_BOTTOM = (0x0A, 0x0E, 0x15)
FG = (0x7F, 0xB2, 0xFF)
GLOW = (0x2C, 0x5C, 0xA8)


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def dist_to_segment(px, py, x1, y1, x2, y2):
    dx, dy = x2 - x1, y2 - y1
    denom = dx * dx + dy * dy
    if denom == 0:
        return math.hypot(px - x1, py - y1)
    t = ((px - x1) * dx + (py - y1) * dy) / denom
    t = max(0.0, min(1.0, t))
    return math.hypot(px - (x1 + t * dx), py - (y1 + t * dy))


def inside_round_rect(x, y, w, h, r):
    cx = min(max(x, r), w - r)
    cy = min(max(y, r), h - r)
    return math.hypot(x - cx, y - cy) <= r


def render(size):
    """返回 (w, h, [row_bytes...])，RGBA。"""
    inset = size * 0.045
    x0, y0 = inset, inset
    w = h = size - 2 * inset
    r = w * 0.24

    lw = max(1.6, size * 0.082)          # 线宽
    # 提示符 ">" 两个折点
    ax, ay = x0 + w * 0.30, y0 + h * 0.285
    vx, vy = x0 + w * 0.545, y0 + h * 0.50
    bx, by = x0 + w * 0.30, y0 + h * 0.715
    # 光标下划线
    cx1, cy1 = x0 + w * 0.625, y0 + h * 0.715
    cx2, cy2 = x0 + w * 0.755, y0 + h * 0.715

    rows = []
    for py in range(size):
        row = bytearray()
        for px in range(size):
            fx, fy = px + 0.5, py + 0.5
            if not inside_round_rect(fx, fy, size, size, r + inset * 0.5):
                row += bytes((0, 0, 0, 0))
                continue

            t = ((fx - x0) + (fy - y0)) / (2.0 * (w + h))
            t = max(0.0, min(1.0, t))
            bg = lerp(BG_TOP, BG_BOTTOM, t * 1.25)

            d = min(
                dist_to_segment(fx, fy, ax, ay, vx, vy),
                dist_to_segment(fx, fy, vx, vy, bx, by),
                dist_to_segment(fx, fy, cx1, cy1, cx2, cy2),
            )

            # 前景：抗锯齿覆盖度
            cover = max(0.0, min(1.0, (lw / 2.0) - d + 0.5))
            # 外发光
            glow = max(0.0, min(1.0, 1.0 - (d - lw / 2.0) / (lw * 2.2))) if d > lw / 2.0 else 0.0

            col = bg
            if glow > 0.0:
                col = tuple(
                    int(round(col[i] + (GLOW[i] - col[i]) * glow * 0.38)) for i in range(3)
                )
            if cover > 0.0:
                col = tuple(
                    int(round(col[i] + (FG[i] - col[i]) * cover)) for i in range(3)
                )
            row += bytes((col[0], col[1], col[2], 255))
        rows.append(bytes(row))
    return size, size, rows


def write_png(path, w, h, rows):
    raw = b"".join(b"\x00" + r for r in rows)

    def chunk(tag, data):
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)  # 8bit RGBA
    blob = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "wb") as f:
        f.write(blob)
    return len(blob)


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    targets = [
        # 官方规范：包图标 ICON.PNG = 64x64，ICON_256.PNG = 256x256
        (64, os.path.join(root, "fpk", "ICON.PNG")),
        (256, os.path.join(root, "fpk", "ICON_256.PNG")),
        (256, os.path.join(root, "fpk", "app", "ui", "images", "icon_256.png")),
        (64, os.path.join(root, "fpk", "app", "ui", "images", "icon_64.png")),
    ]
    cache = {}
    for size, path in targets:
        if size not in cache:
            cache[size] = render(size)
        w, h, rows = cache[size]
        n = write_png(path, w, h, rows)
        print(f"{path}  {size}x{size}  {n} bytes")


if __name__ == "__main__":
    main()
