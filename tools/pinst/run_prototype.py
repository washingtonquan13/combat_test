"""Bake ~24 test notes at several tiers, rebuild them, measure bytes and
distance against reference codecs, and write listening material.

  python -I tools/pinst/run_prototype.py OUT_DIR [--only A,B] [--tiers mid,hybrid] [--no-amp] [--no-reels]

Notes bake in parallel. The original's amp render and codec round trips are
cached in each note's folder; delete OUT_DIR to redo them.

Run from the project root. Writes OUT_DIR/report.md, OUT_DIR/results.json,
per-note WAVs and MP3 reels for listening."""
from __future__ import annotations

import os

# one thread per worker: the notes run in parallel, and BLAS threads on top
# of that made every note three times slower
for _v in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS"):
    os.environ.setdefault(_v, "1")

import json
import os
import re
import subprocess
import sys
import tempfile
import time

import numpy as np
import soundfile as sf

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pinst_codec as pc  # noqa: E402
import metrics  # noqa: E402
import amp  # noqa: E402

FF = os.path.expanduser(
    r"~\AppData\Local\Programs\Python\Python312\Lib\site-packages\imageio_ffmpeg\binaries\ffmpeg-win-x86_64-v7.1.exe")
G = "samples/metal-gtx/Samples/"
D = "samples/sm-drums/Samples/SMDrum Stereo (Samples)/"
C = "samples/sm-drums/Samples/SMD Cymbals Stereo (Samples)/"

# name, path, kind ('gtr' gets offset=500 and the amp), pitched, note
NOTES = [
    ("gtr_e2_sus_rr1", G + "Sus_Down/e2_Sus_Down1.wav", "gtr", True, "e2"),
    ("gtr_e2_sus_rr2", G + "Sus_Down/e2_Sus_Down2.wav", "gtr", True, "e2"),
    ("gtr_a2_sus", G + "Sus_Down/a2_Sus_Down1.wav", "gtr", True, "a2"),
    ("gtr_d3_sus", G + "Sus_Down/d3_Sus_Down1.wav", "gtr", True, "d3"),
    ("gtr_g3_sus", G + "Sus_Down/g3_Sus_Down1.wav", "gtr", True, "g3"),
    ("gtr_e4_sus", G + "Sus_Down/e4_Sus_Down1.wav", "gtr", True, "e4"),
    ("gtr_e5_sus", G + "Sus_Down/e5_Sus_Down1.wav", "gtr", True, "e5"),
    ("gtr_e2_upstroke", G + "Sus_Up/e2_Sus_Up1.wav", "gtr", True, "e2"),
    ("gtr_e2_mute", G + "Mute_Down/e2_Mute_Down1.wav", "gtr", True, "e2"),
    ("gtr_a2_mute", G + "Mute_Down/a2_Mute_Down1.wav", "gtr", True, "a2"),
    ("gtr_a2_release", G + "Release4/a2_Rel4_1.wav", "gtr", True, "a2"),
    ("kick_v32_rr1", D + "Kik_Stereo/RR1/32_Kik_Stereo_RR1.wav", "drum", False, None),
    ("kick_v32_rr2", D + "Kik_Stereo/RR2/32_Kik_Stereo_RR2.wav", "drum", False, None),
    ("kick_v16", D + "Kik_Stereo/RR1/16_Kik_Stereo_RR1.wav", "drum", False, None),
    ("snare_v34_rr1", D + "Snare65_Reg_Stereo/RR1/34_Snare65_Reg_Stereo_RR1.wav", "drum", False, None),
    ("snare_v34_rr2", D + "Snare65_Reg_Stereo/RR2/34_Snare65_Reg_Stereo_RR2.wav", "drum", False, None),
    ("snare_v17", D + "Snare65_Reg_Stereo/RR1/17_Snare65_Reg_Stereo_RR1.wav", "drum", False, None),
    ("tom2_v30", D + "Toms_Stereo/Tom2/RR1/30_Tom2_Stereo_RR1.wav", "drum", False, None),
    ("hat_tight_v40", C + "Hi-Hat (Samples)/01 Hat Tight 1/RR1/40_Hat_Tight_Cnt_RR1.wav", "drum", False, None),
    ("hat_tight_v20", C + "Hi-Hat (Samples)/01 Hat Tight 1/RR1/20_Hat_Tight_Cnt_RR1.wav", "drum", False, None),
    ("hat_open_v14", C + "Hi-Hat (Samples)/03 Hat, Open/RR1/14_Hat_Open_RR1.wav", "drum", False, None),
    ("crash15_v22", C + "Crash (Samples)/Crash 15 (Samples)/RR1/22_Crash_15in_L_edge_RR1.wav", "drum", False, None),
    ("ride17_v1", C + "Ride (Samples)/Ride 17 (Samples)/RR1/01_Ride_17in_L_Cnt_Tip_RR1.wav", "drum", False, None),
]

AUTO_GAIN_DB = 1.0    # spectral dB (or half that in mel dB) the body layers must buy to be chosen
TIERS = [
    pc.Tier("fine", f_cents=0.5, f_tol=0.5, a_db=0.5, a_tol=0.5, cull_db=-80, noise_q=1.0, noise_tol=1.0),
    pc.Tier("mid", f_cents=0.5, f_tol=1),
    pc.Tier("lean", f_cents=0.5, f_tol=2, a_tol=1.5, cull_db=-60, noise_q=2.0, noise_tol=2.5, noise_bands=28),
    pc.Tier("hybrid", f_cents=0.5, f_tol=1, pcm_ms=50),
    pc.Tier("attack", f_cents=0.5, f_tol=1, xf_ms=200, xf_snr=12),
    pc.Tier("body", f_cents=0.5, f_tol=1, xf_ms=200, xf_snr=12, xf_lf_hz=300),
]

CODECS = [
    ("vorbis_q0", ["-c:a", "libvorbis", "-q:a", "0"], "ogg"),
    ("vorbis_q4", ["-c:a", "libvorbis", "-q:a", "4"], "ogg"),
    ("opus_48k", ["-c:a", "libopus", "-b:a", "48k"], "opus"),
    ("opus_96k", ["-c:a", "libopus", "-b:a", "96k"], "opus"),
]

NAMES = {"c": 0, "d": 2, "e": 4, "f": 5, "g": 7, "a": 9, "b": 11}


def note_hz(nm):
    m = re.fullmatch(r"([a-g])(#?)(-?\d)", nm)
    midi = 12 * (int(m.group(3)) + 1) + NAMES[m.group(1)] + (1 if m.group(2) else 0)
    return 440 * 2 ** ((midi - 69) / 12)


def codec_roundtrip(x, args, ext):
    with tempfile.TemporaryDirectory() as td:
        src, enc, dec = (os.path.join(td, f) for f in ("a.wav", "b." + ext, "c.wav"))
        sf.write(src, x, pc.SR, subtype="PCM_24")
        subprocess.run([FF, "-y", "-loglevel", "error", "-i", src, *args, enc], check=True)
        subprocess.run([FF, "-y", "-loglevel", "error", "-i", enc, "-ar", str(pc.SR), dec], check=True)
        y, _ = sf.read(dec, always_2d=True)
        size = os.path.getsize(enc)
    y = y[: len(x)]
    return np.pad(y, ((0, len(x) - len(y)), (0, 0))), size


def bake_stereo(x, pitched, f0, tier):
    M = 0.5 * (x[:, 0] + x[:, 1])
    S = 0.5 * (x[:, 0] - x[:, 1])
    out, total, parts = [], 0, {}
    side_db = 20 * np.log10(np.sqrt((S**2).mean()) / max(np.sqrt((M**2).mean()), 1e-12) + 1e-12)
    info = {"side_db": float(side_db)}
    for label, sig in (("mid", M), ("side", S)):
        if label == "side" and side_db < -40:
            out.append(np.zeros_like(S))
            info["side"] = "dropped"
            continue
        ch, dec, sizes = pc.compile_channel(sig, pitched, f0, tier)
        y = pc.render(dec, tier)
        out.append(y)
        total += sum(sizes.values())
        for k, v in sizes.items():
            parts[k] = parts.get(k, 0) + v
        info[label] = {**ch.info, "tracks_kept": dec.info["n_tracks"], "keys": dec.info["n_keys"]}
    M2, S2 = out
    return np.stack([M2 + S2, M2 - S2], axis=1), total, parts, info


def mono(x):
    return x.mean(axis=1)


def score(ref, y, cache=None):
    """cache: a dict the caller keeps per original, when it scores several rebuilds of it."""
    r = cache.setdefault("mono", mono(ref)) if cache is not None else mono(ref)
    return {"mrstft_db": round(metrics.mrstft_db(r, mono(y), cache=cache), 2),
            "mel_db": round(metrics.mel_db(r, mono(y), cache=cache), 2)}


def write_mp3(path, x):
    with tempfile.TemporaryDirectory() as td:
        w = os.path.join(td, "r.wav")
        sf.write(w, np.clip(x, -1, 1), pc.SR, subtype="PCM_16")
        subprocess.run([FF, "-y", "-loglevel", "error", "-i", w, "-c:a", "libmp3lame", "-b:a", "192k", path], check=True)


def do_note(job):
    """One note, start to finish, in a worker. The original's side (amp
    reference, codec round trips) is cached in the note's folder, since it
    never changes between iterations."""
    (name, path, kind, pitched, nm), out_dir, tier_names, do_amp = job
    t0 = time.time()
    x, sr = sf.read(path, always_2d=True)
    assert sr == pc.SR, path
    if kind == "gtr":
        x = x[500:]          # the program's offset=500
    f0 = note_hz(nm) if nm else None
    nd = os.path.join(out_dir, name)
    os.makedirs(nd, exist_ok=True)
    amped = do_amp and kind == "gtr"
    ref_json = os.path.join(nd, "ref.json")
    amp_ref = None
    if os.path.exists(ref_json) and (not amped or os.path.exists(os.path.join(nd, "amp_orig.wav"))):
        codecs = json.load(open(ref_json))
        if amped:
            amp_ref, _ = sf.read(os.path.join(nd, "amp_orig.wav"), always_2d=True)
            if any("amp" not in v for v in codecs.values()):
                codecs = None
    else:
        codecs = None
    if codecs is None:
        sf.write(os.path.join(nd, "orig.wav"), x, pc.SR, subtype="PCM_24")
        if amped:
            amp_ref = amp.amp_cab(x)
            sf.write(os.path.join(nd, "amp_orig.wav"), amp_ref, pc.SR, subtype="PCM_24")
        codecs = {}
        for cname, args, ext in CODECS:
            y, size = codec_roundtrip(x, args, ext)
            sf.write(os.path.join(nd, f"{cname}.wav"), y, pc.SR, subtype="PCM_24")
            codecs[cname] = {"bytes": size, **score(x, y)}
            if amped:
                codecs[cname]["amp"] = score(amp_ref, amp.amp_cab(y))
        json.dump(codecs, open(ref_json, "w"))
    row = {"name": name, "kind": kind, "seconds": round(len(x) / pc.SR, 2),
           "pcm24_bytes": x.shape[0] * x.shape[1] * 3, "tiers": {}, "codecs": codecs}
    for tier in TIERS:
        if tier_names and tier.name not in tier_names:
            continue
        y, size, parts, info = bake_stereo(x, pitched, f0, tier)
        sf.write(os.path.join(nd, f"{tier.name}.wav"), y, pc.SR, subtype="PCM_24")
        r = {"bytes": size, "parts": parts, **score(x, y), "info": info}
        if amped:
            ya = amp.amp_cab(y)
            sf.write(os.path.join(nd, f"amp_{tier.name}.wav"), ya, pc.SR, subtype="PCM_24")
            r["amp"] = score(amp_ref, ya)
        row["tiers"][tier.name] = r
    t = row["tiers"]
    if "mid" in t and "body" in t:
        # per-note choice: the residual layers only where they buy a clear step
        # (judged through the amp for guitar, since that is how it is heard)
        f = lambda v: v.get("amp", v)
        gain = max(f(t["mid"])["mrstft_db"] - f(t["body"])["mrstft_db"],
                   2 * (f(t["mid"])["mel_db"] - f(t["body"])["mel_db"]))
        pick = "body" if gain >= AUTO_GAIN_DB else "mid"
        t["auto"] = {**t[pick], "picked": pick}
    row["secs_to_bake"] = round(time.time() - t0, 1)
    return row


def main():
    from concurrent.futures import ProcessPoolExecutor
    out_dir = sys.argv[1]
    arg = lambda k: sys.argv[sys.argv.index(k) + 1] if k in sys.argv else None
    only, tier_names = arg("--only"), (arg("--tiers") or "").split(",") if arg("--tiers") else None
    do_amp = "--no-amp" not in sys.argv
    os.makedirs(out_dir, exist_ok=True)
    jobs = [(n, out_dir, tier_names, do_amp) for n in NOTES if not only or any(o in n[0] for o in only.split(","))]
    t0 = time.time()
    with ProcessPoolExecutor(max(1, min(len(jobs), int(arg("--jobs") or (os.cpu_count() or 4) - 2)))) as ex:
        results = list(ex.map(do_note, jobs))
    for row in results:
        t = row["tiers"]
        if any("amp" in v for v in t.values()):
            print("   amp: " + "  ".join(f"{k}={v['amp']['mrstft_db']:4.1f}/{v['amp']['mel_db']:4.1f}" for k, v in
                                       list(t.items()) + list(row["codecs"].items())))
        print(f"{row['name']:20s} {row['seconds']:5.2f}s  " + "  ".join(
            f"{k}={v['bytes']/1024:6.1f}K/{v['mrstft_db']:4.1f}dB" for k, v in t.items()) + "  |  " + "  ".join(
            f"{k}={v['bytes']/1024:5.1f}K/{v['mrstft_db']:4.1f}dB" for k, v in row["codecs"].items()), flush=True)
    with open(os.path.join(out_dir, "results.json"), "w") as f:
        json.dump(results, f, indent=1)
    if "--no-reels" not in sys.argv:
        gap = lambda s: np.zeros((int(s * pc.SR), 2))
        rd = lambda n, f: sf.read(os.path.join(out_dir, n, f), always_2d=True)[0]
        for tn in (results[0]["tiers"] if results else []):
            for pre in ("", "amp_"):
                parts = []
                for row in results:
                    if os.path.exists(os.path.join(out_dir, row["name"], f"{pre}{tn}.wav")):
                        parts += [rd(row["name"], pre + "orig.wav"), gap(0.4), rd(row["name"], f"{pre}{tn}.wav"), gap(1.0)]
                if parts:
                    write_mp3(os.path.join(out_dir, f"reel_{pre}{tn}.mp3"), np.concatenate(parts))
    print(f"total {time.time() - t0:.0f}s")


if __name__ == "__main__":
    main()
