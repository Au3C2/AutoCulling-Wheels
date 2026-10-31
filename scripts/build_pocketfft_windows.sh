#!/usr/bin/env bash
# build_pocketfft_windows.sh — Build the pocketfft_fast wheel on Windows (MSVC).
#
# Sources live in scripts/pocketfft_fast/ (pf.cpp wraps pocketfft_hdronly.h,
# the same pocketfft algorithm family numpy/scipy vendor). Locally validated
# on 2026-10-31: output bit-identical to scipy.fft, 3.7 ms/frame vs numpy's
# 19 ms on the sharpness HF gate frame.
#
# Usage: build_pocketfft_windows.sh [out_dir]
set -euo pipefail

OUT_DIR="${1:-dist}"
mkdir -p "$OUT_DIR"
# Absolutize before any cd: the build runs in a temp WORKDIR.
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "=== Building pocketfft_fast wheel (MSVC) ==="
cp -r "$HERE/pocketfft_fast" "$TEMP/pocketfft_build_src"
cd "$TEMP/pocketfft_build_src"
python setup.py bdist_wheel
cp dist/*.whl "$OUT_DIR/"
echo "SUCCESS: pocketfft_fast wheel built at $OUT_DIR"
