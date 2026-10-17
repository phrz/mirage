#!/usr/bin/env python3 -I
"""Whole-image and 256px-rect encode/decode timing + size for lossless screen-content codecs.
Spawn overhead is measured per tool and subtracted. Sizes in KB, times in ms (median of N)."""
import subprocess, time, os, sys, statistics, tempfile, shutil
B="/opt/homebrew/bin/"
N=int(os.environ.get("N","5"))
def t(cmd, n=N):
    xs=[]
    for _ in range(n):
        a=time.perf_counter(); subprocess.run(cmd,capture_output=True); xs.append((time.perf_counter()-a)*1000)
    return statistics.median(xs)
base={k:t([B+k,"--version"] if k!="dwebp" else [B+k,"-version"]) for k in ["cwebp","dwebp","cjxl","djxl","avifenc","avifdec","heif-enc","heif-dec"] if os.path.exists(B+k)}
codecs=[
 ("webp-ll z6", lambda i,o:[B+"cwebp","-quiet","-lossless","-z","6",i,"-o",o], ".webp", lambda i,o:[B+"dwebp",i,"-o",o,"-quiet"], "cwebp","dwebp"),
 ("webp-ll z9", lambda i,o:[B+"cwebp","-quiet","-lossless","-z","9",i,"-o",o], ".webp", lambda i,o:[B+"dwebp",i,"-o",o,"-quiet"], "cwebp","dwebp"),
 ("jxl-ll e3",  lambda i,o:[B+"cjxl",i,o,"-d","0","-e","3","--quiet"], ".jxl", lambda i,o:[B+"djxl",i,o,"--quiet"], "cjxl","djxl"),
 ("jxl-ll e7",  lambda i,o:[B+"cjxl",i,o,"-d","0","-e","7","--quiet"], ".jxl", lambda i,o:[B+"djxl",i,o,"--quiet"], "cjxl","djxl"),
 ("jxl d1 e3",  lambda i,o:[B+"cjxl",i,o,"-d","1","-e","3","--quiet"], ".jxl", lambda i,o:[B+"djxl",i,o,"--quiet"], "cjxl","djxl"),
 ("avif-ll s10",lambda i,o:[B+"avifenc","-l","-s","10","-j","1",i,o], ".avif", lambda i,o:[B+"avifdec","-j","1",i,o], "avifenc","avifdec"),
 ("avif-ll s6", lambda i,o:[B+"avifenc","-l","-s","6","-j","1",i,o], ".avif", lambda i,o:[B+"avifdec","-j","1",i,o], "avifenc","avifdec"),
 ("heic-ll",    lambda i,o:[B+"heif-enc","-L","-o",o,i], ".heic", lambda i,o:[B+"heif-dec",i,o], "heif-enc","heif-dec"),
]
def png_size(p): return os.path.getsize(p)/1024
tmp=tempfile.mkdtemp()
for src in sys.argv[1:]:
    name=os.path.basename(src)
    # a 256x256 rect crop from the middle-left (text-heavy area in these shots)
    crop=os.path.join(tmp,"crop-"+name)
    subprocess.run([B+"magick",src,"-crop","256x256+300+500","+repage",crop],capture_output=True)
    for label,img in (("full "+name,src),("256px rect of "+name,crop)):
        print(f"\n== {label}: PNG {png_size(img):.0f} KB")
        print(f"{'codec':12} {'KB':>7} {'enc ms':>8} {'dec ms':>8}")
        for cname,enc,ext,dec,et,dt in codecs:
            out=os.path.join(tmp,"o"+ext); back=os.path.join(tmp,"back.png")
            if os.path.exists(out): os.remove(out)
            n = 2 if ("heic" in cname or "e7" in cname or "s6" in cname) and "full" in label else N
            e=t(enc(img,out),n)-base.get(et,0)
            if not os.path.exists(out): print(f"{cname:12} {'fail':>7}"); continue
            d=t(dec(out,back),n)-base.get(dt,0)
            print(f"{cname:12} {os.path.getsize(out)/1024:7.1f} {max(e,0):8.1f} {max(d,0):8.1f}")
shutil.rmtree(tmp)
