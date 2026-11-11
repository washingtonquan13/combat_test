"""Bake ~24 test notes at several tiers, rebuild them, measure bytes and
distance against reference codecs, and write listening material.

  python -I tools/pinst/run_prototype.py OUT_DIR [--only NAME] [--no-amp]

Run from the project root. Writes OUT_DIR/report.md, OUT_DIR/results.json,
per-note WAVs and MP3 reels for listening."""
from __future__ import annotations

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

TIERS = [
    pc.Tier("fine", f_cents=0.5, f_tol=0.5, a_db=0.5, a_tol=0.5, cull_db=-80, noise_q=1.0, noise_tol=1.0),
    pc.Tier("mid", f_cents=0.5, f_tol=1),
    pc.Tier("lean", f_cents=0.5, f_tol=2, a_tol=1.5, cull_db=-60, noise_q=2.0, noise_tol=2.5, noise_bands=28),
    pc.Tier("hybrid", f_cents=0.5, f_tol=1, pcm_ms=50),
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


def score(ref, y):
    return {"mrstft_db": round(metrics.mrstft_db(mono(ref), mono(y)), 2),
            "mel_db": round(metrics.mel_db(mono(ref), mono(y)), 2)}


def write_mp3(path, x):
    with tempfile.TemporaryDirectory() as td:
        w = os.path.join(td, "r.wav")
        sf.write(w, np.clip(x, -1, 1), pc.SR, subtype="PCM_16")
        subprocess.run([FF, "-y", "-loglevel", "error", "-i", w, "-c:a", "libmp3lame", "-b:a", "192k", path], check=True)


def main():
    out_dir = sys.argv[1]
    only = sys.argv[sys.argv.index("--only") + 1] if "--only" in sys.argv else None
    do_amp = "--no-amp" not in sys.argv
    os.makedirs(out_dir, exist_ok=True)
    results = []
    reels = {}   # key -> list of arrays
    gap = lambda s: np.zeros((int(s * pc.SR), 2))
    for name, path, kind, pitched, nm in NOTES:
        if only and only not in name:
            continue
        t0 = time.time()
        x, sr = sf.read(path, always_2d=True)
        assert sr == pc.SR, path
        if kind == "gtr":
            x = x[500:]          # the program's offset=500
        f0 = note_hz(nm) if nm else None
        nd = os.path.join(out_dir, name)
        os.makedirs(nd, exist_ok=True)
        sf.write(os.path.join(nd, "orig.wav"), x, pc.SR, subtype="PCM_24")
        pcm_bytes = x.shape[0] * x.shape[1] * 3
        row = {"name": name, "kind": kind, "seconds": round(len(x) / pc.SR, 2), "pcm24_bytes": pcm_bytes,
               "tiers": {}, "codecs": {}}
        amp_ref = amp.amp_cab(x) if (do_amp and kind == "gtr") else None
        if amp_ref is not None:
            sf.write(os.path.join(nd, "amp_orig.wav"), amp_ref, pc.SR, subtype="PCM_24")
        for tier in TIERS:
            y, size, parts, info = bake_stereo(x, pitched, f0, tier)
            sf.write(os.path.join(nd, f"{tier.name}.wav"), y, pc.SR, subtype="PCM_24")
            r = {"bytes": size, "parts": parts, **score(x, y), "info": info}
            if amp_ref is not None:
                ya = amp.amp_cab(y)
                sf.write(os.path.join(nd, f"amp_{tier.name}.wav"), ya, pc.SR, subtype="PCM_24")
                r["amp"] = score(amp_ref, ya)
                reels.setdefault("amp_" + tier.name, []).extend([amp_ref, gap(0.4), ya, gap(1.0)])
            reels.setdefault(tier.name, []).extend([x, gap(0.4), y, gap(1.0)])
            row["tiers"][tier.name] = r
        for cname, args, ext in CODECS:
            y, size = codec_roundtrip(x, args, ext)
            sf.write(os.path.join(nd, f"{cname}.wav"), y, pc.SR, subtype="PCM_24")
            row["codecs"][cname] = {"bytes": size, **score(x, y)}
            if amp_ref is not None:
                row["codecs"][cname]["amp"] = score(amp_ref, amp.amp_cab(y))
        row["secs_to_bake"] = round(time.time() - t0, 1)
        results.append(row)
        t = row["tiers"]
        if amp_ref is not None:
            print("   amp: " + "  ".join(f"{k}={v['amp']['mrstft_db']:4.1f}/{v['amp']['mel_db']:4.1f}" for k, v in
                                       list(t.items()) + list(row["codecs"].items())))
        print(f"{name:20s} {row['seconds']:5.2f}s  " + "  ".join(
            f"{k}={v['bytes']/1024:6.1f}K/{v['mrstft_db']:4.1f}dB" for k, v in t.items()) + "  |  " + "  ".join(
            f"{k}={v['bytes']/1024:5.1f}K/{v['mrstft_db']:4.1f}dB" for k, v in row["codecs"].items()), flush=True)
    with open(os.path.join(out_dir, "results.json"), "w") as f:
        json.dump(results, f, indent=1)
    for key, parts in reels.items():
        write_mp3(os.path.join(out_dir, f"reel_{key}.mp3"), np.concatenate(parts))


if __name__ == "__main__":
    main()
