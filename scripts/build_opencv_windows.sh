#!/usr/bin/env bash
# build_opencv_windows.sh — Build the minimal standalone OpenCV wheel on Windows.
#
# Same recipe as build_opencv_macos.sh (P2-1) applied to Windows: opencv-python
# tag 93 + opencv 5.0.0, BUILD_LIST=core,imgproc,imgcodecs,python3, no FFmpeg/
# OpenEXR/GUI. On GitHub runners the MSVC toolchain is preinstalled, so the
# standard opencv-python scikit-build path works without the MinGW workarounds
# the local build needed.
#
# Locally validated 2026-10-31: knife-edge gate file IMG_20260314_160318_240.jpg
# scores bit-identical; all 53 engine gates green.
#
# Usage: build_opencv_windows.sh [out_dir]
set -euo pipefail

OPENCV_PY_TAG="93"   # opencv-python release 5.0.0.93
OUT_DIR="${1:-dist}"
WORKDIR="${TEMP:-/tmp}/build_opencv_windows"
mkdir -p "$OUT_DIR"
# Absolutize before any cd: the build runs in a temp WORKDIR.
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

echo "=== 1. Cloning opencv-python ${OPENCV_PY_TAG} + opencv 5.0.0 submodule ==="
git clone --depth 1 --branch "${OPENCV_PY_TAG}" https://github.com/opencv/opencv-python.git
cd opencv-python
git submodule update --init --depth 1 opencv

# opencv-python's Windows packaging asserts several cmake output patterns exist
# (bundled ffmpeg DLL, py.typed, ...); the minimal WITH_FFMPEG=OFF build
# legitimately omits some of them. Downgrade the assertion to a warning so the
# wheel packaging reflects what was actually built.
python - <<'PY'
p = 'setup.py'
s = open(p).read()
old = '''                    if not found and "gapi" not in relpath_re:
                        raise Exception("Not found: '%s'" % relpath_re)'''
new = '''                    if not found:
                        print("WARNING: skipping missing cmake output: %s" % relpath_re)'''
assert old in s, 'setup.py pattern not found'
open(p, 'w', newline='\n').write(s.replace(old, new))
print('patched: cmake-output classifier skips missing patterns')
PY

echo "=== 2. Installing build tools ==="
pip install -q scikit-build cmake ninja wheel numpy

echo "=== 3. Building wheel (skbuild / MSVC) ==="
export CMAKE_ARGS="-DWITH_FFMPEG=OFF \
 -DWITH_OPENEXR=OFF \
 -DWITH_GSTREAMER=OFF \
 -DWITH_CUDA=OFF \
 -DWITH_OPENCL=OFF \
 -DWITH_ITT=OFF \
 -DWITH_IPP=OFF \
 -DBUILD_TESTS=OFF \
 -DBUILD_PERF_TESTS=OFF \
 -DBUILD_EXAMPLES=OFF \
 -DBUILD_opencv_apps=OFF \
 -DBUILD_LIST=core,imgproc,imgcodecs,python3 \
 -DWITH_TIFF=ON -DWITH_JPEG=ON -DWITH_WEBP=ON -DWITH_PNG=ON \
 -DCMAKE_BUILD_TYPE=Release"
python setup.py bdist_wheel

echo "=== 4. Renaming wheel to opencv-python-custom (matches pyproject pins) ==="
export OUT_DIR
python - <<'PY'
import os, shutil, zipfile

src = [f for f in os.listdir('dist') if f.endswith('.whl')][0]
work = 'renamed'
shutil.rmtree(work, ignore_errors=True)
with zipfile.ZipFile(os.path.join('dist', src)) as z:
    z.extractall(work)

old_di = os.path.join(work, 'opencv_python-5.0.0.93.dist-info')
new_di = os.path.join(work, 'opencv_python_custom-5.0.0.93.dist-info')
if os.path.isdir(old_di) and not os.path.isdir(new_di):
    os.rename(old_di, new_di)
meta = os.path.join(new_di, 'METADATA')
raw = open(meta, 'rb').read()
print('METADATA head repr:', repr(raw[:120]))
import re
raw2, nsub = re.subn(rb'^Name: opencv[_-]python\r?$', b'Name: opencv-python-custom', raw,
                     count=1, flags=re.M)
assert nsub == 1, 'METADATA Name rename failed (see head repr above)'
open(meta, 'wb').write(raw2)
print('METADATA Name -> opencv-python-custom')

record = os.path.join(new_di, 'RECORD')
lines = [l.replace('opencv_python-5.0.0.93.dist-info', 'opencv_python_custom-5.0.0.93.dist-info')
         for l in open(record, encoding='utf-8').read().splitlines() if l.strip()]
open(record, 'w', encoding='utf-8', newline='').write('\n'.join(lines) + '\n')

out = os.path.join(os.environ.get('OUT_DIR', 'dist'),
                   'opencv_python_custom-5.0.0.93-cp310-cp310-win_amd64.whl')
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
    for root, dirs, files in os.walk(work):
        for f in files:
            full = os.path.join(root, f)
            rel = os.path.relpath(full, work).replace(os.sep, '/')
            z.write(full, rel)
shutil.rmtree(work)
print('renamed wheel:', out)
PY

echo "SUCCESS: minimal OpenCV wheel built at $OUT_DIR"
