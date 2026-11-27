"""One-off: the hero's skeleton out of its baked MakeHuman .glb, the body gone.

    python -I tools/rig/strip_rig.py <proof_hero.glb> <humanoid_rig.glb>

The game's locomotion clips were baked on this skeleton (tools/locomotion/,
tools/kimodo/, tools/gait/), so the tools that bake them still need it. This
edits the glTF itself rather than round-tripping it through Blender, so every
joint's rest and inverse bind matrix is kept to the bit. The meshes,
materials and textures are dropped; one invisible triangle, skinned to the
hips, stays so importers still build a skeleton from the skin.
"""
import json, struct, sys

src, out = sys.argv[1], sys.argv[2]
data = open(src, "rb").read()
jlen = struct.unpack("<I", data[12:16])[0]
gl = json.loads(data[20:20 + jlen])
bin_off = 20 + jlen + 8
blob = data[bin_off:bin_off + struct.unpack("<I", data[20 + jlen:24 + jlen])[0]]

skin = gl["skins"][0]
ibm = gl["accessors"][skin["inverseBindMatrices"]]
view = gl["bufferViews"][ibm["bufferView"]]
start = view.get("byteOffset", 0) + ibm.get("byteOffset", 0)
ibm_bytes = blob[start:start + 64 * ibm["count"]]

names = [gl["nodes"][j]["name"] for j in skin["joints"]]
hips = names.index("Hips")
pos = struct.pack("<9f", 0, 0, 0, 0.001, 0, 0, 0, 0.001, 0)
joints = struct.pack("<12B", *([hips, 0, 0, 0] * 3))
weights = struct.pack("<12f", *([1, 0, 0, 0] * 3))
chunks = [ibm_bytes, pos, joints, weights]
views, offset, body = [], 0, b""
for c in chunks:
	views.append({"buffer": 0, "byteOffset": offset, "byteLength": len(c)})
	body += c
	pad = (-len(body)) % 4
	body += b"\0" * pad
	offset = len(body)
accessors = [
	{"bufferView": 0, "componentType": 5126, "count": ibm["count"], "type": "MAT4"},
	{"bufferView": 1, "componentType": 5126, "count": 3, "type": "VEC3",
	 "min": [0, 0, 0], "max": [0.001, 0.001, 0]},
	{"bufferView": 2, "componentType": 5121, "count": 3, "type": "VEC4"},
	{"bufferView": 3, "componentType": 5126, "count": 3, "type": "VEC4"},
]
skin["inverseBindMatrices"] = 0
skin["name"] = "Armature"

# Joints are nodes 0..64; the skinned meshes follow them, then the Armature.
mesh_nodes = [i for i, n in enumerate(gl["nodes"]) if "mesh" in n]
keep = mesh_nodes[0]
drop = set(mesh_nodes[1:])
remap, nodes = {}, []
for i, n in enumerate(gl["nodes"]):
	if i in drop:
		continue
	remap[i] = len(nodes)
	nodes.append(n)
for n in nodes:
	if "children" in n:
		n["children"] = [remap[c] for c in n["children"] if c not in drop]
	if "mesh" in n:
		n["mesh"] = 0
		n["name"] = "rig_anchor"
for s in gl["scenes"]:
	s["nodes"] = [remap[c] for c in s["nodes"]]
skin["joints"] = [remap[j] for j in skin["joints"]]
if "skeleton" in skin:
	skin["skeleton"] = remap[skin["skeleton"]]

gl["nodes"] = nodes
gl["meshes"] = [{"name": "rig_anchor", "primitives": [{"attributes": {
	"POSITION": 1, "JOINTS_0": 2, "WEIGHTS_0": 3}}]}]
gl["accessors"] = accessors
gl["bufferViews"] = views
gl["buffers"] = [{"byteLength": len(body)}]
for k in ("materials", "textures", "images", "samplers", "animations"):
	gl.pop(k, None)
gl["asset"]["generator"] = "tools/rig/strip_rig.py from " + gl["asset"].get("generator", "")

js = json.dumps(gl, separators=(",", ":")).encode()
js += b" " * ((-len(js)) % 4)
glb = struct.pack("<4sII", b"glTF", 2, 12 + 8 + len(js) + 8 + len(body))
glb += struct.pack("<I4s", len(js), b"JSON") + js + struct.pack("<I4s", len(body), b"BIN\0") + body
open(out, "wb").write(glb)
print("wrote", out, len(glb), "bytes,", len(skin["joints"]), "joints")
