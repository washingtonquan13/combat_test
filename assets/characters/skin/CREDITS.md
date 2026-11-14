# Credits

## mpfb_face_detail.png

Baked by `tools/characters/bake_scan_detail.py` from:

**"Infinite, 3D Head Scan" by Lee Perry-Smith**, licensed under
[Creative Commons Attribution 3.0 Unported](https://creativecommons.org/licenses/by/3.0/).
Based on a work at www.triplegangers.com. Permissions beyond the scope of
this license may be available at http://www.ir-ltd.net/.

The copy used was the one in three.js's examples
(`examples/models/gltf/LeePerrySmith/`). Changes: the scan's displacement map
was baked as a normal map onto the MakeHuman/MPFB head's UV layout, with its
low frequencies removed and the eyes, ears, lips and nostrils masked out.

This credit must appear in the game's credits when it ships.

## Face parts: tools/characters/parts/lee/

MakeHuman targets cut by `tools/characters/bake_scan_parts.py` from the same
scan (**"Infinite, 3D Head Scan" by Lee Perry-Smith**, CC BY 3.0, as above).
Changes: the scan was fitted to an MPFB head and its difference from it cut,
with soft edges, into nose, mouth, chin, cheeks, brow, ears and skull; the
eyes and lids are MPFB's. Characters whose recipe uses these parts
(`"parts"` in `tools/characters/recipes/*.json`, proof_hero among them) carry
the scan's shapes, so this credit covers them too.
