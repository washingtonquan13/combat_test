""".pinst note file: what compile_channel decided, as bytes, and a decoder
that rebuilds the note from those bytes alone. The decoder is the reference
any other player has to match.

Layout (every integer is a zigzag varint unless said otherwise):

  "PINST1"
  sample rate, channel count (1 = mid only, 2 = mid + side),
  packed (1 = streams are raw LZMA2, 0 = streams stored as they are)
  per channel: byte length, then the channel blob

Channel blob:
  header   n, H, noise_H, noise_bands, f_cents*1000, a_db*1000, noise_q*1000,
           f0_cents*1000, phase_bits, lock (0/1), f0_frames, track count,
           noise_frames, tns_len, tns_start, junction, lf_hz,
           layer count, then per layer: n, M, K, bands, snr*100, noise_hz, dead, frames
  streams  each: byte length, then the data
           hdr dt df da noise tns f0, then sc and q per layer

  hdr      per track: start delta, key count, [harmonic number if lock],
           first cents code, first level code, phase (one raw byte)
  dt df da per track, per key after the first: frame delta, cents delta, level delta
  noise    first row of band codes, then per key: frame delta, band deltas
  tns, f0  per key: frame delta, value delta

  python -I tools/pinst/pinst_file.py OUT_DIR [NAME,NAME]   round-trip check
"""
import lzma
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pinst_codec as pc  # noqa: E402

MAGIC = b"PINST1"
_F = [{"id": lzma.FILTER_LZMA2, "preset": 9 | lzma.PRESET_EXTREME}]


def _put(out, *vals):
    for v in vals:
        pc._varint(int(v), out)


def _lz(b):
    return pc.lz_bytes(b)


def _unlz(b):
    return lzma.decompress(b, format=lzma.FORMAT_RAW, filters=_F) if b else b""


class Cur:
    def __init__(self, b):
        self.b, self.i = b, 0

    def v(self):
        z, sh = 0, 0
        while True:
            c = self.b[self.i]
            self.i += 1
            z |= (c & 0x7F) << sh
            sh += 7
            if c < 128:
                return (z >> 1) ^ -(z & 1)

    def raw(self):
        self.i += 1
        return self.b[self.i - 1]

    def take(self, n):
        self.i += n
        return self.b[self.i - n : self.i]

    def left(self):
        return self.i < len(self.b)


def _ints(b, count):
    a = np.frombuffer(b, dtype=np.uint8)
    if len(a) == count:      # every value fits one byte
        z = a.astype(np.int64)
        return (z >> 1) ^ -(z & 1)
    c = Cur(b)
    return np.array([c.v() for _ in range(count)], dtype=np.int64)


# ------------------------------------------------------------------- write

def pack_channel(dec: pc.Channel, tier: pc.Tier, packed=True) -> bytes:
    assert dec.pcm is None, "the verbatim-attack tier has no file form"
    I = dec.info
    S = I["streams"]
    layers = [I[k] for k in ("xf", "xlf") if k in I]
    assert ("xf" in I) or ("xlf" not in I)
    out = bytearray()
    _put(out, dec.n, dec.H, dec.noise_H, tier.noise_bands, round(tier.f_cents * 1000), round(tier.a_db * 1000),
         round(tier.noise_q * 1000), round(tier.f0_cents * 1000), tier.phase_bits, I["lock"], I["f0_frames"],
         I["n_tracks"], I["noise_frames"], 0 if dec.tns is None else I["tns_len"], dec.tns_start, dec.junction,
         round(I.get("lf_hz", 0)), len(layers))
    for x in layers:
        _put(out, x["n"], x["M"], x["K"], x["nbands"], round(x["snr"] * 100), round(x["noise_hz"]), x["dead"], x["frames"])
    streams = [S["hdr"], S["dt"], S["df"], S["da"], S["noise"], S["tns"] if dec.tns is not None else b"", S["f0"]]
    for x in layers:
        streams += [x["sc"], x["q"]]
    for s in streams:
        z = _lz(s) if packed else bytes(s)
        _put(out, len(z))
        out += z
    return bytes(out)


def pack(channels, tier, packed=True) -> bytes:
    """channels: decoded Channels, mid first, side second if kept."""
    out = bytearray(MAGIC)
    _put(out, pc.SR, len(channels), int(packed))
    for ch in channels:
        b = pack_channel(ch, tier, packed)
        _put(out, len(b))
        out += b
    return bytes(out)


# -------------------------------------------------------------------- read

def unpack_channel(blob: bytes, decode_layers=True, packed=True):
    """Returns (Channel, Tier holding what render needs). With
    decode_layers off the transform layers come back as their codes:
    (Channel, Tier, [(sc, q, n, M, K, bands, snr, noise_hz, dead)])."""
    c = Cur(blob)
    (n, H, noise_H, nb, f_c, a_d, n_q, f0_c, pbits, lock, f0_frames, ntr, nfr, tns_len, tns_start, junction,
     lf_hz, nlay) = [c.v() for _ in range(18)]
    f_c, a_d, n_q, f0_c = f_c / 1000, a_d / 1000, n_q / 1000, f0_c / 1000
    lay = [[c.v() for _ in range(8)] for _ in range(nlay)]
    st = []
    for _ in range(7 + 2 * nlay):
        L = c.v()
        st.append(_unlz(c.take(L)) if packed else bytes(c.take(L)))
    hdr, dt, df, da, noise, tns, f0 = st[:7]

    def pairs(b):
        cc, k, q, kk, qq = Cur(b), [], [], 0, 0
        while cc.left():
            kk += cc.v()
            qq += cc.v()
            k.append(kk)
            q.append(qq)
        return np.array(k), np.array(q)

    f0q = None
    if lock:
        k0, q0 = pairs(f0)
        f0q = 20.0 * 2 ** (pc.expand(k0, (q0 * f0_c).astype(float)[:, None], f0_frames)[:, 0] / 1200)
    tracks, anchors = [], []
    ch_, ct, cf, ca = Cur(hdr), Cur(dt), Cur(df), Cur(da)
    start = 0
    for _ in range(ntr):
        start += ch_.v()
        nk = ch_.v()
        hh = ch_.v() if lock else 0
        qc, qa, qph = [ch_.v()], [ch_.v()], ch_.raw()
        keys = [0]
        for _ in range(nk - 1):
            keys.append(keys[-1] + ct.v())
            qc.append(qc[-1] + cf.v())
            qa.append(qa[-1] + ca.v())
        L = keys[-1] + 1
        ref = hh * f0q[start : start + L] if lock else np.full(L, 20.0)
        full = pc.expand(np.array(keys), np.stack([np.array(qc) * f_c, np.array(qa) * a_d], axis=1).astype(float), L)
        ph = np.zeros(L)
        ph[0] = qph / (1 << pbits) * pc.TWO_PI
        tracks.append(pc.Track(start, ref * 2 ** (full[:, 0] / 1200), full[:, 1], ph))
        anchors.append(0)
    cn = Cur(noise)
    rows, nkeys = [np.array([cn.v() for _ in range(nb)])], [0]
    while cn.left():
        nkeys.append(nkeys[-1] + cn.v())
        rows.append(rows[-1] + np.array([cn.v() for _ in range(nb)]))
    # -200 dB is silence; nothing under it means anything
    noise_db = pc.expand(np.array(nkeys), np.maximum(np.array(rows).astype(float) * n_q, -200.0), nfr)
    tns_dec = None
    if tns_len:
        tk, qt = pairs(tns)
        tns_dec = pc.expand(tk, (qt * 1.5).astype(float)[:, None], tns_len)[:, 0]
    out = pc.Channel(n, H, tracks, noise_db, noise_H, tns_dec, tns_start, None, junction, {"anchors": anchors})
    codes = []
    for i, (xn, M, K, bands, snr, noise_hz, dead, F) in enumerate(lay):
        nbx = len(pc._xf_edges(K, bands)) - 1
        sc = np.cumsum(_ints(st[7 + 2 * i], F * nbx).reshape(F, nbx), axis=0)
        q = _ints(st[8 + 2 * i], F * K).reshape(F, K)
        codes.append((sc, q, xn, M, K, bands, snr / 100, float(noise_hz), dead))
    if len(codes) > 1:
        edges = pc.erb_edges(nb)
        out.noise_db[:, np.sqrt(edges[:-1] * edges[1:]) < lf_hz] = -200.0
    if not decode_layers:
        return out, pc.Tier("file", noise_bands=nb), codes
    sig = [pc.xform_decode(*c) for c in codes]
    if sig:
        out.xres = sig[0]
    if len(sig) > 1:
        out.xlf = sig[1]
    return out, pc.Tier("file", noise_bands=nb)


def unpack(data: bytes):
    assert data[: len(MAGIC)] == MAGIC
    c = Cur(data)
    c.i = len(MAGIC)
    sr, nch, packed = c.v(), c.v(), c.v()
    assert sr == pc.SR
    return [unpack_channel(c.take(c.v()), packed=packed) for _ in range(nch)]


def blobs(data: bytes):
    """(channel blobs, packed)"""
    assert data[: len(MAGIC)] == MAGIC
    c = Cur(data)
    c.i = len(MAGIC)
    sr, nch, packed = c.v(), c.v(), c.v()
    return [c.take(c.v()) for _ in range(nch)], packed


def repack(data: bytes, packed: bool) -> bytes:
    """The same note with its streams packed or stored."""
    bl, was = blobs(data)
    out = bytearray(MAGIC)
    _put(out, pc.SR, len(bl), int(packed))
    for b in bl:
        c = Cur(b)
        for _ in range(17):
            c.v()
        nl = c.v()
        for _ in range(8 * nl):
            c.v()
        o = bytearray(b[: c.i])
        for _ in range(7 + 2 * nl):
            s = c.take(c.v())
            s = _unlz(s) if was else bytes(s)
            s = _lz(s) if packed else s
            _put(o, len(s))
            o += s
        _put(out, len(o))
        out += o
    return bytes(out)


def render(data: bytes) -> np.ndarray:
    """Stereo audio from file bytes."""
    ys = [pc.render(ch, tier) for ch, tier in unpack(data)]
    M = ys[0]
    S = ys[1] if len(ys) > 1 else np.zeros_like(M)
    return np.stack([M + S, M - S], axis=1)


# ------------------------------------------------------------------- check

def _check(job):
    import soundfile as sf
    import run_prototype as rp
    (name, path, kind, pitched, nm), out_dir, tname = job
    tier = [t for t in rp.TIERS if t.name == tname][0]
    x, _ = sf.read(path, always_2d=True)
    if kind == "gtr":
        x = x[500:]
    f0 = rp.note_hz(nm) if nm else None
    M, S = 0.5 * (x[:, 0] + x[:, 1]), 0.5 * (x[:, 0] - x[:, 1])
    side_db = 20 * np.log10(np.sqrt((S**2).mean()) / max(np.sqrt((M**2).mean()), 1e-12) + 1e-12)
    chans, ys, counted = [], [], 0
    for sig in (M, S) if side_db >= -40 else (M,):
        _, dec, sizes = pc.compile_channel(sig, pitched, f0, tier)
        chans.append(dec)
        ys.append(pc.render(dec, tier))
        counted += sum(sizes.values())
    data = pack(chans, tier)
    os.makedirs(os.path.join(out_dir, name), exist_ok=True)
    open(os.path.join(out_dir, name, f"{tname}.pinst"), "wb").write(data)
    y = render(data)
    S2 = ys[1] if len(ys) > 1 else np.zeros_like(ys[0])
    ref = np.stack([ys[0] + S2, ys[0] - S2], axis=1)
    return name, tname, len(data), counted, float(np.abs(y - ref).max()), float(np.abs(ref).max())


if __name__ == "__main__":
    for v in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS"):
        os.environ.setdefault(v, "1")
    from concurrent.futures import ProcessPoolExecutor
    import run_prototype as rp
    out_dir = sys.argv[1]
    only = sys.argv[2].split(",") if len(sys.argv) > 2 else None
    jobs = [(n, out_dir, t) for n in rp.NOTES if not only or any(o in n[0] for o in only) for t in ("mid", "body")]
    with ProcessPoolExecutor(12) as ex:
        for name, t, size, counted, err, peak in ex.map(_check, jobs):
            print(f"{name:18s} {t:5s} file {size:7d} B  counted {counted:7d} B  max diff {err:.2e} (peak {peak:.3f})")
