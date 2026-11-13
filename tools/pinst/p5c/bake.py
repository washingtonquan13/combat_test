"""Bake an SFZ's samples into .pinst5 notes with the C encoder (p5c.dll).

  python -I -B bake.py FILE.sfz OUT_ROOT [same options as ../p5/bake.py]

This is ../p5/bake.py (read it for the options, the manifest and the skipping)
with two things swapped: `encode` is this folder's encode.py, and the encoder
version in the manifest is a hash of p5c.dll, encode.py, the LZMA module the DLL
calls back into, contract.VERSION and the dial. A library baked by the Python
encoder therefore bakes again.
"""
from __future__ import annotations

import hashlib
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PINST = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(PINST, "p5"))
import bake  # noqa: E402  (puts p5 and tools/pinst on the path)

sys.path.insert(0, HERE)        # ahead of p5: `import encode` is the C encoder's, here and in the workers
import encode  # noqa: E402,F401


def encoder_version(dial: float) -> str:
    import contract
    h = hashlib.sha1(b"p5c")
    for p in (encode._lib._name, os.path.join(HERE, "encode.py"), os.path.join(PINST, "pinst_codec.py"),
              os.path.join(PINST, "fastlib.py")):
        h.update(os.path.basename(p).encode())
        h.update(open(p, "rb").read())
    h.update(f"|v{contract.VERSION}|dial{dial!r}".encode())
    return h.hexdigest()[:16]


bake.encoder_version = encoder_version

if __name__ == "__main__":
    bake.main()
