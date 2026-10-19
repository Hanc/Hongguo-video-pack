"""Resize the approved transparent master without losing its alpha channel."""
from pathlib import Path
from PIL import Image
import argparse

parser = argparse.ArgumentParser()
parser.add_argument('source', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
image = Image.open(args.source).convert('RGBA')
if image.width != image.height:
    raise ValueError('Select the square logo; do not distort the artwork.')
# Transparent extraction is performed on the master, never on white grapes.
alpha = image.getchannel('A')
if alpha.getextrema()[0] == 255:
    raise ValueError('The master is opaque. Use assets/branding/logo-master.png with transparent exterior corners.')
box = alpha.getbbox()
if box:
    image = image.crop(box)
if any(image.getpixel(p)[3] != 0 for p in [(0,0),(image.width-1,0),(0,image.height-1),(image.width-1,image.height-1)]):
    raise ValueError('Exterior corners must be transparent.')
brand = root / 'assets/branding'
brand.mkdir(parents=True, exist_ok=True)
def resized(size):
    result = image.resize((size,size), Image.Resampling.LANCZOS)
    # Remove near-zero edge noise introduced by filtering a transparent master.
    result.putalpha(result.getchannel('A').point(lambda a: 0 if a < 8 else a))
    for corner in [(0,0),(size-1,0),(0,size-1),(size-1,size-1)]:
        result.putpixel(corner, (0,0,0,0))
    return result

resized(512).save(brand / 'logo.png')
sizes = [16,24,32,48,64,128,256]
frames = [resized(size) for size in sizes]
frames[-1].save(root / 'windows/runner/resources/app_icon.ico', sizes=[(n,n) for n in sizes], append_images=frames[:-1])
for density, size in [('mdpi',48),('hdpi',72),('xhdpi',96),('xxhdpi',144),('xxxhdpi',192)]:
    resized(size).save(root / f'android/app/src/main/res/mipmap-{density}/ic_launcher.png')
