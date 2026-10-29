#!/usr/bin/env python3
"""Genera el icono de Prisma: una fuente de audio que se divide en tres caminos,
y cada camino es un deslizador de volumen en una posición distinta.
Uso: python3 make_icon.py <salida.icns> [preview.png]"""
import math, sys
from PIL import Image, ImageDraw, ImageFilter, ImageChops

S = 2048                      # se dibuja al doble y se reduce (antialias)
BODY = int(S * 824 / 1024)    # cuerpo del icono según la rejilla de macOS
OFF = (S - BODY) // 2


def squircle_mask(size, n=5.0):
    m = Image.new("L", (size, size), 0)
    a = size / 2
    pts = []
    for i in range(720):
        t = 2 * math.pi * i / 720
        c, s = math.cos(t), math.sin(t)
        pts.append((a + a * math.copysign(abs(c) ** (2 / n), c), a + a * math.copysign(abs(s) ** (2 / n), s)))
    ImageDraw.Draw(m).polygon(pts, fill=255)
    return m


def diag_gradient(size, c0, c1):
    small = Image.new("RGB", (256, 256))
    px = small.load()
    for y in range(256):
        for x in range(256):
            t = (x * 0.35 + y * 0.65) / 255
            px[x, y] = tuple(int(c0[i] + (c1[i] - c0[i]) * t) for i in range(3))
    return small.resize((size, size), Image.BICUBIC)


def bezier(p0, p1, p2, p3, n=200):
    out = []
    for i in range(n + 1):
        t = i / n
        u = 1 - t
        out.append((u**3 * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t**3 * p3[0],
                    u**3 * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t**3 * p3[1]))
    return out


def stroke(draw, pts, width, fill):
    """Trazo grueso y liso: círculos a lo largo del camino (sin juntas raras)."""
    r = width / 2
    dense = []
    for a, b in zip(pts, pts[1:]):
        d = math.hypot(b[0] - a[0], b[1] - a[1])
        steps = max(1, int(d / (r * 0.25)))
        for k in range(steps):
            t = k / steps
            dense.append((a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t))
    dense.append(pts[-1])
    for x, y in dense:
        draw.ellipse([x - r, y - r, x + r, y + r], fill=fill)


def main(out_icns, preview=None):
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    body = diag_gradient(BODY, (98, 84, 255), (196, 70, 220)).convert("RGBA")

    # Brillo sutil arriba (vidrio).
    shine = Image.new("RGBA", (BODY, BODY), (0, 0, 0, 0))
    ImageDraw.Draw(shine).ellipse([-BODY * 0.3, -BODY * 0.9, BODY * 1.3, BODY * 0.42], fill=(255, 255, 255, 34))
    body.alpha_composite(shine.filter(ImageFilter.GaussianBlur(BODY * 0.18)))

    B = BODY
    node = (B * 0.22, B * 0.5)
    lw = B * 0.05
    rows = [B * 0.29, B * 0.5, B * 0.71]
    knobs = [0.78, 0.56, 0.68]      # posición de cada deslizador (volúmenes distintos)
    x_split, x_end = B * 0.46, B * 0.84

    shapes = Image.new("RGBA", body.size, (0, 0, 0, 0))
    lines_dim = Image.new("RGBA", body.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(shapes)
    dd = ImageDraw.Draw(lines_dim)
    knob_pts = []
    for y, k in zip(rows, knobs):
        curve = bezier(node, (node[0] + B * 0.13, node[1]), (x_split - B * 0.12, y), (x_split, y))
        xk = x_split + (x_end - x_split) * k
        stroke(d, curve + [(xk, y)], lw, (255, 255, 255, 255))          # tramo "lleno"
        stroke(dd, [(xk, y), (x_end, y)], lw, (255, 255, 255, 255))     # tramo restante
        knob_pts.append((xk, y))

    lines_dim.putalpha(lines_dim.getchannel("A").point(lambda v: v * 95 // 255))
    body.alpha_composite(lines_dim)
    body.alpha_composite(shapes)

    # Nodo de origen (la fuente de audio): anillo blanco.
    nr = B * 0.075
    ring = Image.new("RGBA", body.size, (0, 0, 0, 0))
    rd = ImageDraw.Draw(ring)
    rd.ellipse([node[0] - nr, node[1] - nr, node[0] + nr, node[1] + nr], fill=(255, 255, 255, 255))
    body.alpha_composite(ring)

    # Pomos de los deslizadores con sombra suave.
    kr = B * 0.058
    sh = Image.new("RGBA", body.size, (0, 0, 0, 0))
    sd = ImageDraw.Draw(sh)
    for x, y in knob_pts:
        sd.ellipse([x - kr, y - kr + B * 0.012, x + kr, y + kr + B * 0.012], fill=(40, 10, 90, 110))
    body.alpha_composite(sh.filter(ImageFilter.GaussianBlur(B * 0.014)))
    kn = Image.new("RGBA", body.size, (0, 0, 0, 0))
    kd = ImageDraw.Draw(kn)
    for x, y in knob_pts:
        kd.ellipse([x - kr, y - kr, x + kr, y + kr], fill=(255, 255, 255, 255))
    body.alpha_composite(kn)

    # Recorte en squircle + borde fino de luz.
    m = squircle_mask(BODY)
    body.putalpha(m)
    rim = Image.new("RGBA", (BODY, BODY), (255, 255, 255, 0))
    rim.putalpha(ImageChops.subtract(m, m.filter(ImageFilter.MinFilter(9))).point(lambda v: v * 70 // 255))
    body.alpha_composite(rim)

    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shb = Image.new("RGBA", (BODY, BODY), (20, 10, 60, 0))
    shb.putalpha(m.point(lambda v: v * 90 // 255))
    shadow.paste(shb, (OFF, OFF + int(S * 0.014)), shb)
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(S * 0.014)))
    img.alpha_composite(body, (OFF, OFF))

    final = img.resize((1024, 1024), Image.LANCZOS)
    if preview:
        bg = Image.new("RGBA", final.size, (236, 236, 240, 255))
        bg.alpha_composite(final)
        bg.convert("RGB").save(preview)
    final.save(out_icns, sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)])


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None)
