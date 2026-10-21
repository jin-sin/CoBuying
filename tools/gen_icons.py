#!/usr/bin/env python3
"""오렌담마켓 아이콘 에셋 생성 — 시안 A(오렌지 슬라이스).

의존성 없이(표준 라이브러리만) SVG 없이 직접 래스터라이즈한다.
도형이 원·선분·둥근사각형뿐이라 거리장(SDF)으로 안티에일리어싱까지 정확히 낼 수 있고,
그래서 Pillow·ImageMagick·rsvg 같은 외부 도구를 깔 필요가 없다.

    python3 tools/gen_icons.py

디자인 원본은 assets/icon/app_icon.svg (사람이 읽는 용도), 실제 PNG는 이 스크립트가 진리.
좌표계는 100x100 단위 공간이며 아이콘 크기에 맞춰 스케일된다.
"""

import math
import os
import struct
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

ORANGE = (0xFF, 0x6B, 0x35)
WHITE = (0xFF, 0xFF, 0xFF)

CORNER = 24.0     # 둥근 사각형 반경 (100 단위 기준)
RIND_R = 32.0     # 흰 껍질(바깥 원) 반경
FLESH_R = 26.0    # 오렌지 과육(안쪽 원) 반경


def _detail(glyph_px):
    """작은 크기에서 뭉개지지 않도록 살(spoke) 개수와 두께를 단계별로 조정."""
    if glyph_px >= 64:
        return 8, 4.0, 5.0
    if glyph_px >= 30:
        return 8, 5.5, 6.0
    return 4, 6.5, 7.0


def _sd_round_rect(x, y, half, r):
    qx, qy = abs(x) - (half - r), abs(y) - (half - r)
    return (math.hypot(max(qx, 0.0), max(qy, 0.0))
            + min(max(qx, qy), 0.0) - r)


def _sd_segment(px, py, ax, ay, bx, by, hw):
    vx, vy = bx - ax, by - ay
    wx, wy = px - ax, py - ay
    t = (wx * vx + wy * vy) / (vx * vx + vy * vy)
    t = 0.0 if t < 0.0 else (1.0 if t > 1.0 else t)
    return math.hypot(wx - vx * t, wy - vy * t) - hw


def _over(dst, src, cov):
    """source-over 합성. dst/src은 (r,g,b,a) 0..1."""
    sa = src[3] * cov
    da = dst[3]
    out_a = sa + da * (1.0 - sa)
    if out_a <= 0.0:
        return (0.0, 0.0, 0.0, 0.0)
    return tuple(
        (src[i] * sa + dst[i] * da * (1.0 - sa)) / out_a for i in range(3)
    ) + (out_a,)


def render(size, bg="rounded", scale=1.0, opaque=False):
    """size×size 픽셀로 아이콘을 그린다.

    bg      'rounded' 둥근 사각형 / 'square' 꽉 찬 사각형 / 'none' 배경 없음
    scale   100단위 도안이 캔버스에서 차지하는 비율 (적응형 아이콘 전경용)
    opaque  True면 알파 없이 RGB로 출력 (iOS 앱 아이콘 요구사항)
    """
    glyph_px = size * scale
    spokes, spoke_w, dot_r = _detail(glyph_px)
    upp = 100.0 / glyph_px          # 픽셀 하나가 차지하는 단위 길이 = AA 폭
    off = (1.0 - scale) * 0.5 * size

    orange = tuple(c / 255.0 for c in ORANGE)
    white = tuple(c / 255.0 for c in WHITE)

    tips = []
    for i in range(spokes):
        a = 2.0 * math.pi * i / spokes
        tips.append((50.0 + FLESH_R * math.cos(a), 50.0 + FLESH_R * math.sin(a)))

    channels = 3 if opaque else 4
    buf = bytearray(size * size * channels)

    for py in range(size):
        v = ((py + 0.5) - off) / glyph_px * 100.0
        row = py * size * channels
        for px in range(size):
            u = ((px + 0.5) - off) / glyph_px * 100.0
            acc = (1.0, 1.0, 1.0, 0.0) if not opaque else (1.0, 1.0, 1.0, 0.0)

            if bg == "rounded":
                d = _sd_round_rect(u - 50.0, v - 50.0, 50.0, CORNER)
                acc = _over(acc, orange + (1.0,), _cov(d, upp))
            elif bg == "square":
                acc = _over(acc, orange + (1.0,), 1.0)

            dr = math.hypot(u - 50.0, v - 50.0)
            if dr <= RIND_R + upp * 2.0:
                acc = _over(acc, white + (1.0,), _cov(dr - RIND_R, upp))
                acc = _over(acc, orange + (1.0,), _cov(dr - FLESH_R, upp))

                d = dr - dot_r
                for tx, ty in tips:
                    ds = _sd_segment(u, v, 50.0, 50.0, tx, ty, spoke_w * 0.5)
                    if ds < d:
                        d = ds
                acc = _over(acc, white + (1.0,), _cov(d, upp))

            i = row + px * channels
            buf[i] = int(acc[0] * 255.0 + 0.5)
            buf[i + 1] = int(acc[1] * 255.0 + 0.5)
            buf[i + 2] = int(acc[2] * 255.0 + 0.5)
            if not opaque:
                buf[i + 3] = int(acc[3] * 255.0 + 0.5)

    return buf, channels


def _cov(sd, aa):
    """거리 → 커버리지(0..1). 경계에서 픽셀 한 칸 폭으로 부드럽게 떨어진다."""
    t = 0.5 - sd / aa
    return 0.0 if t < 0.0 else (1.0 if t > 1.0 else t)


def write_png(path, size, buf, channels):
    stride = size * channels
    raw = bytearray()
    for y in range(size):
        raw.append(0)
        raw += buf[y * stride:(y + 1) * stride]

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8,
                                      6 if channels == 4 else 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")

    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(png)


def emit(rel, size, **kw):
    buf, ch = render(size, **kw)
    write_png(os.path.join(ROOT, rel), size, buf, ch)
    print(f"  {size:>4}px  {rel}")


def main():
    print("마스터 / 웹")
    for s in (1024, 512, 250):
        emit(f"assets/icon/app_icon_{s}.png", s)
    emit("web/favicon.png", 32)
    emit("web/icons/Icon-192.png", 192)
    emit("web/icons/Icon-512.png", 512)
    # maskable은 런처가 임의 모양으로 잘라내므로 배경이 가장자리까지 차야 한다
    emit("web/icons/Icon-maskable-192.png", 192, bg="square")
    emit("web/icons/Icon-maskable-512.png", 512, bg="square")

    print("안드로이드 레거시 런처")
    for d, s in (("mdpi", 48), ("hdpi", 72), ("xhdpi", 96),
                 ("xxhdpi", 144), ("xxxhdpi", 192)):
        emit(f"android/app/src/main/res/mipmap-{d}/ic_launcher.png", s)

    print("안드로이드 적응형 전경 (108dp 캔버스, 안전영역 72dp)")
    for d, s in (("mdpi", 108), ("hdpi", 162), ("xhdpi", 216),
                 ("xxhdpi", 324), ("xxxhdpi", 432)):
        emit(f"android/app/src/main/res/mipmap-{d}/ic_launcher_foreground.png",
             s, bg="none", scale=72.0 / 108.0)

    print("iOS (알파 없는 정사각 — 마스킹은 iOS가 한다)")
    ios = {
        "Icon-App-20x20@1x": 20, "Icon-App-20x20@2x": 40, "Icon-App-20x20@3x": 60,
        "Icon-App-29x29@1x": 29, "Icon-App-29x29@2x": 58, "Icon-App-29x29@3x": 87,
        "Icon-App-40x40@1x": 40, "Icon-App-40x40@2x": 80, "Icon-App-40x40@3x": 120,
        "Icon-App-60x60@2x": 120, "Icon-App-60x60@3x": 180,
        "Icon-App-76x76@1x": 76, "Icon-App-76x76@2x": 152,
        "Icon-App-83.5x83.5@2x": 167,
        "Icon-App-1024x1024@1x": 1024,
    }
    for name, s in sorted(ios.items(), key=lambda kv: kv[1]):
        emit(f"ios/Runner/Assets.xcassets/AppIcon.appiconset/{name}.png",
             s, bg="square", opaque=True)


if __name__ == "__main__":
    main()
