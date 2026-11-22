"""Meshy text-to-3D: preview then PBR refine; downloads GLB + thumbnail into an output folder.
Key from MESHY_API_KEY (never printed).  python -I meshy_gen.py OUTDIR "prompt" [pose]"""
import json, os, sys, time, urllib.request

KEY = os.environ["MESHY_API_KEY"]
API = "https://api.meshy.ai/openapi/v2/text-to-3d"
out, prompt = sys.argv[1], sys.argv[2]
pose = sys.argv[3] if len(sys.argv) > 3 else ""
os.makedirs(out, exist_ok=True)


def call(url, body=None):
    req = urllib.request.Request(url, data=json.dumps(body).encode() if body else None,
                                 headers={"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"},
                                 method="POST" if body else "GET")
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read())


def wait(tid, label):
    while True:
        t = call(f"{API}/{tid}")
        print(label, t["status"], t.get("progress"), flush=True)
        if t["status"] == "SUCCEEDED":
            return t
        if t["status"] in ("FAILED", "CANCELED", "EXPIRED"):
            sys.exit(f"{label} {t['status']}: {t.get('task_error')}")
        time.sleep(10)


body = {"mode": "preview", "prompt": prompt, "art_style": "realistic", "should_remesh": True,
        "topology": "quad", "target_polycount": 30000}
if pose:
    body["pose_mode"] = pose
pid = call(API, body)["result"]
print("preview task", pid, flush=True)
wait(pid, "preview")
rid = call(API, {"mode": "refine", "preview_task_id": pid, "enable_pbr": True})["result"]
print("refine task", rid, flush=True)
t = wait(rid, "refine")
json.dump(t, open(os.path.join(out, "task.json"), "w"), indent=1)
for k, name in (("glb", "model.glb"),):
    urllib.request.urlretrieve(t["model_urls"][k], os.path.join(out, name))
if t.get("thumbnail_url"):
    urllib.request.urlretrieve(t["thumbnail_url"], os.path.join(out, "thumb.png"))
print("DONE", out, flush=True)
