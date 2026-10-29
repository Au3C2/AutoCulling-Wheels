#!/usr/bin/env bash
set -euo pipefail

OPENCV_PYTHON_TAG="93"
OUT_DIR="${1:-dist}"
mkdir -p "${OUT_DIR}"

WORKDIR="${TMPDIR:-/tmp}/build_opencv_macos"
rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

echo "Cloning opencv-python tag ${OPENCV_PYTHON_TAG}..."
git clone --depth 1 --branch "${OPENCV_PYTHON_TAG}" https://github.com/opencv/opencv-python.git opencv-python
cd opencv-python
git submodule update --init --depth 1 opencv

export CMAKE_ARGS="-DWITH_FFMPEG=OFF \
  -DWITH_OPENEXR=OFF \
  -DWITH_GSTREAMER=OFF \
  -DWITH_CUDA=OFF \
  -DWITH_OPENCL=OFF \
  -DBUILD_TESTS=OFF \
  -DBUILD_PERF_TESTS=OFF \
  -DBUILD_EXAMPLES=OFF \
  -DBUILD_opencv_apps=OFF \
  -DBUILD_LIST=core,imgproc,imgcodecs,python3 \
  -DWITH_TIFF=ON \
  -DWITH_JPEG=ON \
  -DWITH_WEBP=ON \
  -DWITH_PNG=ON \
  -DCMAKE_BUILD_TYPE=Release"

# Tolerant patch for missing type annotations and optional files
python3 -c "
p = 'setup.py'
text = open(p).read()
old = 'if not found and \"gapi\" not in relpath_re:'
new = 'if not found and \"gapi\" not in relpath_re and \"py.typed\" not in relpath_re and \"typing\" not in relpath_re:'
if old in text:
    open(p, 'w').write(text.replace(old, new, 1))
"

python3 setup.py build_ext

# Assemble standalone package
STAGE="${WORKDIR}/wheel_stage"
rm -rf "${STAGE}"
mkdir -p "${STAGE}/cv2" "${STAGE}/opencv_python_custom-5.0.0.93.dist-info"

CV2_BUILD=$(find _skbuild -type d -path "*/cmake-install/python/cv2" | head -1)
if [ -z "${CV2_BUILD}" ]; then
    echo "ERROR: cv2 build directory not found"
    exit 1
fi

cp -r "${CV2_BUILD}"/* "${STAGE}/cv2/"
# Move so to root of cv2 if nested in python-3
if [ -d "${STAGE}/cv2/python-3" ]; then
    mv "${STAGE}/cv2/python-3"/* "${STAGE}/cv2/"
    rmdir "${STAGE}/cv2/python-3"
fi

cat <<'EOF' > "${STAGE}/opencv_python_custom-5.0.0.93.dist-info/METADATA"
Metadata-Version: 2.1
Name: opencv-python-custom
Version: 5.0.0.93
Summary: Standalone minimal OpenCV for AutoCulling (no FFmpeg, no OpenEXR)
Requires-Python: >=3.6
Requires-Dist: numpy
EOF

cat <<'EOF' > "${STAGE}/opencv_python_custom-5.0.0.93.dist-info/WHEEL"
Wheel-Version: 1.0
Generator: AutoCulling-Wheels
Root-Is-Purelib: false
Tag: cp310-cp310-macosx_11_0_arm64
EOF

echo "cv2" > "${STAGE}/opencv_python_custom-5.0.0.93.dist-info/top_level.txt"

wheel pack "${STAGE}" -d "${OUT_DIR}"
echo "SUCCESS: Wheel built at ${OUT_DIR}"
