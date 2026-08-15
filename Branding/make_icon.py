from PIL import Image, ImageDraw, ImageFilter
import math

SS = 4  # supersample factor

def lerp(a, b, t): return tuple(round(a[i] + (b[i]-a[i])*t) for i in range(len(a)))

def squircle_mask(size, radius_frac=0.2237):
    """macOS-style continuous-corner squircle via superellipse."""
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    n = 5.0                      # superellipse exponent ~ Apple's continuous corner
    cx = cy = size/2.0
    a = size/2.0
    pts = []
    steps = 2048
    for i in range(steps):
        th = 2*math.pi*i/steps
        ct, st = math.cos(th), math.sin(th)
        x = cx + a * math.copysign(abs(ct)**(2.0/n), ct)
        y = cy + a * math.copysign(abs(st)**(2.0/n), st)
        pts.append((x, y))
    d.polygon(pts, fill=255)
    return m

def vgrad(size, top, bottom):
    g = Image.new("RGB", (1, size))
    for y in range(size):
        g.putpixel((0, y), lerp(top, bottom, y/max(1, size-1)))
    return g.resize((size, size), Image.BILINEAR)

def diag_grad(size, c0, c1):
    g = Image.new("RGB", (size, size))
    px = g.load()
    for y in range(size):
        for x in range(size):
            t = (x + y) / (2.0*(size-1))
            px[x, y] = lerp(c0, c1, t)
    return g

def build(px_out=1024):
    S = px_out * SS
    canvas = Image.new("RGBA", (S, S), (0,0,0,0))

    # --- squircle body, inset like macOS 11+ icons ---
    inset = int(S * 0.085)
    body = S - 2*inset
    mask = squircle_mask(body)
    bg = vgrad(body, (22, 26, 38), (9, 10, 16))          # deep slate -> near black
    bg_rgba = bg.convert("RGBA"); bg_rgba.putalpha(mask)
    canvas.paste(bg_rgba, (inset, inset), bg_rgba)

    # subtle top sheen
    sheen = Image.new("L", (body, body), 0)
    sd = ImageDraw.Draw(sheen)
    sd.ellipse([-body*0.35, -body*0.95, body*1.35, body*0.42], fill=46)
    sheen = sheen.filter(ImageFilter.GaussianBlur(body*0.05))
    sheen = Image.composite(sheen, Image.new("L",(body,body),0), mask)
    canvas.paste(Image.new("RGBA",(body,body),(255,255,255,255)), (inset, inset), sheen)

    # --- the halo ring ---
    cx = cy = S/2.0
    R  = S * 0.278           # ring radius
    W  = S * 0.083           # stroke width

    ring_mask = Image.new("L", (S, S), 0)
    rd = ImageDraw.Draw(ring_mask)
    rd.ellipse([cx-R-W/2, cy-R-W/2, cx+R+W/2, cy+R+W/2], fill=255)
    rd.ellipse([cx-R+W/2, cy-R+W/2, cx+R-W/2, cy+R-W/2], fill=0)

    grad = diag_grad(S, (255, 106, 92), (150, 108, 255))   # coral -> violet
    ring = grad.convert("RGBA"); ring.putalpha(ring_mask)

    # outer glow
    glow = ring.filter(ImageFilter.GaussianBlur(S*0.030))
    ga = glow.split()[3].point(lambda v: int(v*0.72))
    glow.putalpha(ga)
    glow_clipped = Image.new("RGBA", (S,S), (0,0,0,0))
    body_mask_full = Image.new("L", (S,S), 0)
    body_mask_full.paste(mask, (inset, inset))
    glow_clipped.paste(glow, (0,0), glow)
    glow_clipped.putalpha(Image.composite(glow_clipped.split()[3], Image.new("L",(S,S),0), body_mask_full))
    canvas = Image.alpha_composite(canvas, glow_clipped)
    canvas = Image.alpha_composite(canvas, ring)

    # inner rim light for depth
    rim = Image.new("L", (S,S), 0)
    ImageDraw.Draw(rim).ellipse([cx-R+W/2, cy-R+W/2, cx+R-W/2, cy+R-W/2], outline=90, width=max(1,int(S*0.004)))
    rim = rim.filter(ImageFilter.GaussianBlur(S*0.003))
    canvas.paste(Image.new("RGBA",(S,S),(255,255,255,255)), (0,0), rim)

    return canvas.resize((px_out, px_out), Image.LANCZOS)

icon = build(1024)
icon.save("halo-icon-1024.png")
print("wrote halo-icon-1024.png", icon.size)
