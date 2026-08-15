from PIL import Image, ImageDraw
import os, subprocess, math

src = Image.open("halo-icon-1024.png").convert("RGBA")
os.makedirs("Halo.iconset", exist_ok=True)
spec = [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)]
for pt, scale in spec:
    px = pt*scale
    name = f"icon_{pt}x{pt}{'@2x' if scale==2 else ''}.png"
    src.resize((px,px), Image.LANCZOS).save(os.path.join("Halo.iconset", name))
print("iconset entries:", len(os.listdir("Halo.iconset")))
subprocess.run(["iconutil","-c","icns","Halo.iconset","-o","Halo.icns"], check=True)
print("wrote Halo.icns", os.path.getsize("Halo.icns"), "bytes")

# --- menu bar template icons: monochrome black + alpha; macOS tints automatically ---
def menubar(px, recording=False):
    SS=8; S=px*SS
    img=Image.new("RGBA",(S,S),(0,0,0,0)); d=ImageDraw.Draw(img)
    cx=cy=S/2; R=S*0.34; W=S*0.13
    d.ellipse([cx-R-W/2,cy-R-W/2,cx+R+W/2,cy+R+W/2], fill=(0,0,0,255))
    d.ellipse([cx-R+W/2,cy-R+W/2,cx+R-W/2,cy+R-W/2], fill=(0,0,0,0))
    if recording:                      # filled centre dot = actively recording
        r=S*0.15
        d.ellipse([cx-r,cy-r,cx+r,cy+r], fill=(0,0,0,255))
    return img.resize((px,px), Image.LANCZOS)

for pt in (16,18):
    for scale in (1,2):
        for rec in (False,True):
            px=pt*scale
            suffix="Recording" if rec else "Idle"
            nm=f"menubar{suffix}_{pt}{'@2x' if scale==2 else ''}.png"
            menubar(px,rec).save(nm)
print("menu bar icons written")
