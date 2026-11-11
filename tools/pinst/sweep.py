"""Try several trial tiers on every note of a kind, one process per (note, tier).

  python -I tools/pinst/sweep.py OUT_DIR gtr|drum [NAME,NAME]

Edit TRIALS for the experiment at hand. Codec figures come from a finished
run_prototype OUT_DIR given as the sibling folder named pinst."""
import os, sys, json
for v in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS"): os.environ.setdefault(v, "1")
sys.path.insert(0, "tools/pinst")
import numpy as np, soundfile as sf
import run_prototype as rp, pinst_codec as pc
T = lambda name, **k: pc.Tier(name, f_cents=0.5, f_tol=1, **k)
TRIALS = [T("mid"), T("hybrid", pcm_ms=50), T("xf150_12", xf_ms=150, xf_snr=12),
          T("xf200_12", xf_ms=200, xf_snr=12),
          T("lf300", xf_ms=200, xf_snr=12, xf_lf_hz=300),
          T("lf300_9", xf_ms=200, xf_snr=9, xf_lf_hz=300, xf_lf_snr=12),
          T("lf600", xf_ms=200, xf_snr=12, xf_lf_hz=600),
          T("lf300_m512", xf_ms=200, xf_snr=12, xf_lf_hz=300, xf_lf_M=512),
          T("lf300_80ms", xf_ms=80, xf_snr=12, xf_lf_hz=300)]
def job(a):
    (name, path, kind, pitched, nm), tier, out = a
    x, sr = sf.read(path, always_2d=True)
    if kind == "gtr": x = x[500:]
    y, size, parts, info = rp.bake_stereo(x, pitched, rp.note_hz(nm) if nm else None, tier)
    os.makedirs(os.path.join(out, name), exist_ok=True)
    sf.write(os.path.join(out, name, tier.name + ".wav"), y, pc.SR, subtype="PCM_24")
    return name, tier.name, size, rp.score(x, y), parts
if __name__ == "__main__":
    from concurrent.futures import ProcessPoolExecutor
    out, kind = sys.argv[1], sys.argv[2]
    notes = [n for n in rp.NOTES if n[2] == kind and (len(sys.argv) < 4 or any(o in n[0] for o in sys.argv[3].split(",")))]
    with ProcessPoolExecutor(12) as ex:
        res = list(ex.map(job, [(n, t, out) for n in notes for t in TRIALS]))
    json.dump(res, open(os.path.join(out, f"sweep_{kind}.json"), "w"))
    ref = {r["name"]: r["codecs"] for r in json.load(open(sys.argv[1].replace("sweep", "pinst") + "/results.json"))}
    for n in notes:
        print(n[0])
        for nm, tn, size, sc, parts in res:
            if nm == n[0]: print(f"   {tn:9s} {size/1024:6.1f}K  mrstft {sc['mrstft_db']:4.1f}  mel {sc['mel_db']:5.2f}  xform {parts.get('xform',0)/1024:5.1f}K")
        for c, v in ref[n[0]].items(): print(f"   {c:9s} {v['bytes']/1024:6.1f}K  mrstft {v['mrstft_db']:4.1f}  mel {v['mel_db']:5.2f}")
