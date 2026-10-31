"""pocketfft_fast — minimal SIMD FFT for the sharpness gate.

rfft2(a) mirrors numpy.fft.rfft2 semantics for float32 2-D input.
Compiled with the same pocketfft algorithm family numpy/scipy vendor.
"""

from pocketfft_fast._core import rfft2

__all__ = ["rfft2"]
