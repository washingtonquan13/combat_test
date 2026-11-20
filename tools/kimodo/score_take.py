"""Scores raw Kimodo takes so seeds can be ranked before anything is baked.

    python -I tools/kimodo/score_take.py --role hero --contact 86 \
        --cons prompts/m1/h.cons out/m1_h1 out/m1_h2 ...

Reads each take's joint_positions.f32 and root_positions.f32 (30 SOMA joints,
30 fps, metres, Y up) and prints one row per take, best first. Measures, from
the bake-off spec (docs/plans/bg3_cinematics.md, M1; proposal section 5.1):

  skate    cm a planted foot slides, worst single plant. A foot is planted
           while it is within PLANT_HEIGHT of the floor and moving slower
           than PLANT_SPEED.
  jerk     root jerk, mean |d3 root / dt3| in m/s^3: a jittery or popping
           body scores high.
  pen      cm the lowest foot joint goes below the floor (the floor is the
           take's own lowest foot height over its first 10 frames).
  miss     cm, worst constraint miss from the --cons file (root, joint).
  ttc      frames between the asked contact and where the motion puts it:
           hero, the frame the right hand reaches furthest along the
           thrust; attacker, the frame the right hand bottoms out after
           the wind-up.
  drift    m the root wanders from where it starts, furthest, up to the
           contact and 20 frames past it. An exchange is staged on a spot,
           so a body that walks off it is no use however clean it is.
  swing    m/s, the right hand's fastest speed in the 20 frames before
           the asked contact: commitment. A real blow is fast (an
           attacker's overhead cut wants 4 m/s or more).
  windup   frames the right hand is held above the head before the blow.
           A heavy strike needs at least 8 (5.1, anticipation).

score = skate + 2 pen + miss + 3 ttc + jerk / 50 + 20 (drift - 0.6, if
over), plus 100 when the attacker's wind-up is short, plus 10 per m/s the
swing is under 4. Lower is better.
"""

import argparse
import math
import sys

import numpy as np

NAMES = ["Hips", "Spine1", "Spine2", "Chest", "Neck1", "Neck2", "Head", "Jaw",
         "LeftEye", "RightEye", "LeftShoulder", "LeftArm", "LeftForeArm",
         "LeftHand", "LeftHandThumbEnd", "LeftHandMiddleEnd", "RightShoulder",
         "RightArm", "RightForeArm", "RightHand", "RightHandThumbEnd",
         "RightHandMiddleEnd", "LeftLeg", "LeftShin", "LeftFoot",
         "LeftToeBase", "RightLeg", "RightShin", "RightFoot", "RightToeBase"]
J = {n: i for i, n in enumerate(NAMES)}
FPS = 30.0
PLANT_HEIGHT = 0.04
PLANT_SPEED = 0.25
WINDUP_MIN = 8


def load(take):
    P = np.fromfile(take + "/joint_positions.f32", np.float32).reshape(-1, 30, 3)
    R = np.fromfile(take + "/root_positions.f32", np.float32).reshape(-1, 3)
    return P.astype(np.float64), R.astype(np.float64)


def plants(P, floor):
    """Worst slide, in cm, of any foot over any of its plants."""
    worst = 0.0
    for foot, toe in (("LeftFoot", "LeftToeBase"), ("RightFoot", "RightToeBase")):
        f = P[:, J[foot]]
        t = P[:, J[toe]]
        low = np.minimum(f[:, 1], t[:, 1]) - floor
        flat = f[:, [0, 2]]
        speed = np.zeros(len(f))
        speed[1:] = np.linalg.norm(np.diff(flat, axis=0), axis=1) * FPS
        down = (low < PLANT_HEIGHT) & (speed < PLANT_SPEED)
        start = None
        for i in range(len(down) + 1):
            if i < len(down) and down[i]:
                if start is None:
                    start = i
            elif start is not None:
                if i - start >= 3:
                    seg = flat[start:i]
                    worst = max(worst, float(np.linalg.norm(seg - seg[0], axis=1).max()) * 100)
                start = None
    return worst


def jerk(R):
    d3 = np.diff(R, n=3, axis=0) * FPS ** 3
    return float(np.linalg.norm(d3, axis=1).mean())


def constraint_miss(P, R, cons):
    worst = 0.0
    if not cons:
        return worst
    for line in open(cons):
        line = line.split("#")[0].split()
        if not line:
            continue
        kind, f = line[0], int(line[1])
        if f >= len(P):
            continue
        if kind == "root":
            x, z = map(float, line[2:4])
            worst = max(worst, math.hypot(R[f, 0] - x, R[f, 2] - z) * 100)
        elif kind == "joint":
            t = np.array(list(map(float, line[3:6])))
            worst = max(worst, float(np.linalg.norm(P[f, J[line[2]]] - t)) * 100)
    return worst


def hero_contact(P, asked):
    """The frame the right hand is furthest along the thrust, near `asked`."""
    lo, hi = max(asked - 15, 1), min(asked + 15, len(P) - 1)
    hips = P[:, J["Hips"]]
    hand = P[:, J["RightHand"]]
    # Along the body's own facing at the lunge's start.
    facing = hand[lo] - hips[lo]
    facing[1] = 0.0
    facing /= max(np.linalg.norm(facing), 1e-6)
    reach = (hand[lo:hi] - hips[lo]) @ facing
    return lo + int(np.argmax(reach)), 0


def attacker_contact(P, asked):
    """The frame the right hand bottoms out after the wind-up, and how many
    frames it was held above the head before it."""
    hand = P[:, J["RightHand"], 1]
    head = P[:, J["Head"], 1]
    lo, hi = max(asked - 20, 1), min(asked + 15, len(P) - 1)
    bottom = lo + int(np.argmin(hand[lo:hi]))
    # The wind-up: the run of frames above the head that ends before the
    # bottom (the last one, the blow starting down from it).
    up = hand > head
    end = bottom
    while end > 0 and not up[end]:
        end -= 1
    start = end
    while start > 0 and up[start - 1]:
        start -= 1
    held = (end - start + 1) if up[end] else 0
    return bottom, held


def score(take, role, asked, cons):
    P, R = load(take)
    floor = float(np.min(P[:10, [J["LeftFoot"], J["LeftToeBase"], J["RightFoot"], J["RightToeBase"]], 1]))
    low = float(np.min(P[:, [J["LeftFoot"], J["LeftToeBase"], J["RightFoot"], J["RightToeBase"]], 1]))
    row = {
        "take": take,
        "skate": plants(P, floor),
        "jerk": jerk(R),
        "pen": max(0.0, (floor - low) * 100),
        "miss": constraint_miss(P, R, cons),
    }
    if role == "hero":
        at, held = hero_contact(P, asked)
    else:
        at, held = attacker_contact(P, asked)
    row["at"] = at
    row["ttc"] = abs(at - asked)
    row["windup"] = held
    hand = P[:, J["RightHand"]]
    lo = max(asked - 20, 1)
    hi = min(asked + 3, len(P))
    row["swing"] = float((np.linalg.norm(np.diff(hand[lo - 1:hi], axis=0), axis=1) * FPS).max())
    end = min(len(R), asked + 21)
    row["drift"] = float(np.linalg.norm(R[:end, [0, 2]] - R[0, [0, 2]], axis=1).max())
    row["score"] = (row["skate"] + 2 * row["pen"] + row["miss"] + 3 * row["ttc"]
                    + row["jerk"] / 50 + 20 * max(0.0, row["drift"] - 0.6)
                    + 10 * max(0.0, 4.0 - row["swing"]) + (100 if role == "attacker" and held < WINDUP_MIN else 0))
    return row


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--role", choices=["hero", "attacker"], required=True)
    ap.add_argument("--contact", type=int, required=True)
    ap.add_argument("--cons", default="")
    ap.add_argument("takes", nargs="+")
    a = ap.parse_args()
    rows = sorted((score(t, a.role, a.contact, a.cons) for t in a.takes), key=lambda r: r["score"])
    print(f"{'take':28s} {'score':>7s} {'skate':>6s} {'jerk':>7s} {'pen':>5s} {'miss':>6s} {'ttc':>4s} {'at':>4s} {'drift':>6s} {'swing':>6s} {'windup':>6s}")
    for r in rows:
        print(f"{r['take']:28s} {r['score']:7.2f} {r['skate']:6.2f} {r['jerk']:7.1f} {r['pen']:5.2f} {r['miss']:6.2f} {r['ttc']:4d} {r['at']:4d} {r['drift']:6.2f} {r['swing']:6.2f} {r['windup']:6d}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
