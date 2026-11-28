"""Synthesises the lockpicking screen's placeholder sounds into
assets/audio/lock/: small metal-on-metal ticks, a bind click, a strain
rattle, a snap and the open clunk. Placeholders until recorded foley
replaces them; run from the project root:  python tools/audio/make_lock_sounds.py
"""
import os
import wave

import numpy as np

RATE = 44100
OUT = os.path.join("assets", "audio", "lock")
rng = np.random.default_rng(7)


def t(seconds):
    return np.arange(int(RATE * seconds)) / RATE


def ring(freqs, seconds, decay, amps=None):
    """Sum of decaying partials: a struck bit of metal."""
    x = t(seconds)
    amps = amps or [1.0] * len(freqs)
    out = np.zeros_like(x)
    for f, a in zip(freqs, amps):
        out += a * np.sin(2 * np.pi * f * x + rng.uniform(0, 6.28)) * np.exp(-x * decay * (f / freqs[0]) ** 0.5)
    return out


def noise_burst(seconds, decay, colour=0.0):
    x = t(seconds)
    n = rng.standard_normal(len(x))
    if colour:
        # One-pole low-pass: higher colour = darker.
        y = np.zeros_like(n)
        for i in range(1, len(n)):
            y[i] = y[i - 1] * colour + n[i] * (1 - colour)
        n = y / (np.abs(y).max() + 1e-9)
    return n * np.exp(-x * decay)


def save(name, signal, peak=0.8, loop=False):
    signal = signal / (np.abs(signal).max() + 1e-9) * peak
    # 3 ms fade-in so no click at the start. A loop gets none: its start
    # follows its own end (the import loops it), and a fade would dip
    # once a cycle.
    if not loop:
        ramp = min(len(signal), int(RATE * 0.003))
        signal[:ramp] *= np.linspace(0, 1, ramp)
    data = (signal * 32767).astype(np.int16)
    os.makedirs(OUT, exist_ok=True)
    with wave.open(os.path.join(OUT, name), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(data.tobytes())
    print("wrote", name)


# The pick brushing a pin: a tiny bright tick.
save("pick_tick.wav", ring([5200, 7900, 11300], 0.05, 160, [1, 0.6, 0.3]) + 0.5 * noise_burst(0.05, 400), 0.35)
# The plug catching on a bound pin: a short, lower click.
save("bind.wav", ring([1900, 3400, 6100], 0.12, 60, [1, 0.5, 0.3]) + 0.7 * noise_burst(0.12, 250, 0.3), 0.6)
# The pick straining against the bind: a gritty rattle, looped. Every
# periodic part has a whole number of cycles in the second, so the end
# meets the start. The noise runs 50 ms long and that overhang is faded
# into its head, so the sample after the last one is the head's first.
x = t(1.0)
n = len(x)
fade = int(RATE * 0.05)
grit = noise_burst(1.0 + fade / RATE, 0.0, 0.6)
w = np.linspace(0, 1, fade)
grit[:fade] = grit[:fade] * w + grit[n:n + fade] * (1 - w)
grit = grit[:n]
chatter = (np.sin(2 * np.pi * 31 * x) > 0.6).astype(float)
rattle = grit * (0.35 + 0.65 * chatter) + 0.25 * np.sin(2 * np.pi * 2400 * x) * chatter
save("strain.wav", rattle, 0.4, loop=True)
# The pick snapping: a sharp crack and a ringing fragment.
save("snap.wav", 1.2 * noise_burst(0.35, 90) + ring([3100, 5300, 8800], 0.35, 22, [1, 0.7, 0.5]), 0.9)
# The plug turning home: a heavy clunk then a latch click.
clunk = ring([180, 420, 960], 0.45, 14, [1, 0.6, 0.3]) + 0.6 * noise_burst(0.45, 40, 0.8)
latch = np.concatenate([np.zeros(int(RATE * 0.09)), ring([2300, 4100], 0.36, 50)])
save("open.wav", clunk + 0.5 * latch[: len(clunk)], 0.9)
# Forcing failed: the plug grinds and jams.
grind = noise_burst(0.6, 6, 0.85) * (0.6 + 0.4 * np.sin(2 * np.pi * 13 * t(0.6)))
save("jam.wav", grind + 0.6 * ring([140, 330], 0.6, 9), 0.85)
