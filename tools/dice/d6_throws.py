"""Simulates and picks the d6 throws the skill-check dice sprites are rendered from.

    python -I tools/dice/d6_throws.py <throws.json>

Physics first, art second: thousands of candidate throws are simulated at
once (numpy, a penalty-contact cube on a floor, camera looking straight down
at it; batches spread over the CPU's cores, a die leaving its batch once
it lies still), and HEADS of them are kept,
each passing every rule below. The
renderer (render_d6_sheets.py) only keys what this writes; the popup flies
each die along the same path, read back from the packed sidecar.

A cube has 24 rotations onto itself, so one throw can end on any face just
by relabelling which face is which. The result is known before the popup
animates, so each kept throw is written six times, relabelled from its first
sample (right-multiplied by the cube turn that brings face n up): six whole
rolls, launch to rest, one per result, with no cut between them.

Rules for a kept throw, all measured after its yaw fix (the whole throw is
turned about the camera's axis so it comes to rest square to the screen,
which the floor's symmetry makes free):
- Spin reads as a tumble, not a strobe: airborne, it turns SPIN_MEAN degrees
  a frame on average and never more than SPIN_MAX (a cube looks the same
  every 90 degrees, so near 45 a frame it seems to stand still or spin
  backward); its axis never stays within AXIS_NEAR degrees of a face axis
  for more than AXIS_RUN airborne frames (a spin about a face axis repeats
  its silhouette every quarter turn); and it turns at least MIN_TUMBLE
  degrees in all before rest.
- It travels toward screen up: net direction within PATH_SPREAD degrees,
  PATH_PX long (it starts close to the dice row), never stepping back down,
  never faster than MAX_STEP_PX a frame.
- The face it rests on stays turned from the camera (unreadable) for its
  first HIDDEN_START frames, so no result shows at launch.
- It ends on a tip: its last turn of more than 45 degrees rolls it over an
  edge, at most TIP_LATE frames before rest. The screen direction of that
  roll (eight ways: +Y, -Y, +X, -X and the diagonals) is its ending.
- The HEADS kept throws all end in different directions, and any three of
  them, in any slot order, launched LAUNCH_FRAMES apart into slots
  SLOT_SPACING faces apart, never overlap in flight.
"""

import concurrent.futures
import itertools
import json
import math
import os
import sys
import time

import numpy as np

HALF = 1.7
# Face edge on screen, px; fixes the world-to-pixel scale.
FACE_PX = 96
PX_PER_UNIT = FACE_PX / (2 * HALF)
FPS = 30
# Positions and rotations are written this many times a frame, so the
# renderer's motion blur follows the true arc through each shutter.
SAMPLES = 4
SUBSTEPS = 80
MAX_FRAMES = 90
GRAVITY = 60.0
# Contact: penalty spring and damper per corner, Coulomb friction made
# smooth below FRICTION_SLIP, and a little spin damping while touching.
STIFFNESS = 2.0e5
DAMPING = 140.0
FRICTION = 0.55
FRICTION_SLIP = 0.05
CONTACT_SPIN_DAMPING = 1.5
INERTIA = (2 * HALF) ** 2 / 6.0

CANDIDATES = 150000
BATCH = 2000
SEED = 20261107
# Launch speed, world units a second, and spin, radians a second.
LAUNCH_SPEED = (6.0, 11.0)
LAUNCH_SPIN = (13.0, 19.5)
HEADS = 4
# Airborne spin, degrees a frame: the mean's range and the cap on any frame.
SPIN_MEAN = (20.0, 32.0)
SPIN_MAX = 38.0
# A frame's turn whose axis lies within AXIS_NEAR degrees of a cube face
# axis; more than AXIS_RUN such airborne frames in a row is a looping spin.
AXIS_NEAR = 20.0
AXIS_RUN = 4
# Fewest airborne frames, and total turn launch to rest, degrees.
MIN_AIRBORNE = 4
MIN_TUMBLE = 270.0
# Two endings count as different when their tip directions differ by at
# least this many degrees as well as by eight-way label.
TIP_APART = 45.0
# The rest face's normal stays below this height toward the camera (its
# numeral unreadable) for the first HIDDEN_START frames.
HIDDEN_START = 4
READABLE = 0.35
# The final tip lands at most this many frames before rest.
TIP_LATE = 14
POOL = 15
PATH_SPREAD = 30.0
MAX_STEP_PX = 19.0
PATH_PX = (110.0, 260.0)
# A bounce may push the die back toward the camera's bottom edge this far
# in one frame, in world units.
MAX_BACKSTEP = 0.15
# Sideways wander from the line the die rests on, world units. Neighbours
# sit SLOT_SPACING apart, so a wandering die crosses into the next slot.
MAX_DRIFT = 1.0
# Popup slots, centre to centre, in faces, and each die's launch delay.
SLOT_SPACING = 1.6
LAUNCH_FRAMES = (0, 4, 8)
# Gap kept between two dice's silhouettes, in faces.
CLEARANCE = 0.1
# Over the last REST_BLEND frames each roll eases into its exact rest pose,
# so every result's final frame is the same pixels as its still.
REST_BLEND = 4
# The final tip's axis lies at least this cosine flat to the floor: a roll
# over an edge, not a twist about the camera axis.
TIP_FLAT = 0.7
TIP_NAMES = ("+X", "+X+Y", "+Y", "-X+Y", "-X", "-X-Y", "-Y", "+X-Y")

# Face n: (outward normal, the way "up" its numeral reads), cube-local.
# Opposite faces sum to 7. render_d6_sheets.py builds the die from the same.
FACES = {
    1: ((0, 0, 1), (0, 1, 0)),
    6: ((0, 0, -1), (0, 1, 0)),
    2: ((1, 0, 0), (0, 0, 1)),
    5: ((-1, 0, 0), (0, 0, 1)),
    3: ((0, -1, 0), (0, 0, 1)),
    4: ((0, 1, 0), (0, 0, 1)),
}


def face_rest(n: int) -> np.ndarray:
    """Rotation (cube-local to world) that rests face n square to the camera
    (+Z), its numeral upright (+Y)."""
    normal, up = (np.array(v, float) for v in FACES[n])
    right = np.cross(up, normal)
    return np.array([right, up, normal])


def cube_turns() -> list:
    turns = []
    for perm in itertools.permutations(range(3)):
        for signs in itertools.product((1, -1), repeat=3):
            m = np.zeros((3, 3))
            for i in range(3):
                m[i, perm[i]] = signs[i]
            if np.linalg.det(m) > 0:
                turns.append(m)
    return turns


def quat_to_mat(q: np.ndarray) -> np.ndarray:
    w, x, y, z = np.moveaxis(q, -1, 0)
    return np.stack([
        np.stack([1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y)], -1),
        np.stack([2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x)], -1),
        np.stack([2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y)], -1),
    ], -2)


def mat_to_quat(m: np.ndarray) -> np.ndarray:
    """One rotation matrix to a (w, x, y, z) quaternion."""
    t = np.trace(m)
    if t > 0:
        s = math.sqrt(t + 1.0) * 2
        q = [0.25 * s, (m[2, 1] - m[1, 2]) / s, (m[0, 2] - m[2, 0]) / s, (m[1, 0] - m[0, 1]) / s]
    else:
        i = int(np.argmax(np.diag(m)))
        j, k = (i + 1) % 3, (i + 2) % 3
        s = math.sqrt(1.0 + m[i, i] - m[j, j] - m[k, k]) * 2
        q = [0.0] * 4
        q[0] = (m[k, j] - m[j, k]) / s
        q[1 + i] = 0.25 * s
        q[1 + j] = (m[j, i] + m[i, j]) / s
        q[1 + k] = (m[k, i] + m[i, k]) / s
    q = np.array(q)
    return q / np.linalg.norm(q)


def quat_mul(a: np.ndarray, b: np.ndarray) -> np.ndarray:
    aw, ax, ay, az = np.moveaxis(a, -1, 0)
    bw, bx, by, bz = np.moveaxis(b, -1, 0)
    return np.stack([
        aw * bw - ax * bx - ay * by - az * bz,
        aw * bx + ax * bw + ay * bz - az * by,
        aw * by - ax * bz + ay * bw + az * bx,
        aw * bz + ax * by - ay * bx + az * bw,
    ], -1)


def rotation_angle(a: np.ndarray, b: np.ndarray) -> np.ndarray:
    """Degrees between rotation matrices a and b (batched on leading axes)."""
    c = (np.einsum("...ij,...ij->...", a, b) - 1.0) / 2.0
    return np.degrees(np.arccos(np.clip(c, -1.0, 1.0)))


def launch(n: int, rng: np.random.Generator):
    """Thrown from just above the floor, mostly toward screen up, tumbling."""
    x = np.zeros((n, 3))
    x[:, 2] = HALF + rng.uniform(1.5, 3.5, n)
    heading = np.radians(90.0 + rng.uniform(-30.0, 30.0, n))
    speed = rng.uniform(LAUNCH_SPEED[0], LAUNCH_SPEED[1], n)
    v = np.stack([np.cos(heading) * speed, np.sin(heading) * speed, rng.uniform(1.0, 6.0, n)], -1)
    q = rng.normal(size=(n, 4))
    q /= np.linalg.norm(q, axis=1, keepdims=True)
    axis = rng.normal(size=(n, 3))
    axis /= np.linalg.norm(axis, axis=1, keepdims=True)
    w = axis * rng.uniform(LAUNCH_SPIN[0], LAUNCH_SPIN[1], (n, 1))
    return x, v, q, w


# A die that has lain flat (within REST_TILT degrees) and still for
# REST_RUN frames never moves again (measured: none of the dice that stop
# that way starts again, while dice paused on an edge do), so it leaves
# the batch and its last pose fills the frames left. Same results, bit for
# bit; about 40 of the 90 frames simulated per die instead of all.
REST_RUN = 3
REST_TILT = 2.0


def simulate(x, v, q, w):
    """All candidates at once. Returns per sample: position (S, n, 3),
    rotation (S, n, 3, 3), lowest corner height (S, n); and per frame the
    linear and angular speed (F, n)."""
    n = len(x)
    dt = 1.0 / (FPS * SUBSTEPS)
    per_sample = SUBSTEPS // SAMPLES
    count = MAX_FRAMES * SAMPLES + 1
    pos, rot, low = np.empty((count, n, 3)), np.empty((count, n, 3, 3)), np.empty((count, n))
    lin, ang = np.zeros((MAX_FRAMES, n)), np.zeros((MAX_FRAMES, n))
    corners = np.array([[sx, sy, sz] for sx in (-1, 1) for sy in (-1, 1) for sz in (-1, 1)], float) * HALF
    cx, cy, cz = (corners[:, j, None] for j in range(3))
    x, v, q, w = x.copy(), v.copy(), q.copy(), w.copy()
    m = quat_to_mat(q)
    pos[0], rot[0], low[0] = x, m, 1.0
    active = np.arange(n)
    run = np.zeros(n, int)
    flat = math.cos(math.radians(REST_TILT))
    for frame in range(MAX_FRAMES):
        if len(active) == 0:
            break
        for sub in range(1, SUBSTEPS + 1):
            # Corner-major (8, n) arrays, summed over axis 0: the same
            # operations in the same order as the einsum / cross / sum
            # forms, so the floats match them exactly (pairwise sums over
            # a contiguous axis would not).
            mx, my, mz = m[:, 0], m[:, 1], m[:, 2]
            rx = (mx[:, 0] * cx + mx[:, 2] * cz) + mx[:, 1] * cy
            ry = (my[:, 0] * cx + my[:, 2] * cz) + my[:, 1] * cy
            rz = (mz[:, 0] * cx + mz[:, 2] * cz) + mz[:, 1] * cy
            depth = -(x[:, 2] + rz)
            touch = depth > 0.0
            wx, wy, wz = w[:, 0], w[:, 1], w[:, 2]
            ux = v[:, 0] + (wy * rz - wz * ry)
            uy = v[:, 1] + (wz * rx - wx * rz)
            uz = v[:, 2] + (wx * ry - wy * rx)
            fn = np.where(touch, np.maximum(0.0, STIFFNESS * depth - DAMPING * uz), 0.0)
            slip = np.sqrt(ux * ux + uy * uy)
            k = -FRICTION * fn
            den = np.maximum(slip, FRICTION_SLIP)
            fx, fy = k * ux / den, k * uy / den
            force = np.stack([fx.sum(0), fy.sum(0), fn.sum(0)], -1)
            force[:, 2] -= GRAVITY
            torque = np.stack([(ry * fn - rz * fy).sum(0), (rz * fx - rx * fn).sum(0),
                               (rx * fy - ry * fx).sum(0)], -1)
            v += force * dt
            w += torque / INERTIA * dt
            w *= (1.0 - CONTACT_SPIN_DAMPING * dt * touch.any(0))[:, None]
            x += v * dt
            q = q + 0.5 * dt * quat_mul(np.concatenate([np.zeros((len(w), 1)), w], 1), q)
            q /= np.linalg.norm(q, axis=1, keepdims=True)
            m = quat_to_mat(q)
            if sub % per_sample == 0:
                s = frame * SAMPLES + sub // per_sample
                pos[s, active], rot[s, active] = x, m
                low[s, active] = x[:, 2] + rz.min(0)
        lin[frame, active] = speed = np.linalg.norm(v, axis=1)
        ang[frame, active] = spin = np.linalg.norm(w, axis=1)
        lying = np.abs(m[:, 2, :]).max(1) > flat
        run[active] = np.where((speed <= 0.2) & (spin <= 0.3) & lying, run[active] + 1, 0)
        done = run[active] >= REST_RUN
        if done.any():
            s = (frame + 1) * SAMPLES
            gone = active[done]
            pos[s + 1:, gone], rot[s + 1:, gone] = x[done], m[done]
            low[s + 1:, gone] = low[s, gone]
            keep = ~done
            active, x, v, q, w, m = active[keep], x[keep], v[keep], q[keep], w[keep], m[keep]
    return pos, rot, low, lin, ang


def yaw(angle: float) -> np.ndarray:
    c, s = math.cos(angle), math.sin(angle)
    return np.array([[c, -s, 0], [s, c, 0], [0, 0, 1]])


def judge(i, pos, rot, low, lin, ang, turns):
    """The throw's kept form, or None with why it failed."""
    frames_lin, frames_ang = lin[:, i], ang[:, i]
    moving = np.nonzero((frames_lin > 0.2) | (frames_ang > 0.3))[0]
    if len(moving) == 0 or moving[-1] + 3 >= MAX_FRAMES:
        return None, "never rests"
    end = int(moving[-1]) + 2  # frames are 0..end, end at rest
    R = rot[::SAMPLES, i][: end + 1]
    P = pos[::SAMPLES, i][: end + 1]
    lows = low[::SAMPLES, i][: end + 1]
    r_end = R[end]
    top = np.round(r_end.T @ np.array([0, 0, 1.0]))
    if np.abs(top).sum() != 1 or np.degrees(np.arccos(np.clip((r_end @ top)[2], -1, 1))) > 3.0:
        return None, "not flat"

    # Path length does not change with the yaw fix below, so most throws
    # fail here before paying for it. The margin keeps the exact test
    # (after the fix, a rounding apart) the one that decides at the edges.
    d_raw = P[end, :2] - P[0, :2]
    raw_length = np.linalg.norm(d_raw) * PX_PER_UNIT
    if not PATH_PX[0] - 0.01 <= raw_length <= PATH_PX[1] + 0.01:
        return None, "path length"

    # Yaw fix: turn the throw about the camera axis so it rests square.
    # Four turns a quarter apart all do; take the one heading most up-screen.
    rest1 = face_rest(1)
    best = None
    for m in turns:
        f = rest1 @ (r_end @ m).T
        a = math.atan2(f[1, 0], f[0, 0])
        if rotation_angle(yaw(a) @ r_end @ m, rest1) > 3.0:
            continue
        heading = (yaw(a)[:2, :2] @ d_raw)
        off = abs(math.atan2(heading[0], heading[1]))
        if best is None or off < best[0]:
            best = (off, a)
    if best is None:
        return None, "not square"
    fix = yaw(best[1])
    R = np.einsum("ij,fjk->fik", fix, R)
    P = P @ fix.T

    # Path: toward screen up, no backsteps, capped speed.
    d = P[end, :2] - P[0, :2]
    length = np.linalg.norm(d) * PX_PER_UNIT
    if not PATH_PX[0] <= length <= PATH_PX[1]:
        return None, "path length"
    if abs(math.degrees(math.atan2(d[0], d[1]))) > PATH_SPREAD:
        return None, "path direction"
    steps = np.diff(P[:, :2], axis=0)
    if (steps[:, 1] < -MAX_BACKSTEP).any():
        return None, "backstep"
    if (np.linalg.norm(steps, axis=1) * PX_PER_UNIT).max() > MAX_STEP_PX:
        return None, "too fast"
    if np.abs(P[:, 0] - P[end, 0]).max() > MAX_DRIFT:
        return None, "drift"

    # Spin, frame to frame: a tumble, not a strobe or a loop.
    spins = rotation_angle(R[:-1], R[1:])
    airborne = np.array([low[f * SAMPLES: f * SAMPLES + SAMPLES + 1, i].min() > 0.05 for f in range(end)])
    if airborne.sum() < MIN_AIRBORNE:
        return None, "airborne"
    flying = spins[airborne]
    if flying.max() > SPIN_MAX:
        return None, "spin max"
    if not SPIN_MEAN[0] <= flying.mean() <= SPIN_MEAN[1]:
        return None, "spin mean"
    tumble = float(spins.sum())
    if tumble < MIN_TUMBLE:
        return None, "tumble"
    body = np.einsum("fji,fjk->fik", R[:-1], R[1:])  # each frame's turn, cube-local
    axes = np.stack([body[:, 2, 1] - body[:, 1, 2], body[:, 0, 2] - body[:, 2, 0],
                     body[:, 1, 0] - body[:, 0, 1]], -1)
    axes /= np.maximum(np.linalg.norm(axes, axis=1, keepdims=True), 1e-9)
    near = np.degrees(np.arccos(np.clip(np.abs(axes).max(1), 0.0, 1.0))) < AXIS_NEAR
    run = longest = 0
    for f in range(end):
        run = run + 1 if (near[f] and airborne[f]) else 0
        longest = max(longest, run)
    if longest > AXIS_RUN:
        return None, "face-axis spin"

    # Ending: the last turn of more than 45 degrees rolls over an edge; its
    # direction is where the rest face's top swings, on screen.
    tilt = np.array([rotation_angle(R[f], R[end]) for f in range(end + 1)])
    last = np.nonzero(tilt > 45.0)[0]
    if len(last) == 0:
        return None, "no tip"
    t0 = int(last[-1])
    rel = R[end] @ R[t0].T
    axis = np.array([rel[2, 1] - rel[1, 2], rel[0, 2] - rel[2, 0], rel[1, 0] - rel[0, 1]])
    flat = np.linalg.norm(axis[:2])
    if flat < 1e-6 or flat / np.linalg.norm(axis) < TIP_FLAT:
        return None, "tip axis"
    if end - t0 > TIP_LATE:
        return None, "early tip"
    top_local = r_end.T @ np.array([0, 0, 1.0])
    if (np.einsum("fij,j->fi", R[:HIDDEN_START], top_local)[:, 2] >= READABLE).any():
        return None, "result shown at launch"
    tip_angle = math.degrees(math.atan2(-axis[0], axis[1])) % 360.0
    tip = TIP_NAMES[int(round(tip_angle / 45.0)) % 8]

    # Every sample, fixed, for the renderer.
    s_end = end * SAMPLES
    Rs = np.einsum("ij,sjk->sik", fix, rot[: s_end + 1, i])
    Ps = pos[: s_end + 1, i] @ fix.T
    return {
        "index": i, "end": end, "path_px": float(length),
        "mean_spin": float(flying.mean()), "max_spin": float(flying.max()),
        "max_spin_all": float(spins.max()), "airborne": int(airborne.sum()),
        "tumble": tumble, "tip": tip, "tip_angle": tip_angle, "tip_frames": end - t0,
        "R": Rs, "P": Ps, "frame_P": P, "frame_R": R,
    }, None


def labelled(throw: dict, turns: list) -> dict:
    """The six results' rotations per sample: the same motion relabelled
    (right-multiplied by the cube turn that brings face n up), the last
    REST_BLEND frames eased into face n's exact rest."""
    Rs, Ps = throw["R"], throw["P"].copy()
    end_s = len(Rs) - 1
    out = {}
    blend_from = (throw["end"] - REST_BLEND) * SAMPLES
    for n in range(1, 7):
        rest = face_rest(n)
        m = min(turns, key=lambda t: rotation_angle(Rs[end_s] @ t, rest))
        quats = []
        prev = None
        for s in range(end_s + 1):
            qs = mat_to_quat(Rs[s] @ m)
            if s > blend_from:
                k = (s - blend_from) / (end_s - blend_from)
                k = k * k * (3 - 2 * k)
                qr = mat_to_quat(rest)
                if np.dot(qs, qr) < 0:
                    qr = -qr
                qs = qs * (1 - k) + qr * k  # nlerp: the gap is a degree or two
                qs /= np.linalg.norm(qs)
            if prev is not None and np.dot(prev, qs) < 0:
                qs = -qs
            quats.append(qs)
            prev = qs
        out[n] = np.array(quats)
    z = Ps[:, 2].copy()
    for s in range(blend_from + 1, end_s + 1):
        k = (s - blend_from) / (end_s - blend_from)
        k = k * k * (3 - 2 * k)
        z[s] = z[s] * (1 - k) + HALF * k
    Ps[:, 2] = z
    return out, Ps


def separation(pa, ra, pb, rb) -> float:
    """Gap between two dice in space (negative: interpenetrating), by the
    separating axis test for two boxes: their 3 + 3 face normals and the
    9 cross products of their edges. Two dice may cross on screen when one
    flies over the other; the popup draws the higher on top."""
    d = pb - pa
    axes = [ra[:, k] for k in range(3)] + [rb[:, k] for k in range(3)]
    axes += [np.cross(ra[:, i], rb[:, j]) for i in range(3) for j in range(3)]
    gap = -np.inf
    for n in axes:
        length = np.linalg.norm(n)
        if length < 1e-6:
            continue
        n = n / length
        reach = HALF * (np.abs(n @ ra).sum() + np.abs(n @ rb).sum())
        gap = max(gap, abs(n @ d) - reach)
    return gap


def pair_clear(a: dict, b: dict, delay: int, slots: int) -> bool:
    """a in a slot, b `slots` slots right of it and launched `delay` frames
    later; both come to rest in their slots. Never closer than CLEARANCE."""
    offset = np.array([slots * SLOT_SPACING * 2 * HALF, 0.0, 0.0])
    rest = lambda t: t["frame_P"] - np.array([*t["frame_P"][-1, :2], 0.0])
    pa, pb = rest(a), rest(b) + offset
    for f in range(delay, max(len(pa), len(pb) + delay)):
        fa, fb = min(f, len(pa) - 1), min(f - delay, len(pb) - 1)
        if separation(pa[fa], a["frame_R"][fa], pb[fb], b["frame_R"][fb]) < CLEARANCE * 2 * HALF:
            return False
    return True


def tips_apart(a: dict, b: dict) -> bool:
    """a and b end rolling different ways on screen."""
    gap = abs((a["tip_angle"] - b["tip_angle"] + 180.0) % 360.0 - 180.0)
    return a["tip"] != b["tip"] and gap >= TIP_APART


def compatible(a: dict, b: dict) -> bool:
    """a and b may share one popup: they end differently and fill any two
    slots of one roll, in either order."""
    if not tips_apart(a, b):
        return False
    configs = {(LAUNCH_FRAMES[j] - LAUNCH_FRAMES[i], j - i) for i in range(3) for j in range(i + 1, 3)}
    return all(pair_clear(x, y, d, n) for x, y in ((a, b), (b, a)) for d, n in configs)


def run_batch(start: int):
    """Simulate and judge candidates start .. start + BATCH, seeded by start
    so the result does not depend on how batches are spread over cores."""
    rng = np.random.default_rng((SEED, start))
    turns = cube_turns()
    sim = simulate(*launch(BATCH, rng))
    kept, why = [], {}
    for i in range(BATCH):
        t, reason = judge(i, *sim, turns)
        if t is None:
            why[reason] = why.get(reason, 0) + 1
        else:
            t["index"] = start + i
            kept.append(t)
    return kept, why


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    kept, why = [], {}
    # One worker per physical core (numpy's elementwise work is one thread
    # each, and hyperthreads share a core's float units).
    workers = max(1, (os.cpu_count() or 2) // 2)
    starts = range(0, CANDIDATES, BATCH)
    began = time.perf_counter()
    with concurrent.futures.ProcessPoolExecutor(workers) as executor:
        for done, (batch_kept, batch_why) in enumerate(executor.map(run_batch, starts), 1):
            kept += batch_kept
            for reason, n in batch_why.items():
                why[reason] = why.get(reason, 0) + n
            took = time.perf_counter() - began
            print(f"d6_throws: batch {done}/{len(starts)} ({100 * done / len(starts):.0f}%), "
                  f"{len(kept)} kept, {took:.0f} s, about {took / done * (len(starts) - done):.0f} s left",
                  flush=True)
    print(f"d6_throws: {len(kept)} of {CANDIDATES} pass; rejected: {why}")
    tally = {}
    for t in kept:
        tally[t["tip"]] = tally.get(t["tip"], 0) + 1
    print(f"d6_throws: endings {dict(sorted(tally.items()))}")
    # Of every set of HEADS throws that end apart and whose pairs all clear,
    # the one whose least tumbling throw tumbles most. The search runs on
    # the POOL most tumbling throws of each ending.
    kept.sort(key=lambda t: -t["tumble"])
    pool = [t for name in TIP_NAMES for t in [k for k in kept if k["tip"] == name][:POOL]]
    pool.sort(key=lambda t: -t["tumble"])
    ok = {i: set() for i in range(len(pool))}
    for i, j in itertools.combinations(range(len(pool)), 2):
        if compatible(pool[i], pool[j]):
            ok[i].add(j)
            ok[j].add(i)
    print(f"d6_throws: {sum(map(len, ok.values())) // 2} compatible pairs")
    chosen, best = None, -1.0
    def grow(group, rest):
        nonlocal chosen, best
        if len(group) == HEADS:
            tumble = min(pool[g]["tumble"] for g in group)
            if tumble > best:
                chosen, best = [pool[g] for g in group], tumble
            return
        for k in sorted(rest):
            grow(group + [k], {r for r in rest if r > k} & ok[k])
    grow([], set(range(len(pool))))
    turns = cube_turns()
    if chosen is None:
        raise SystemExit("d6_throws: no set of throws clears in flight")
    heads = []
    for t in chosen:
        quats, Ps = labelled(t, turns)
        rest_xy = Ps[-1, :2]
        path = [[float((p[0] - rest_xy[0]) * PX_PER_UNIT), float(-(p[1] - rest_xy[1]) * PX_PER_UNIT),
                 float((p[2] - HALF) * PX_PER_UNIT)] for p in Ps[::SAMPLES]]
        heads.append({
            "candidate": t["index"], "frames": t["end"] + 1, "tip": t["tip"],
            "path_px": path,
            "samples": {"pos": Ps.tolist(), "quat": {str(n): q.tolist() for n, q in quats.items()}},
        })
        print(f"d6_throws: candidate {t['index']}: {t['end'] + 1} frames, tip {t['tip']} "
              f"({t['tip_angle']:.0f} deg), spin mean {t['mean_spin']:.1f} max {t['max_spin']:.1f} "
              f"deg/frame airborne ({t['airborne']} frames; {t['max_spin_all']:.1f} max any frame), "
              f"tumble {t['tumble']:.0f} deg, final tip {t['tip_frames']} frames before rest, "
              f"path {t['path_px']:.0f} px")
    with open(sys.argv[1], "w", newline="\n") as fh:
        json.dump({"fps": FPS, "samples": SAMPLES, "half": HALF, "face_px": FACE_PX,
                   "px_per_unit": PX_PER_UNIT, "heads": heads}, fh)


if __name__ == "__main__":
    main()
