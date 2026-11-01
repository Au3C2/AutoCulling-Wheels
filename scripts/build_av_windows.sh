#!/usr/bin/env bash
# build_av_windows.sh — Build the minimal PyAV wheel on Windows (MinGW via MSYS2).
#
# Minimal FFmpeg n8.0.3 (mov demuxer + hevc/mjpeg decode + swscale/swresample/
# avdevice only) with plain gcc, then PyAV 17.1.0 compiled against it with the
# same MinGW toolchain (distutils mingw32 compiler), ffmpeg DLLs bundled into
# av/. This mirrors the locally validated recipe bit for bit (the MSVC
# toolchain variant crashes in HEVC decode: cl 19.5x-built ffmpeg reserves a
# 1 MB stack and miscompiles at av.open, while the MinGW build decodes
# bit-identically to the official PyAV wheel).
#
# Run under the MSYS2 mingw64 shell provided by the workflow (setup-msys2);
# PATH must contain: mingw64/bin (gcc/make/nasm), the Windows venv Scripts
# (python), and $OUT_DIR must be absolute.
#
# Usage: build_av_windows.sh [abs_out_dir]
set -euo pipefail

FFMPEG_TAG="n8.0.3"
PYAV_VER="17.1.0"
OUT_DIR="${1:?usage: build_av_windows.sh <abs_out_dir>}"
WORKDIR="${TEMP:-/tmp}/build_av_windows"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

echo "=== toolchain ==="
gcc --version | head -1
nasm -v
python --version

echo "=== 1. Cloning FFmpeg ${FFMPEG_TAG} ==="
git clone --depth 1 --branch "${FFMPEG_TAG}" https://github.com/FFmpeg/FFmpeg.git ffmpeg
cd ffmpeg

echo "=== 2. Configuring + building minimal FFmpeg (MinGW gcc) ==="
./configure \
  --prefix="${WORKDIR}/ffmpeg_install" \
  --enable-shared --disable-static --disable-programs --disable-doc \
  --disable-network --disable-autodetect \
  --disable-zlib --disable-bzlib --disable-lzma --disable-iconv \
  --disable-everything \
  --enable-demuxer=mov \
  --enable-decoder=hevc,mjpeg \
  --enable-parser=hevc,mjpeg \
  --enable-protocol=file,pipe \
  --extra-ldflags="-Wl,--stack,8388608" \
  > configure.log 2>&1
tail -5 configure.log

make -j"$(nproc)" install > make.log 2>&1
tail -2 make.log
cd "$WORKDIR"

echo "=== 3. Building PyAV ${PYAV_VER} against minimal FFmpeg ==="
python -c "
import urllib.request, json
url = 'https://pypi.org/pypi/av/${PYAV_VER}/json'
data = json.loads(urllib.request.urlopen(url).read())
sdist = [u for u in data['urls'] if u['packagetype'] == 'sdist'][0]
urllib.request.urlretrieve(sdist['url'], 'av.tar.gz')
"
tar -xzf av.tar.gz
cd "av-${PYAV_VER}"

# Compatibility patch for Cython 3.1+ (same as build_av_macos.sh)
python -c "
p = 'av/container/pyio.py'
text = open(p).read()
if 'seek_func: seek_func_t = pyio_seek' in text:
    open(p, 'w').write(text.replace('seek_func: seek_func_t = pyio_seek', 'seek_func = pyio_seek', 1))
"

# MinGW toolchain for the extension (locally validated configuration):
# distutils mingw32 compiler + MS_WIN64 (pyconfig.h only defines it under
# _MSC_VER) + fully static MinGW runtime so the pyd has no libgcc/libstdc++/
# libwinpthread imports, + gcc-14-compatible pointer-warning downgrade.
printf '[build_ext]\ncompiler=mingw32\ndefine=MS_WIN64\n' > setup.cfg
python -c "
p = 'setup.py'
s = open(p).read()
old = '''extra_compile_args = []
if platform.system() != \"Windows\":
    extra_compile_args.append(\"-Wno-error=incompatible-pointer-types\")'''
new = '''extra_compile_args = [\"-Wno-error=incompatible-pointer-types\"]
extra_link_args = [\"-static\", \"-static-libgcc\", \"-static-libstdc++\"]'''
assert old in s, 'setup.py pattern not found'
open(p, 'w', newline=chr(10)).write(s.replace(old, new))
print('patched setup.py for mingw')
"

python setup.py --ffmpeg-dir="${WORKDIR}/ffmpeg_install" bdist_wheel

echo "=== 4. Bundling ffmpeg DLLs into the av/ package ==="
python - <<'PY'
import base64, glob, hashlib, os, shutil, zipfile

whl = [f for f in os.listdir('dist') if f.endswith('.whl')][0]
prefix = os.path.join('..', 'ffmpeg_install', 'bin')
work = 'unpacked'
shutil.rmtree(work, ignore_errors=True)
with zipfile.ZipFile(os.path.join('dist', whl)) as z:
    z.extractall(work)

dlls = sorted(glob.glob(os.path.join(prefix, '*.dll')))
assert dlls, 'no ffmpeg DLLs found in ' + prefix
mingw = os.environ.get('MINGW_BIN', '')
pthread = os.path.join(mingw, 'libwinpthread-1.dll') if mingw else None
for src in dlls:
    shutil.copy2(src, os.path.join(work, 'av', os.path.basename(src)))
if pthread and os.path.exists(pthread):
    shutil.copy2(pthread, os.path.join(work, 'av', 'libwinpthread-1.dll'))

rec_path = os.path.join(work, 'av-17.1.0.dist-info', 'RECORD')
lines = [l for l in open(rec_path, encoding='utf-8').read().splitlines() if l.strip()]
seen = {l.split(',')[0] for l in lines}
for src in dlls:
    name = os.path.basename(src)
    rel = 'av/' + name
    if rel in seen:
        continue
    data = open(os.path.join(work, 'av', name), 'rb').read()
    h = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b'=').decode()
    lines.append('av/%s,sha256=%s,%d' % (name, h, len(data)))
pthread_rel = 'av/libwinpthread-1.dll'
if pthread and os.path.exists(pthread) and pthread_rel not in seen:
    data = open(os.path.join(work, 'av', 'libwinpthread-1.dll'), 'rb').read()
    h = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b'=').decode()
    lines.append('av/libwinpthread-1.dll,sha256=%s,%d' % (h, len(data)))
open(rec_path, 'w', encoding='utf-8', newline='\n').write('\n'.join(lines) + '\n')

out = os.path.join('dist', whl)
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
    for root, dirs, files in os.walk(work):
        for f in files:
            full = os.path.join(root, f)
            rel = os.path.relpath(full, work).replace(os.sep, '/')
            z.write(full, rel)
shutil.rmtree(work)
print('bundled wheel: %.2f MB' % (os.path.getsize(out) / 1048576))
PY

cp dist/*.whl "$OUT_DIR/"
echo "SUCCESS: minimal PyAV wheel built at $OUT_DIR"
