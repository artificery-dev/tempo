"""Toolchain-only rasterization of shared SVG artwork and a small text atlas."""
from pathlib import Path
import struct, zlib, subprocess, html
import xml.etree.ElementTree as ET
root = Path(__file__).resolve().parents[2]
out = root / 'build/recovery'

def png(path):
    data=path.read_bytes(); pos=8; packed=b''
    while pos<len(data):
        n=struct.unpack_from('>I',data,pos)[0]; kind=data[pos+4:pos+8]; value=data[pos+8:pos+8+n]; pos+=12+n
        if kind==b'IHDR': w,h,depth,color,_,_,interlace=struct.unpack('>IIBBBBB',value)
        if kind==b'IDAT': packed+=value
    assert depth==8 and color in (2,6) and interlace==0
    channels=4 if color==6 else 3; stride=w*channels; raw=zlib.decompress(packed); previous=bytearray(stride); rows=[]
    for y in range(h):
        f=raw[y*(stride+1)]; row=bytearray(raw[y*(stride+1)+1:(y+1)*(stride+1)])
        for x in range(stride):
            a=row[x-channels] if x>=channels else 0; b=previous[x]; c=previous[x-channels] if x>=channels else 0
            p=a+b-c; distances=[abs(p-a),abs(p-b),abs(p-c)]
            paeth=[a,b,c][distances.index(min(distances))]
            assert 0<=f<=4
            row[x]=(row[x]+[0,a,b,(a+b)//2,paeth][f])&255
        rows.append(row);previous=row
    pixels=b''.join(rows)
    if channels==3: pixels=b''.join(pixels[i:i+3]+b'\xff' for i in range(0,len(pixels),3))
    return w,h,pixels

subprocess.run(['rsvg-convert','-w','160','-h','160','-o',str(out/'icon.png'),str(root/'assets/tempo/svg/tempo-mark-on-dark.svg')],check=True)
# Reuse the shared icon's gradient, stretched over the recovery viewport.
source = ET.parse(root / 'assets/tempo/svg/tempo-icon-square.svg').getroot()
ns = '{http://www.w3.org/2000/svg}'
background = ET.Element(ns + 'svg', width='480', height='360', viewBox='0 0 480 360')
background.append(source.find(ns + 'defs'))
ET.SubElement(background, ns + 'rect', width='480', height='360', fill='url(#g)')
ET.ElementTree(background).write(out / 'background.svg')
subprocess.run(['rsvg-convert', '-o', str(out/'background.png'), str(out/'background.svg')], check=True)
(out/'wordmark.svg').write_text('<svg xmlns="http://www.w3.org/2000/svg" width="128" height="40"><text x="0" y="31" font-family="DejaVu Sans" font-weight="bold" font-size="32" fill="white">Tempo</text></svg>')
subprocess.run(['rsvg-convert', '-o', str(out/'wordmark.png'), str(out/'wordmark.svg')], check=True)
atlas='<svg xmlns="http://www.w3.org/2000/svg" width="1140" height="24">'
for i in range(95):
    atlas+=f'<text x="{i*12}" y="19" font-family="DejaVu Sans Mono" font-size="18" fill="white">{html.escape(chr(32+i))}</text>'
atlas+='</svg>'
(out/'font.svg').write_text(atlas)
subprocess.run(['rsvg-convert','-o',str(out/'font.png'),str(out/'font.svg')],check=True)
with (out/'ui-assets.h').open('w') as f:
    for name,path in [('icon',out/'icon.png'),('wordmark',out/'wordmark.png'),('background',out/'background.png'),('font',out/'font.png')]:
        w,h,pixels=png(path)
        f.write(f'static const unsigned int {name}_width={w}, {name}_height={h};\n')
        f.write(f'static const unsigned char {name}_pixels[]={{\n')
        for i in range(0,len(pixels),32): f.write(','.join(str(v) for v in pixels[i:i+32])+',\n')
        f.write('};\n')
