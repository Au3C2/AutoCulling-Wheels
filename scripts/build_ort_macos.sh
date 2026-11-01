#!/usr/bin/env bash
# build_ort_macos.sh — Build the reduced-ops ONNX Runtime wheel for AutoCulling (macOS arm64).
#
# Upstream ONNX Runtime 1.23's minimal_build does not support Python bindings
# (--build_wheel + --minimal_build is rejected), so this uses a FULL build with
# reduced operator registration: only the 29 ops used by the 3 production
# models are registered; contrib/ML ops and the Azure EP are compiled out; the
# CoreML EP is kept (the macOS scoring chain depends on it).
#
# Key flags (do not drop):
#   -Donnxruntime_BUILD_UNIT_TESTS=OFF   test targets fail with -Werror on
#                                        unused vars in reduced builds
#   CMAKE_POLICY_VERSION_MINIMUM=3.5     CMake 4.x compat with the pinned
#                                        protobuf/psimd FetchContent deps
#
# Output: dist/onnxruntime_custom-1.23.2-*.whl
set -euo pipefail

ORT_VER="1.23.2"
OPS_CONFIG="$(cd "$(dirname "$0")" && pwd)/onnxruntime_required_ops.config"
OUT_DIR="${1:-dist}"
mkdir -p "${OUT_DIR}"
ABS_OUT_DIR="$(cd "${OUT_DIR}" && pwd)"

# Pin the deployment target to 12.0 — the official onnxruntime 1.23.2 macOS
# wheel baseline (CoreML provider needs the MLMultiArray Float16 APIs from
# macOS 12). The unguarded-availability warning for the macOS 13 compute-unit
# enum is downgraded from -Werror (the official build does the same); the
# runtime code paths behind it are guarded by CoreML EP capability checks.
export MACOSX_DEPLOYMENT_TARGET=12.0
export CMAKE_OSX_ARCHITECTURES=arm64
# CoreML provider source patch: MLComputeUnitsCPUAndNeuralEngine is a
# macOS 13 enum used unguarded at model.mm:539, which trips
# -Werror,-Wunguarded-availability-new when building against the official
# 12.0 deployment target (ORT sets COMPILE_WARNING_AS_ERROR globally and
# neither CMAKE_OBJCXX_FLAGS nor OBJCXXFLAGS reach its ObjC++ targets).
# The enum is a compile-time constant (no dyld binding), so wrapping it in
# @available keeps identical behavior on macOS 13+ and falls back to
# MLComputeUnitsAll on 12.

WORKDIR="${TMPDIR:-/tmp}/build_ort_macos"
rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

echo "=== 1. Cloning onnxruntime v${ORT_VER} (recursive) ==="
git clone --depth 1 --branch "v${ORT_VER}" --recursive \
  https://github.com/microsoft/onnxruntime.git ort_src
cd ort_src

cat > patch_coreml_ane.py <<'PYEOF'
from pathlib import Path

p = Path('onnxruntime/core/providers/coreml/model/model.mm')
t = p.read_text()
old = """      } else if (coreml_compute_unit & COREML_FLAG_ONLY_ENABLE_DEVICE_WITH_ANE) {
        config.computeUnits = MLComputeUnitsCPUAndNeuralEngine;  // Apple Neural Engine
      } else {"""
new = """      } else if (coreml_compute_unit & COREML_FLAG_ONLY_ENABLE_DEVICE_WITH_ANE) {
        if (@available(macOS 13.0, *)) {
          config.computeUnits = MLComputeUnitsCPUAndNeuralEngine;  // Apple Neural Engine
        } else {
          config.computeUnits = MLComputeUnitsAll;
        }
      } else {"""
assert old in t, 'model.mm pattern not found'
p.write_text(t.replace(old, new, 1))
print('model.mm patched')
PYEOF
python3 patch_coreml_ane.py

echo "=== 2. Configuring reduced-ops build ==="
PYTHON_BIN="${PYTHON_BIN:-python3}"
"${PYTHON_BIN}" tools/ci_build/build.py \
  --build_dir "${WORKDIR}/ort_build" \
  --config Release \
  --disable_contrib \
  --disable_ml_ops \
  --include_ops_by_config "${OPS_CONFIG}" \
  --use_coreml \
  --build_wheel \
  --wheel_name_suffix custom \
  --parallel "${ORT_JOBS:-2}" \
  --skip_tests \
  --cmake_path="$(command -v cmake)" \
  --ctest_path="$(command -v ctest)" \
  --cmake_extra_defines="CMAKE_POLICY_VERSION_MINIMUM=3.5" \
  --cmake_extra_defines="onnxruntime_BUILD_UNIT_TESTS=OFF" \
  --cmake_generator="Unix Makefiles"

echo "=== 3. Locating built wheel ==="
WHEEL=$(find "${WORKDIR}/ort_build" -name "onnxruntime_custom-*.whl" | head -1)
if [ -z "${WHEEL}" ]; then
    echo "ERROR: wheel not found in build dir" >&2
    exit 1
fi
cp "${WHEEL}" "${ABS_OUT_DIR}/"
echo "SUCCESS: $(basename "${WHEEL}") -> ${ABS_OUT_DIR}/"
