"""Inspect the actual EXE small icon through Win32, not only the source PNG."""
import ctypes as c
from ctypes import wintypes as w
import json
import sys

class IconInfo(c.Structure):
    _fields_ = [('icon', w.BOOL), ('x', w.DWORD), ('y', w.DWORD), ('mask', w.HBITMAP), ('color', w.HBITMAP)]

class Bitmap(c.Structure):
    _fields_ = [('kind', w.LONG), ('width', w.LONG), ('height', w.LONG), ('stride', w.LONG), ('planes', w.WORD), ('bits', w.WORD), ('data', c.c_void_p)]

class Header(c.Structure):
    _fields_ = [('size', w.DWORD), ('width', w.LONG), ('height', w.LONG), ('planes', w.WORD), ('bits', w.WORD), ('compression', w.DWORD), ('image_size', w.DWORD), ('xppm', w.LONG), ('yppm', w.LONG), ('used', w.DWORD), ('important', w.DWORD)]

shell, user, gdi = c.windll.shell32, c.windll.user32, c.windll.gdi32
shell.ExtractIconExW.argtypes = [w.LPCWSTR, c.c_int, c.POINTER(w.HICON), c.POINTER(w.HICON), w.UINT]
user.GetIconInfo.argtypes = [w.HICON, c.POINTER(IconInfo)]
user.DestroyIcon.argtypes = [w.HICON]
gdi.GetObjectW.argtypes = [w.HANDLE, c.c_int, c.c_void_p]
gdi.CreateCompatibleDC.argtypes = [w.HDC]
gdi.CreateCompatibleDC.restype = w.HDC
gdi.GetDIBits.argtypes = [w.HDC, w.HBITMAP, w.UINT, w.UINT, c.c_void_p, c.c_void_p, w.UINT]
gdi.DeleteObject.argtypes = [w.HANDLE]
gdi.DeleteDC.argtypes = [w.HDC]
icon = w.HICON()
assert shell.ExtractIconExW(sys.argv[1], 0, None, c.byref(icon), 1) == 1, 'No EXE small icon'
info = IconInfo()
assert user.GetIconInfo(icon, c.byref(info)), 'Cannot inspect EXE icon'
dc = gdi.CreateCompatibleDC(None)
try:
    bitmap = Bitmap()
    assert gdi.GetObjectW(info.color, c.sizeof(bitmap), c.byref(bitmap))
    header = Header(size=c.sizeof(Header), width=bitmap.width, height=-bitmap.height, planes=1, bits=32)
    pixels = (c.c_ubyte * (bitmap.width * bitmap.height * 4))()
    assert gdi.GetDIBits(dc, info.color, 0, bitmap.height, pixels, c.byref(header), 0) == bitmap.height
    corners = [pixels[(y * bitmap.width + x) * 4 + 3] for x,y in [(0,0),(bitmap.width-1,0),(0,bitmap.height-1),(bitmap.width-1,bitmap.height-1)]]
    assert corners == [0,0,0,0], 'EXE taskbar icon still has opaque corners'
    white = sum(1 for i in range(0,len(pixels),4) if min(pixels[i:i+3]) > 230 and pixels[i+3] > 245)
    assert white > 0, 'White grape artwork lost its opacity'
    print(json.dumps({'small_icon_size':[bitmap.width,bitmap.height], 'corner_alpha':corners, 'opaque_white_pixels':white}))
finally:
    gdi.DeleteDC(dc)
    gdi.DeleteObject(info.color)
    gdi.DeleteObject(info.mask)
    user.DestroyIcon(icon)
