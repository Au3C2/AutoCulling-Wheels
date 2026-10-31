#!/usr/bin/env bash
# build_av_windows.sh — Build the minimal PyAV wheel on Windows (MSVC).
#
# Mirrors build_av_macos.sh: minimal FFmpeg n8.0.3 (mov demuxer + hevc/mjpeg
# decode + swscale/swresample/avdevice only) then PyAV 17.1.0 against it,
# with the ffmpeg DLLs bundled into the av/ package. On GitHub runners the
# ffmpeg build uses the MSVC toolchain (msvc-dev-cmd), matching the official
# PyAV Windows wheel build environment.
#
# Locally validated 2026-10-31 (MinGW build, same sources/config): primary
# HEIF stream decode bit-identical to the official wheel; all 53 engine
# gates green.
#
# Usage: build_av_windows.sh [out_dir]
set -euo pipefail

FFMPEG_TAG="n8.0.3"
PYAV_VER="17.1.0"
OUT_DIR="${1:-dist}"
WORKDIR="${TEMP:-/tmp}/build_av_windows"
mkdir -p "$OUT_DIR"
# Absolutize before any cd: the build runs in a temp WORKDIR.
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

echo "=== 1. Cloning FFmpeg ${FFMPEG_TAG} ==="
git clone --depth 1 --branch "${FFMPEG_TAG}" https://github.com/FFmpeg/FFmpeg.git ffmpeg
cd ffmpeg

echo "=== 2. Configuring + building minimal FFmpeg (MSVC) ==="
# ffmpeg's MSVC dependency generation parses /showIncludes output with an awk
# script that Git-Bash's awk cannot parse. The runner's preinstalled MSYS2 awk
# can — copy it (with its runtime) into an isolated dir so we don't shadow
# MSVC's link.exe with msys2's /usr/bin/link.
mkdir -p "$WORKDIR/tools"
cp /c/msys64/usr/bin/awk.exe "$WORKDIR/tools/" 2>/dev/null || true
cp /c/msys64/usr/bin/msys-2.0.dll "$WORKDIR/tools/" 2>/dev/null || true
export PATH="$WORKDIR/tools:$PATH"
awk --version 2>/dev/null | head -1
./configure \
  --toolchain=msvc \
  --prefix="${WORKDIR}/ffmpeg_install" \
  --disable-everything \
  --disable-programs \
  --disable-doc \
  --disable-network \
  --disable-autodetect \
  --enable-shared \
  --enable-protocol=file \
  --enable-demuxer=mov,hevc,mjpeg,image2 \
  --enable-decoder=hevc,mjpeg,h264 \
  --enable-parser=hevc,mjpeg,h264 \
  --enable-swscale \
  --enable-swresample \
  --enable-avcodec \
  --enable-avformat \
  --enable-avutil \
  --enable-avfilter \
  --enable-avdevice \
  --extra-cflags="/O2"

# Running configure under Git Bash eats one level of backslash escaping in the
# /showIncludes parsing script written to ffbuild/common.mak, leaving an
# invalid awk regex (gsub(/\/, "/")) that breaks every .dep rule. Repair the
# escaping before make (python + chr() to avoid shell mangling here too).
python - <<'PY'
p = 'ffbuild/common.mak'
s = open(p, encoding='utf-8', newline='').read()
bs = chr(92)
broken = 'gsub(/' + bs + '/, "/")'
fixed = 'gsub(/' + bs + bs + '/, "/")'
if broken in s:
    open(p, 'w', encoding='utf-8', newline='').write(s.replace(broken, fixed))
    print('patched: repaired mangled awk regex in common.mak')
else:
    print('no mangled gsub found (already fine)')
PY

make -j"$(nproc)" install
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

python setup.py bdist_wheel --ffmpeg-dir="${WORKDIR}/ffmpeg_install"

echo "=== 4. Bundling ffmpeg DLLs into the av/ package ==="
python - <<'PYEOF'
import base64, hashlib, os, shutil, zipfile

whl = [f for f in os.listdir('dist') if f.endswith('.whl')][0]
prefix = os.path.join('..', 'ffmpeg_install', 'bin')
work = 'unpacked'
shutil.rmtree(work, ignore_errors=True)
with zipfile.ZipFile(os.path.join('dist', whl)) as z:
    z.extractall(work)

import glob
dlls = sorted(glob.glob(os.path.join(prefix, '*.dll')))
assert dlls, 'no ffmpeg DLLs found in ' + prefix
for src in dlls:
    shutil.copy2(src, os.path.join(work, 'av', os.path.basename(src)))

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
PYEOF

cp dist/*.whl "$OUT_DIR/"
echo "SUCCESS: minimal PyAV wheel built at $OUT_DIR"
