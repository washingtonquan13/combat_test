"""Block player for .pinst notes: the algorithm a real-time voice runs.

A Voice is built from file bytes and hands out audio a block at a time, at
the note's own pitch; any block sizes give the same samples. Everything
random comes from an integer hash of (seed, counter), so another
implementation can reproduce it exactly.

Differences from the offline render in pinst_codec:
  noise   each 1024-sample frame is its own random spectrum, shaped by the
          band levels, sine-windowed and overlap-added (hop 512)
  refill  transform layers take their fill noise from the hash
The partials and the coded coefficients are the same.

  python -I tools/pinst/pinst_stream.py OUT_DIR    compare with the offline render
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pinst_codec as pc  # noqa: E402
import pinst_file as pf  # noqa: E402

G = 1024            # samples made per internal step
NN = pc.NOISE_N
NH = NN // 2


def hash_uniform(seed: int, start: int, count: int) -> np.ndarray:
    """count values in [-1, 1), from counters start..start+count-1."""
    x = (np.arange(start, start + count, dtype=np.uint64) * 0x9E3779B9 + seed) & 0xFFFFFFFF
    x ^= x >> 16
    x = (x * 0x85EBCA6B) & 0xFFFFFFFF
    x ^= x >> 13
    x = (x * 0xC2B2AE35) & 0xFFFFFFFF
    x ^= x >> 16
    return x.astype(np.float64) / 2147483648.0 - 1.0


_SQ3 = np.sqrt(3.0)
_NWIN = np.sin(np.pi * (np.arange(NN) + 0.5) / NN)
_NREF = {}


def noise_frame(seed, i, gain):
    """Frame i of shaped noise: NN samples, to be overlap-added at i * NH."""
    u = hash_uniform(seed, i * (NN + 2), NN + 2) * _SQ3
    return np.fft.irfft((u[0::2] + 1j * u[1::2]) * gain, NN) * _NWIN


def noise_ref_db(edges):
    """Band levels of this generator at unit gain, as the analysis measures them."""
    key = (pc.SR, len(edges))
    if key not in _NREF:
        F = 4 * pc.SR // NH
        y = np.zeros((F + 1) * NH)
        one = np.ones(NH + 1)
        for i in range(F):
            y[i * NH : i * NH + NN] += noise_frame(1, i, one)
        _NREF[key] = pc._band_db(y, NH, edges)[8:-8].mean(axis=0)
    return _NREF[key]


class Layer:
    """One transform layer, decoded a frame at a time."""

    def __init__(self, sc, q, n, M, K, nbands, snr, noise_hz, dead, seed, grid3=False):
        self.q, self.n, self.M, self.K, self.seed = q, n, M, K, seed
        B, self.w = pc._mdct(M)
        self.w0 = pc.layer_windows(M)[0] if grid3 else self.w
        self.B = B[:, :K]
        self.edges = pc._xf_edges(K, nbands)
        self.wid = np.diff(self.edges)
        live = sc != dead
        self.rms = 10 ** (sc * 1.5 / 20) * live
        self.step = np.maximum(self.rms, 1e-30) * 10 ** (-snr / 20) * np.sqrt(12)
        noisy = (self.edges[:-1] * pc.SR / (2 * M) >= noise_hz) if noise_hz > 0 else np.zeros(len(self.wid), bool)
        self.coded = live & ~noisy[None, :]
        self.tail = np.zeros(M)
        self.f = 0          # next frame; frame f covers samples (f-1)*M .. (f+1)*M
        # PINST3 (pc.layer_windows): frame f covers f*M - M/2 .. f*M + 3M/2,
        # so the note starts half way into the first hop
        self.pending = self.hop()[M // 2 :] if grid3 else np.zeros(0)

    def take(self, n):
        """The next n samples (PINST3 grid)."""
        while len(self.pending) < n:
            self.pending = np.concatenate([self.pending, self.hop()])
        out, self.pending = self.pending[:n], self.pending[n:]
        return out

    def hop(self):
        """The next M samples."""
        f, M = self.f, self.M
        self.f += 1
        if f >= len(self.q):
            out, self.tail = self.tail, np.zeros(M)
            return out
        q, e, wid = self.q[f], self.edges[:-1], self.wid
        step = np.repeat(self.step[f], wid)
        X = q * step
        lack = np.maximum(self.rms[f] ** 2 * wid - np.add.reduceat(X**2, e), 0)
        nz = np.add.reduceat((q == 0).astype(float), e)
        fill = np.repeat(np.sqrt(lack / np.maximum(nz, 1)), wid)
        fill = np.where(np.repeat(self.coded[f], wid), np.minimum(fill, step / np.sqrt(12)), fill)
        X = X + (q == 0) * fill * hash_uniform(self.seed, f * self.K, self.K) * _SQ3
        y = (self.B @ X) * (self.w0 if f == 0 else self.w) * (2 / M)
        out = self.tail + y[:M]
        self.tail = y[M:]
        return out


class ChannelVoice:
    def __init__(self, blob, seed, packed=True, v3=False):
        self.v3 = v3
        if v3:
            ch, tier, lay = pf.unpack3_channel(blob, packed, decode_layers=False)
            seed = ch.seed
        else:
            ch, tier, lay = pf.unpack_channel(blob, decode_layers=False, packed=packed)
        self.ch, self.n, self.H, self.pos = ch, ch.n, ch.H, 0
        self.seed = seed
        edges = pc.erb_edges(tier.noise_bands)
        centres = np.sqrt(edges[:-1] * edges[1:])
        f = np.fft.rfftfreq(NN, 1 / pc.SR)
        g_db = ch.noise_db - noise_ref_db(edges)[None, :]
        self.ngain = np.array([10 ** (np.interp(f, centres, r) / 20) for r in g_db])
        self.ntail = np.zeros(NH)
        self.nf = 0
        if v3:
            # noise frame i is centred on sample i * NH: the first half frame
            # falls before the note
            self._noise_hop()
            self.layers = [Layer(sc, q, n, M, K, b, s, 0.0, d, sd, grid3=True)
                           for sc, q, n, M, K, b, s, d, sd in lay]
        else:
            self.layers = [Layer(*a, seed=seed + 1 + i) for i, a in enumerate(lay)]
            for L in self.layers:
                L.hop()         # the half frame before sample 0
        self.xn = lay[0][2] if lay else 0
        self.order = sorted(range(len(ch.tracks)), key=lambda i: ch.tracks[i].start)
        self.next_tr = 0
        self.live = []      # [track, phase at the start of its current hop]
        self.head = None    # noise the 1 ms envelope has already shaped
        if ch.tns is not None:
            m = ch.tns_start + len(ch.tns) * pc.TNS_BLOCK
            raw = np.concatenate([self._noise_hop() for _ in range(-(-m // NH))])
            self.head = pc.apply_tns(raw, ch.tns, ch.tns_start)

    def _noise_hop(self):
        """The next NH samples of noise."""
        i = self.nf
        self.nf += 1
        y = noise_frame(self.seed, i, self.ngain[i]) if i < len(self.ngain) else np.zeros(NN)
        out = self.ntail + y[:NH]
        self.ntail = y[NH:]
        return out

    def _noise(self, p, n):
        out = np.empty(n)
        for k in range(0, n, NH):
            if self.head is not None and p + k < len(self.head):
                out[k : k + NH] = self.head[p + k : p + k + NH]
            else:
                out[k : k + NH] = self._noise_hop()
        return out

    def _sines(self, p, n):
        """Partials over samples p..p+n. A track's frame k sits at sample
        (start + k) * H; frequency and level run straight between frames,
        with one hop of fade before the first frame and after the last."""
        H, out, tracks = self.H, np.zeros(n), self.ch.tracks
        t = np.arange(H)
        for j in range(n // H):
            fr = p // H + j                 # this hop runs from frame fr to fr + 1
            while self.next_tr < len(self.order) and tracks[self.order[self.next_tr]].start - 1 <= fr:
                tr = tracks[self.order[self.next_tr]]
                self.next_tr += 1
                if tr.start - 1 < fr:       # frame 0 track: its fade in fell before sample 0
                    self.live.append([tr, tr.ph[0]])
                    continue
                self.live.append([tr, tr.ph[0] - pc.TWO_PI * tr.f[0] / pc.SR * H])
            keep = []
            for item in self.live:
                tr, th = item
                k = fr - tr.start           # -1 is the fade in, len - 1 the fade out
                L = len(tr.f)
                if k >= L:
                    continue
                w0 = pc.TWO_PI * tr.f[max(k, 0)] / pc.SR
                w1 = pc.TWO_PI * tr.f[min(k + 1, L - 1)] / pc.SR
                a0 = 10 ** (tr.a[k] / 20) if k >= 0 else 0.0
                a1 = 10 ** (tr.a[k + 1] / 20) if k + 1 < L else 0.0
                ph = th + w0 * t + (w1 - w0) / (2 * H) * t**2
                out[j * H : (j + 1) * H] += (a0 + (a1 - a0) * t / H) * np.cos(ph)
                item[1] = th + 0.5 * (w0 + w1) * H
                keep.append(item)
            self.live = keep
        return out

    def step(self):
        """The next G samples."""
        p = self.pos
        self.pos += G
        y = self._sines(p, G)
        nz = self._noise(p, G)
        if self.v3:     # the noise is already muted where a layer carries the band
            for L in self.layers:
                y += L.take(G)
            return y + nz
        for i, L in enumerate(self.layers):
            x = np.concatenate([L.hop() for _ in range(G // L.M)])
            if i == 0:
                # the coded attack stands in for the noise while it runs
                j, n = self.ch.junction, self.xn
                idx = np.arange(p, p + G)
                w = np.where(idx < j, 1.0, 1 - (idx - j) / max(n - j - 1, 1)) * (idx < n)
                nz *= 1 - w
                x = x * w
            y += x
        return y + nz


class Voice:
    """Stereo note from file bytes. render(n) returns the next n samples."""

    def __init__(self, data: bytes):
        bl, packed = pf.blobs(data)
        v3 = data[: len(pf.MAGIC3)] == pf.MAGIC3
        self.ch = [ChannelVoice(b, 7 + 100 * i, packed, v3) for i, b in enumerate(bl)]
        self.n, self.pos = self.ch[0].n, 0
        self.buf = np.zeros((0, 2))

    def render(self, n):
        while len(self.buf) < n:
            ys = [c.step() for c in self.ch]
            M, S = ys[0], ys[1] if len(ys) > 1 else 0.0
            self.buf = np.concatenate([self.buf, np.stack([M + S, M - S], axis=1)])
        out, self.buf = self.buf[:n].copy(), self.buf[n:]
        left = self.n - self.pos
        if left < n:
            out[max(left, 0) :] = 0.0
        self.pos += n
        return out


def _check(job):
    import soundfile as sf
    import run_prototype as rp
    (name, path, kind, pitched, nm), out_dir, tname = job
    data = open(os.path.join(out_dir, name, f"{tname}.pinst"), "rb").read()
    v3 = data[: len(pf.MAGIC3)] == pf.MAGIC3
    x, _ = sf.read(path, always_2d=True)
    if kind == "gtr":
        x = x[500:]
    off = pf.render(data)
    v = Voice(data)
    y = v.render(v.n)
    sd = 0.0    # partials alone, offline against block by block
    for (ch, tier), b in zip(pf.unpack(data), pf.blobs(data)[0]):
        cv = ChannelVoice(b, 7, v3=v3)
        a = pc.synth_tracks(ch.tracks, ch.n, ch.H, mode="integrate", anchors=ch.info["anchors"])
        s = np.concatenate([cv._sines(p, G) for p in range(0, ch.n + G, G)])[: ch.n]
        sd = max(sd, float(np.abs(a - s).max()))
    v2, parts, rng = Voice(data), [], np.random.default_rng(3)
    while sum(map(len, parts)) < v2.n:
        parts.append(v2.render(int(rng.integers(1, 3000))))
    blk = float(np.abs(np.concatenate(parts)[: v2.n] - y).max())
    m = min(len(x), len(y))
    od = float(np.abs(off[: len(y)] - y[: len(off)]).max())
    so, ss = rp.score(x[:m], off[:m]), rp.score(x[:m], y[:m])
    sf.write(os.path.join(out_dir, name, f"{tname}_stream.wav"), y, pc.SR, subtype="PCM_24")
    return name, tname, sd, blk, od, so, ss


if __name__ == "__main__":
    for e in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS"):
        os.environ.setdefault(e, "1")
    from concurrent.futures import ProcessPoolExecutor
    import run_prototype as rp
    out_dir = sys.argv[1]
    tiers = sys.argv[2:] or ["standard"]
    jobs = [(n, out_dir, t) for n in rp.NOTES for t in tiers]
    print(f"{'note':18s} tier      sines diff  block diff  vs offline   offline (mrstft mel)   stream (mrstft mel)")
    with ProcessPoolExecutor(12) as ex:
        for name, t, sd, blk, od, so, ss in ex.map(_check, jobs):
            print(f"{name:18s} {t:9s} {sd:.1e}    {blk:.1e}     {od:.1e}     {so["mrstft_db"]:5.2f} {so["mel_db"]:5.2f}          {ss["mrstft_db"]:5.2f} {ss["mel_db"]:5.2f}")
