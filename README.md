# AutoCulling-Wheels

Prebuilt minimal third-party wheels for [AutoCulling](https://github.com/Au3C2/AutoCullingF1).

## Motivation

Standard PyPI wheels such as `opencv-python` bundle monolithic dependency stacks (including complete FFmpeg 6.x/7.x toolchains, OpenEXR, codec libraries, etc.), inflating desktop application packages by over 100 MB per platform.

AutoCulling only needs image decoding (`imgcodecs`), image processing (`imgproc`), core arrays (`core`), and Python bindings (`python3`), with video/container handling handled by dedicated lightweight decoders (VideoToolbox on macOS, PyAV on Windows).

By compiling minimal, standalone wheels:
- **macOS (arm64)**: `cv2` shrinks from 119 MB (with 99 bundled `.dylibs`) to a single 16.4 MB `cv2.abi3.so` (7.6 MB compressed `.whl`), linking exclusively to system frameworks.
- **Windows (x64)**: `cv2` eliminates redundant bundled DLLs.
- Zero loss in image decoding precision or throughput.

## Releases

Wheels are published under GitHub Releases for automated consumption by AutoCulling CI/CD.
