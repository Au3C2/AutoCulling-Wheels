#!/usr/bin/env bash
set -euo pipefail

FFMPEG_TAG="n8.0.3"
PYAV_VER="17.1.0"
OUT_DIR="${1:-dist}"
mkdir -p "${OUT_DIR}"
ABS_OUT_DIR="$(cd "${OUT_DIR}" && pwd)"

WORKDIR="${TMPDIR:-/tmp}/build_av_macos"
rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

echo "=== 1. Building minimal FFmpeg (${FFMPEG_TAG}) ==="
git clone --depth 1 --branch "${FFMPEG_TAG}" https://github.com/FFmpeg/FFmpeg.git ffmpeg
cd ffmpeg
./configure \
  --prefix="${WORKDIR}/ffmpeg_install" \
  --disable-everything \
  --disable-programs \
  --disable-doc \
  --disable-network \
  --disable-autodetect \
  --enable-shared \
  --enable-pthreads \
  --enable-pic \
  --enable-videotoolbox \
  --enable-audiotoolbox \
  --enable-protocol=file \
  --enable-demuxer=mov,hevc,mjpeg,image2 \
  --enable-decoder=hevc,mjpeg,h264 \
  --enable-parser=hevc,mjpeg,h264 \
  --enable-hwaccel=hevc_videotoolbox \
  --enable-swscale \
  --enable-swresample \
  --enable-avcodec \
  --enable-avformat \
  --enable-avutil \
  --enable-avfilter \
  --enable-avdevice \
  --extra-cflags="-mmacosx-version-min=11.0" \
  --extra-ldflags="-mmacosx-version-min=11.0"

make -j$(sysctl -n hw.ncpu) install
cd "${WORKDIR}"

echo "=== 2. Building PyAV (${PYAV_VER}) against minimal FFmpeg ==="
python3 -c "
import urllib.request, json
url = 'https://pypi.org/pypi/av/${PYAV_VER}/json'
data = json.loads(urllib.request.urlopen(url).read())
sdist = [u for u in data['urls'] if u['packagetype'] == 'sdist'][0]
urllib.request.urlretrieve(sdist['url'], 'av.tar.gz')
"
tar -xzf av.tar.gz
cd "av-${PYAV_VER}"

# Compatibility patch for Cython 3.1+
python3 -c "
p = 'av/container/pyio.py'
text = open(p).read()
if 'seek_func: seek_func_t = pyio_seek' in text:
    open(p, 'w').write(text.replace('seek_func: seek_func_t = pyio_seek', 'seek_func = pyio_seek', 1))
"

python3 setup.py bdist_wheel --ffmpeg-dir="${WORKDIR}/ffmpeg_install"

echo "=== 3. Delocating PyAV wheel ==="
delocate-wheel -v -w "${ABS_OUT_DIR}" dist/*.whl
echo "SUCCESS: Standalone PyAV wheel built at ${OUT_DIR}"
