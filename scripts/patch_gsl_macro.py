#!/usr/bin/env python3
"""patch_gsl_macro.py - in-place rewrite of the vendored Microsoft GSL
GSL_SUPPRESS macro to the string-literal [[gsl::suppress("x")]] form.

Used as the FetchContent PATCH_COMMAND for the gsl dependency in the
AutoCulling-Wheels onnxruntime build. Runs with cwd = the gsl source root
(FetchContent sets it before invoking the command). Byte-level replacement:
the macro definition lines contain no line-termination characters, so this
is immune to the CRLF line endings in the upstream zip that make
`patch --binary` fail with 'different line endings'.

MSVC 18 deprecates the non-string [[gsl::suppress(x)]] form (warning C4875),
which ORT's /WX escalates to an error. The string-literal form is the
officially recommended migration and is semantically identical.
"""
import sys
from pathlib import Path

OLD = b"#define GSL_SUPPRESS(x) [[gsl::suppress(x)]]"
NEW = b'#define GSL_SUPPRESS(x) [[gsl::suppress("x")]]'
FILES = ("include/gsl/assert", "include/gsl/byte", "include/gsl/gsl")

patched = 0
for rel in FILES:
    f = Path(rel)
    if not f.is_file():
        continue
    data = f.read_bytes()
    if OLD in data:
        f.write_bytes(data.replace(OLD, NEW))
        patched += 1
if patched == 0:
    print("gsl_suppress: no non-string GSL_SUPPRESS macro found (already patched or new upstream)")
else:
    print("gsl_suppress: rewrote the macro in %d file(s)" % patched)
