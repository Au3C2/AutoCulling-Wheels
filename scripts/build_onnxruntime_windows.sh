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

echo "=== 2. Build wheel (documented 3-step reduced-ops flow) ==="
cp "$HERE/onnxruntime_windows_reduced_ops.config" reduced_ops.config

# Step A: configure. REDUCED_OPS_BUILD is passed as an explicit cmake define
# instead of --include_ops_by_config: build.py's update phase imports
# reduce_op_kernels in-process, and its `from util import parse_config`
# resolves against a stale sys.modules['util'] on some environments
# (ImportError on the GitHub runner; worked locally). The standalone
# reduce step below replaces that fragile in-process call.
python tools/ci_build/build.py \
  --config Release \
  --build_dir build \
  --build_wheel \
  --use_dml \
  --cmake_extra_defines onnxruntime_REDUCED_OPS_BUILD=ON \
  --cmake_generator Ninja \
  --parallel "$NUMBER_OF_PROCESSORS" \
  --skip_tests \
  --update

# Step B: prune the kernel registrations (standalone, fresh interpreter).
python tools/ci_build/reduce_op_kernels.py reduced_ops.config --cmake_build_dir build/Release

# Step C: compile. REDUCED_OPS_BUILD is already configured; update=False
# keeps build.py from re-importing reduce_op_kernels in-process.
python tools/ci_build/build.py \
  --config Release \
  --build_dir build \
  --build_wheel \
  --use_dml \
  --cmake_extra_defines onnxruntime_REDUCED_OPS_BUILD=ON \
  --cmake_generator Ninja \
  --parallel "$NUMBER_OF_PROCESSORS" \
  --skip_tests \
  --build

WHEEL=$(ls build/Release/dist/*.whl)
cp "$WHEEL" "$OUT_DIR/"
echo "SUCCESS: onnxruntime wheel built at $OUT_DIR ($(basename "$WHEEL"))"
