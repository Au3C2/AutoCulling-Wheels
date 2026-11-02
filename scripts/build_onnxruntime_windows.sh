#!/usr/bin/env bash
# build_onnxruntime_windows.sh — Build the reduced-ops DirectML onnxruntime wheel.
#
# P2-3: the official onnxruntime-directml wheel ships the full ~1500-op kernel
# registry (64 MB capi); AutoCulling's three models (f1_yolov8n / p4_car_model /
# yolov8n) use only 29 standard ops + the com.microsoft fused kernels that
# appear after ORT's graph transformers run (QuickGelu, DmlFusedConv). This
# script builds ORT v1.23.0 with the committed reduced-ops config
# (onnxruntime_windows_reduced_ops.config, generated from the OPTIMIZED graphs
# — regenerating it from the raw ONNX models misses the fused kernels and
# breaks inference) and produces a wheel whose capi is 46 MB vs 64 MB, with
# outputs verified bit-identical to the official wheel and throughput at
# parity (interleaved A/B, 2026-11-01).
#
# Prereqs (provided by the workflow job): VS dev cmd (cl/link/cmake/ninja),
# python with numpy+onnx+setuptools<80, git.
#
# Usage: build_onnxruntime_windows.sh [out_dir]
set -euo pipefail

ORT_VER="v1.23.0"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${1:?usage: build_onnxruntime_windows.sh <abs_out_dir>}"
mkdir -p "$OUT_DIR"
WORKDIR="${TEMP:-/tmp}/build_ort_windows"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

echo "=== toolchain ==="
cmake --version | head -1
python --version

echo "=== 1. Cloning onnxruntime ${ORT_VER} ==="
# The big clone occasionally dies mid-transfer on flaky links; retry.
for attempt in 1 2 3; do
  if git clone --depth 1 --branch "${ORT_VER}" https://github.com/microsoft/onnxruntime.git ort; then
    break
  fi
  if [ "$attempt" = "3" ]; then
    echo "clone failed after 3 attempts" >&2
    exit 1
  fi
  rm -rf ort
  echo "clone attempt ${attempt} failed; retrying in 15s..."
  sleep 15
done
cd ort

# MSVC 18 deprecates the non-string [[gsl::suppress(x)]] form (C4875,
# escalated to an error by /WX). Both fixes must land BEFORE configure:
#   - the non-CUDA gsl FetchContent branch carries no PATCH_COMMAND, so the
#     DirectML build compiles the upstream macro;
#   - the upstream gsl zip has CRLF line endings, which defeats
#     `patch --binary` ("Hunk FAILED: different line endings") even with
#     --ignore-whitespace.
# Both branches therefore get a byte-level PATCH_COMMAND (scripts/patch_gsl_
# macro.py rewrites the macro in-place inside the downloaded gsl tree; the
# macro definition lines contain no line terminators, so CRLF is irrelevant).
python - <<'PYEOF'
from pathlib import Path

d = Path('cmake/external/onnxruntime_external_deps.cmake')
t = d.read_text()

# All paths in PATCH_COMMAND must be forward-slash absolute literals with NO
# cmake variable expansion: the command is written verbatim into the
# FetchContent sub-build CMakeLists, where backslash escapes from expanded
# values (${Python_EXECUTABLE} -> C:\hostedtoolcache\..., $ENV{...} ->
# D:\a\...) fail to parse ("Invalid character escape"). 'python' resolves
# through the job PATH at patch-execution time.
import os
ws = os.environ['GITHUB_WORKSPACE'].replace('\\', '/')
cmd = 'python ' + ws + '/scripts/patch_gsl_macro.py'
old_cuda = "PATCH_COMMAND ${Patch_EXECUTABLE} --binary --ignore-whitespace -p1 < ${PROJECT_SOURCE_DIR}/patches/gsl/1064.patch"
assert t.count(old_cuda) == 1, 'CUDA gsl PATCH_COMMAND not found'
t = t.replace(old_cuda, "PATCH_COMMAND " + cmd, 1)

anchor = """    URL_HASH SHA1=${DEP_SHA1_microsoft_gsl}
    EXCLUDE_FROM_ALL
    FIND_PACKAGE_ARGS 4.0 NAMES Microsoft.GSL
  )"""
patched = """    URL_HASH SHA1=${DEP_SHA1_microsoft_gsl}
    PATCH_COMMAND """ + cmd + """
    EXCLUDE_FROM_ALL
    FIND_PACKAGE_ARGS 4.0 NAMES Microsoft.GSL
  )"""
n = t.count(anchor)
assert n == 1, 'expected exactly 1 unpatched gsl declare, found %d' % n
t = t.replace(anchor, patched, 1)

d.write_text(t)
print('gsl PATCH_COMMAND switched to byte-level rewriter on both branches')
PYEOF

echo "=== 2. Build wheel (single-step reduced-ops flow, same as macOS) ==="
# The earlier 3-step variant (configure with REDUCED_OPS_BUILD=ON, then a
# standalone reduce_op_kernels pass, then build) cannot work: the reduced
# kernel registration files must exist at CONFIGURE time, because they are
# what populates the onnxruntime_providers target source list ("No SOURCES
# given to target: onnxruntime_providers"). The single-step
# --include_ops_by_config flow runs the reducer inside build.py's update
# phase and is what the macOS wheel build already validates; its historical
# ImportError was just a missing flatbuffers install (fixed in the job's
# pip step).
python tools/ci_build/build.py \
  --config Release \
  --build_dir build \
  --build_wheel \
  --use_dml \
  --disable_contrib \
  --disable_ml_ops \
  --include_ops_by_config "$HERE/onnxruntime_windows_reduced_ops.config" \
  --cmake_extra_defines CMAKE_POLICY_VERSION_MINIMUM=3.5 \
  --cmake_extra_defines "CMAKE_CXX_FLAGS_RELEASE=-O2 -Ob2 -DNDEBUG -wd4100 -wd4244 -wd4267 -wd4996" \
  --cmake_generator Ninja \
  --parallel "$NUMBER_OF_PROCESSORS" \
  --skip_tests

WHEEL=$(ls build/Release/dist/*.whl)
mkdir -p "$OUT_DIR"
cp "$WHEEL" "$OUT_DIR/"
echo "SUCCESS: onnxruntime wheel built at $OUT_DIR ($(basename "$WHEEL"))"
