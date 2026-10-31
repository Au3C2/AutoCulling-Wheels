// pf.cpp — minimal SIMD FFT extension for AutoCulling's sharpness gate.
//
// Wraps pocketfft_hdronly.h (Martin Reineck's pocketfft, the same algorithm
// family numpy/scipy vendor) and exposes numpy.fft.rfft2-compatible rfft2
// for float32 2-D input, returning complex64 (h, w//2+1).
//
// Build: gcc/g++ >= 9, C++17. No third-party deps.

#define NPY_NO_DEPRECATED_API NPY_1_7_API_VERSION
#include <Python.h>
#include <numpy/arrayobject.h>

#include <complex>
#include <cstddef>
#include <vector>

#include "pocketfft_hdronly.h"

static PyObject *rfft2(PyObject *self, PyObject *arg) {
  PyObject *obj = PyArray_FROM_OTF(arg, NPY_FLOAT32, NPY_ARRAY_IN_ARRAY);
  if (!obj) return nullptr;
  PyArrayObject *a = reinterpret_cast<PyArrayObject *>(obj);

  if (PyArray_NDIM(a) != 2) {
    Py_DECREF(obj);
    PyErr_SetString(PyExc_ValueError, "rfft2 expects a 2-D float32 array");
    return nullptr;
  }
  const npy_intp h = PyArray_DIM(a, 0), w = PyArray_DIM(a, 1);
  const npy_intp cols = w / 2 + 1;

  npy_intp out_dims[2] = {h, cols};
  PyObject *out_obj = PyArray_SimpleNew(2, out_dims, NPY_COMPLEX64);
  if (!out_obj) { Py_DECREF(obj); return nullptr; }
  PyArrayObject *out = reinterpret_cast<PyArrayObject *>(out_obj);

  const float *in = static_cast<const float *>(PyArray_DATA(a));
  std::complex<float> *outp =
      reinterpret_cast<std::complex<float> *>(PyArray_DATA(out));

  try {
    // shape_t is std::vector<unsigned long long>, stride_t std::vector<long long>
    // on the reference pocketfft build; use explicit typedefs and casts so both
    // MinGW and MSVC accept the initializers without narrowing errors.
    using pf_shape_t = pocketfft::shape_t;
    using pf_stride_t = pocketfft::stride_t;
    using dim_t = pf_shape_t::value_type;
    using stride_elem_t = pf_stride_t::value_type;
    pf_shape_t shape = {static_cast<dim_t>(h), static_cast<dim_t>(w)};
    pf_stride_t s_in = {static_cast<stride_elem_t>(w) * 4, 4};
    pf_stride_t s_out = {static_cast<stride_elem_t>(cols) * 8, 8};

    // Stage 1: real->complex along the last axis, out-of-place.
    pocketfft::r2c<float>(shape, s_in, s_out, 1, pocketfft::FORWARD,
                          in, outp, 1.0f, 0);
    // Stage 2: complex->complex along the first axis, in-place on the
    // half spectrum.
    pf_shape_t shape2 = {static_cast<dim_t>(h), static_cast<dim_t>(cols)};
    pf_stride_t s2 = {static_cast<stride_elem_t>(cols) * 8, 8};
    pocketfft::c2c<float>(shape2, s2, s2, pocketfft::shape_t{0}, pocketfft::FORWARD,
                          outp, outp, 1.0f, 0);
  } catch (std::exception &e) {
    Py_DECREF(out_obj);
    Py_DECREF(obj);
    PyErr_SetString(PyExc_RuntimeError, e.what());
    return nullptr;
  }

  Py_DECREF(obj);
  return out_obj;
}

static PyMethodDef pf_methods[] = {
    {"rfft2", rfft2, METH_O, "rfft2(float32 2-D) -> complex64 (h, w//2+1)."},
    {nullptr, nullptr, 0, nullptr}};

static struct PyModuleDef pf_module = {
    PyModuleDef_HEAD_INIT, "pocketfft_fast._core", nullptr, -1, pf_methods};

PyMODINIT_FUNC PyInit__core(void) {
  import_array();
  return PyModule_Create(&pf_module);
}
