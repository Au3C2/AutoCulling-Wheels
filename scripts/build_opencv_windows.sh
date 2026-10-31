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
cp dist/*.whl "$OUT_DIR/"
echo "SUCCESS: minimal OpenCV wheel built at $OUT_DIR"
