import numpy
from setuptools import Extension, setup

setup(
    name="pocketfft_fast",
    version="1.0.0",
    description="Minimal SIMD pocketfft rfft2 for float32 2-D arrays",
    packages=["pocketfft_fast"],
    package_dir={"pocketfft_fast": "pkg"},
    package_data={"pocketfft_fast": ["*.pyi"]},
    ext_modules=[
        Extension(
            "pocketfft_fast._core",
            sources=["src/pf.cpp"],
            include_dirs=["src", numpy.get_include()],
            extra_compile_args=["-O3", "-DNDEBUG", "-DPOCKETFFT_NO_MULTITHREADING"],
            extra_link_args=["-static", "-static-libgcc", "-static-libstdc++"],
        )
    ],
)
