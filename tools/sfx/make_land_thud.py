"""Synthesizes assets/cinematics/impacts/land_thud.wav: a body landing hard
on packed earth. Made here, from nothing, so it carries no licence.

    python -I tools/sfx/make_land_thud.py

A falling sine (95 to 38 Hz) for the body's weight, a short low-passed noise
burst for the boots on grit, and a little scuff of high noise after it.
"""

import wave

import numpy as np

RATE = 44100
SECONDS = 0.55
OUT = "assets/cinematics/impacts/land_thud.wav"


def lowpass(x, cutoff):
    a = np.exp(-2 * np.pi * cutoff / RATE)
    y = np.empty_like(x)
    acc = 0.0
    for i, v in enumerate(x):
        acc = (1 - a) * v + a * acc
        y[i] = acc
    return y


def main():
    t = np.arange(int(RATE * SECONDS)) / RATE
    rng = np.random.default_rng(7)
    freq = 38 + 57 * np.exp(-t / 0.06)
    phase = 2 * np.pi * np.cumsum(freq) / RATE
    body = np.sin(phase) * np.exp(-t / 0.11) * np.minimum(t / 0.002, 1)
    grit = lowpass(rng.standard_normal(len(t)), 900) * np.exp(-t / 0.035) * 2.5
    scuff = lowpass(rng.standard_normal(len(t)), 3500) * np.exp(-np.maximum(t - 0.04, 0) / 0.08) * (t > 0.04) * 0.35
    out = body + grit + scuff
    out *= 0.9 / np.abs(out).max()
    with wave.open(OUT, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes((out * 32767).astype(np.int16).tobytes())
    print(OUT, len(t), "samples")


if __name__ == "__main__":
    main()
