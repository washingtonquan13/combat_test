"""Packs a height map into a Poly Haven ARM texture's unused metallic channel.

Poly Haven ships displacement separately and the quarry only downloaded
diffuse, normal and ARM. Height is recovered from the normal map instead:
its slopes are integrated over the whole tile in frequency space
(Frankot-Chellappa), which is exact for a tiling texture because the FFT
already treats the image as periodic.

    python -I tools/quarry/height_from_normal.py <name_nor_gl_2k.jpg> ...

Writes <name>_armh_2k.png beside each normal map: R ambient occlusion,
G roughness, B height (0 low, 1 high).
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image


def height(normal: np.ndarray) -> np.ndarray:
    n = normal.astype(np.float64) / 255.0 * 2.0 - 1.0
    nz = np.maximum(n[..., 2], 0.15)
    # OpenGL normal map: green points up the image, rows run down it.
    p = -n[..., 0] / nz
    q = n[..., 1] / nz
    h, w = p.shape
    u = np.fft.fftfreq(w)[None, :]
    v = np.fft.fftfreq(h)[:, None]
    P = np.fft.fft2(p)
    Q = np.fft.fft2(q)
    denom = (2j * np.pi) * (u * u + v * v)
    denom[0, 0] = 1.0
    Z = (u * P + v * Q) / denom
    Z[0, 0] = 0.0
    z = np.real(np.fft.ifft2(Z))
    # Integration leaves a long-wave drift the normal map can't pin down;
    # what matters for blending is the local relief, so take it out.
    lo = np.real(np.fft.ifft2(np.fft.fft2(z) * np.exp(-((u * u + v * v) * (w / 6.0) ** 2))))
    z = z - lo
    a, b = np.percentile(z, [1.0, 99.0])
    return np.clip((z - a) / max(b - a, 1e-9), 0.0, 1.0)


def main() -> None:
    for arg in sys.argv[1:]:
        nor = Path(arg)
        stem = nor.name.replace("_nor_gl_2k.jpg", "")
        arm = nor.with_name(stem + "_arm_2k.jpg")
        out = nor.with_name(stem + "_armh_2k.png")
        hgt = height(np.asarray(Image.open(nor).convert("RGB")))
        rgb = np.asarray(Image.open(arm).convert("RGB")).copy()
        rgb[..., 2] = np.round(hgt * 255.0).astype(np.uint8)
        Image.fromarray(rgb).save(out, optimize=True)
        print(f"{out.name}: height mean {hgt.mean():.2f}")


if __name__ == "__main__":
    main()
