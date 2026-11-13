"""PINST5 bench: the only test run while building (AGENT_PLAN.md).

Encodes a fixed set of notes, decodes the bytes with the real decoder,
prints one line per note and a total.

  python -I -B bench.py [--jobs 4] [--dial 30] [--only substr] [--save run.json] [--base run.json]

Per note:
  kB, kbit/s   file size
  snr          waveform match, dB, worst of left/right (higher is closer)
  b10          band-frame SNR, 10th percentile: 24 ERB bands, 1024-sample frames,
               band-frames within 60 dB of the note's loudest
  peak         decoded peak / source peak
  pre          pre-echo, dB: in 1 ms blocks over the 20 ms before each hit (a block
               12 dB over the mean of the 8 before it, within 60 dB of the loudest),
               the most the decode sits over max(source, loudest - 60 dB). 0 = none.
  amp, amp250  guitar only, after tools/pinst/amp.py's amp and cab: whole-note SNR and
               the worst 250 ms window's SNR (windows within 60 dB of the loudest)
  enc, dec     seconds
With --base, each line also shows the change, and a note is marked WORSE when it
loses more than 0.5 dB of snr or b10, grows more than 3 %, or gains more than 1 dB
of pre-echo. Marked "!" when peak > 1.05 or pre > 1 dB on its own.
"""
from __future__ import annotations

import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
for _v in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS"):
    os.environ.setdefault(_v, "1")

import numpy as np  # noqa: E402

SRC = "C:/Godot Projects/sfpp_test/samples/"
BASS = "standard-bass/Ui_Standard_Bass_V2/Samples/"
DR = "sm-drums/Samples/SMDrum Stereo (Samples)/"
CY = "sm-drums/Samples/SMD Cymbals Stereo (Samples)/"
GTX = "metal-gtx/Samples/"
NOTES = [
    BASS + "Sus_Up/e2_Sus_Up2.wav",
    BASS + "Sus_Up/a3_Sus_Up1.wav",
    BASS + "Sus_Down/c3_Sus_Down1.wav",
    BASS + "Fret_Noise/Fret_Noise10.wav",
    BASS + "Mute_Finger_Down/f2_Mute_Finger_Down1.wav",
    BASS + "Harsh/d2_Harsh.wav",
    DR + "Kik_Stereo/RR2/01_Kik_Stereo_RR2.wav",
    DR + "SideStick_Stereo/RR6/27_SideStick_Stereo_RR6.wav",
    DR + "Toms_Stereo/Tom4/RR3/22_Tom4_Stereo_RR3.wav",
    DR + "SMD RimShot_Str_HyB1 (Samples)/RR1/03_RimShot_Str_HyB1_RR1.wav",
    CY + "Crash (Samples)/China Cymbal (Samples)/RR4/05_China_RR4.wav",
    CY + "Ride (Samples)/Ride 17 Bell (Samples)/RR1/02_Ride_Bell_17in_L_Tip_RR1.wav",
    CY + "Hi-Hat (Samples)/05 Hat, Foot/RR4/01_Hat_Foot_RR4.wav",
    "salamander.piano/Samples/A0v1.wav",
    "hamorg/SFZ/Data/Samples/Drawbar 1-01.wav",
    GTX + "Arpeggio/Group_A/Both/e2_Sustain.wav",
    GTX + "Mute_Down/e2_Mute_Down1.wav",
    GTX + "Arpeggio/Group_A/Both/b3_Sustain.wav",
    "(silent)",
]


def db(p):
    return 10 * np.log10(np.maximum(p, 1e-30))


def snr(x, y):
    return float(db((x**2).sum()) - db(((x - y) ** 2).sum()))


def erb_edges(nb=24, lo=30.0, hi=20000.0):
    e = lambda f: 21.4 * np.log10(1 + 0.00437 * f)
    ie = lambda v: (10 ** (v / 21.4) - 1) / 0.00437
    return ie(np.linspace(e(lo), e(hi), nb + 1))


def band_power(x, sr, N=1024, H=256):
    w = np.hanning(N + 1)[:-1]
    xp = np.concatenate([np.zeros(N // 2), x, np.zeros(N)])
    fr = np.lib.stride_tricks.sliding_window_view(xp, N)[::H]
    P = np.abs(np.fft.rfft(fr * w, axis=1)) ** 2
    k = np.clip(np.ceil(erb_edges() * N / sr).astype(int), 0, P.shape[1])
    return np.stack([P[:, a:max(b, a + 1)].sum(1) for a, b in zip(k[:-1], k[1:])], axis=1)


def band_p10(x, y, sr):
    Px, Pe = band_power(x, sr), band_power(x - y, sr)
    aud = Px > Px.max() * 1e-6
    return float(np.percentile(db(Px[aud]) - db(Pe[aud]), 10)) if aud.any() else 99.0


def pre_echo(x, y, sr):
    b = max(1, round(sr / 1000))
    m = len(x) // b
    if m < 30:
        return 0.0
    ps = (x[: m * b].reshape(m, b) ** 2).mean(1)
    pd = (y[: m * b].reshape(m, b) ** 2).mean(1)
    s, d = db(ps), db(pd)
    top = s.max()
    prev = np.convolve(np.concatenate([np.zeros(8), ps]), np.ones(8) / 8, mode="valid")[:m]
    hits = np.flatnonzero((s > db(prev) + 12) & (s > top - 60))
    worst = 0.0
    for h in hits:
        a = max(0, h - 20)
        if a < h:
            worst = max(worst, float((d[a:h] - np.maximum(s[a:h], top - 60)).max()))
    return worst


def amp_scores(x, y):
    import amp
    if not amp.CAB.startswith("C:"):
        amp.CAB = "C:/Godot Projects/sfpp_test/" + amp.CAB
    wx = amp.amp_cab(np.stack([x, x], 1))[:, 0]
    wy = amp.amp_cab(np.stack([y, y], 1))[:, 0]
    W = int(0.25 * amp.SR)
    m = len(wx) // W
    px = (wx[: m * W].reshape(m, W) ** 2).mean(1)
    pe = ((wx - wy)[: m * W].reshape(m, W) ** 2).mean(1)
    ok = db(px) > db(px.max()) - 60
    return snr(wx, wy), float((db(px[ok]) - db(pe[ok])).min()) if ok.any() else 99.0


def run_one(args):
    rel, dial = args
    sys.path.insert(0, os.path.dirname(HERE))
    import soundfile as sf
    import inventory
    import encode
    import decode
    if rel == "(silent)":
        x, sr = np.zeros((44100, 2)), 44100
    else:
        x, sr = sf.read(SRC + rel, always_2d=True)
    note = inventory.note_of(rel) if rel != "(silent)" else None
    f0 = None   # wave 1 (A): the name is hidden; analysis finds the pitch from the sound
    t0 = time.perf_counter()
    data = encode.encode_note(x, sr, f0, dial)
    t1 = time.perf_counter()
    y, sr2 = decode.decode(data)
    t2 = time.perf_counter()
    assert sr2 == sr and y.shape == x.shape, (y.shape, x.shape)
    live = [c for c in range(x.shape[1]) if np.any(x[:, c])]
    sec = len(x) / sr
    r = {"note": rel.split("/")[-1][:-4] if rel != "(silent)" else "silent", "bytes": len(data),
         "kbps": round(len(data) * 8 / sec / 1000, 1), "sec": round(sec, 2),
         "enc": round(t1 - t0, 2), "dec": round(t2 - t1, 2)}
    if live:
        r["snr"] = round(min(snr(x[:, c], y[:, c]) for c in live), 1)
        r["b10"] = round(min(band_p10(x[:, c], y[:, c], sr) for c in live), 1)
        r["peak"] = round(float(np.abs(y).max() / np.abs(x).max()), 3)
        r["pre"] = round(max(pre_echo(x[:, c], y[:, c], sr) for c in live), 1)
        if rel.startswith(GTX):
            a, a250 = amp_scores(x.mean(1), y.mean(1))
            r["amp"], r["amp250"] = round(a, 1), round(a250, 1)
    else:
        r["silent_out"] = bool(not np.any(y))
    return r


def line(r, b=None):
    s = f"{r['note'][:34]:34s} {r['bytes'] / 1000:8.1f} kB {r['kbps']:6.1f} kb/s"
    if "snr" in r:
        s += f"  snr {r['snr']:5.1f}  b10 {r['b10']:5.1f}  peak {r['peak']:.3f}  pre {r['pre']:4.1f}"
        if "amp" in r:
            s += f"  amp {r['amp']:5.1f} amp250 {r['amp250']:5.1f}"
    else:
        s += f"  silent out: {r['silent_out']}"
    s += f"  enc {r['enc']:5.2f}s dec {r['dec']:5.2f}s"
    flag = ""
    if r.get("peak", 1) > 1.05 or r.get("pre", 0) > 1.0 or r.get("silent_out") is False:
        flag = " !"
    if b:
        d = [f"{100 * (r['bytes'] / max(b['bytes'], 1) - 1):+.1f}%"]
        worse = r["bytes"] > b["bytes"] * 1.03 + 8
        for k in ("snr", "b10", "pre"):
            if k in r and k in b:
                d.append(f"{k} {r[k] - b[k]:+.1f}")
                worse |= (b[k] - r[k] > 0.5) if k != "pre" else (r[k] - b[k] > 1.0)
        s += "  | " + " ".join(d) + ("  WORSE" if worse else "")
    return s + flag


def main():
    import argparse
    from multiprocessing import Pool
    ap = argparse.ArgumentParser()
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--dial", type=float, default=None)
    ap.add_argument("--only", default=None)
    ap.add_argument("--save", default=None)
    ap.add_argument("--base", default=None)
    a = ap.parse_args()
    import contract
    dial = contract.DIAL if a.dial is None else a.dial
    notes = [n for n in NOTES if not a.only or a.only in n]
    t0 = time.perf_counter()
    with Pool(a.jobs) as p:
        res = p.map(run_one, [(n, dial) for n in notes], chunksize=1)
    wall = time.perf_counter() - t0
    base = {}
    if a.base:
        base = {r["note"]: r for r in json.load(open(a.base))["notes"]}
    for r in res:
        print(line(r, base.get(r["note"])))
    tb = sum(r["bytes"] for r in res)
    ts = sum(r["sec"] for r in res)
    te = sum(r["enc"] for r in res)
    td = sum(r["dec"] for r in res)
    tot = f"TOTAL {tb / 1000:.1f} kB over {ts:.1f} s ({tb * 8 / ts / 1000:.1f} kb/s)  enc {te:.1f} s  dec {td:.1f} s  wall {wall:.1f} s  dial {dial}"
    if a.base:
        bb = sum(b["bytes"] for b in base.values() if b["note"] in {r["note"] for r in res})
        tot += f"  | bytes {100 * (tb / max(bb, 1) - 1):+.1f}%"
    print(tot)
    if a.save:
        json.dump({"dial": dial, "notes": res}, open(a.save, "w"), indent=1)


if __name__ == "__main__":
    main()
