"""Fewer elevated decks: decks.json with the least-needed ones taken down.

    python -I tools/blockout/decks_simplify.py <in dir> <out dir> --level moderate|aggressive|hyper [--raw <raw dir>]

Reads <in dir>/decks.json (decks_seed.py's) and writes <out dir>/decks.json
for decks_mesh.py, the same records less what the level takes down, and a
"simplified" entry saying what went. Works on whole groups: a run of ways
that continue one another (decks_mesh's chains) and every run twinned with
it are one road, kept or taken down together.

  - moderate: a street (no motorway or trunk in the group) whose deck
    nowhere stands STREET_LOW above the ground comes down onto it: every
    height 0, so a bridge is drawn as a road at grade and an approach is
    not drawn at all (the ground road under it is). A group joined to a
    deck it is not part of (a merge, a split or a continuation) stays up.
  - aggressive: moderate, and every ramp group (all *_link) none of whose
    ends comes down to the ground (within GROUND of it, and not joined to
    another deck) goes: the flyovers between highways. A ramp from a
    highway down to the street stays.
  - hyper: aggressive, and of the ramps left, those an interchange can do
    without, so what is still up reads as one highway and a few ramps
    off it. A ramp here is a ramp system, ramps joined to one another:
    a system that turns LOOP or more along some way through it (a
    cloverleaf loop, however many ways it is mapped as, and whatever it
    is joined to) goes. Then of the systems left joined to one highway
    way, its exits (joined at its start) or its entrances (joined at its
    end), the exits from one carriageway (one chain) whose middles are
    within INTERCHANGE of one another keep only the one that turns
    least, and the same for the entrances. Nothing left comes down:
    every deck kept stands as high as it did.

Every relation to a record taken out goes with it, so a deck a flyover
merged into simply runs on. With --raw, a highway way on the ground that a
ramp taken out leaves a dead end (the flyover's road mapped at grade where
it lands, as a way of its own) is taken out with it, and so on along it: it
is listed with the dropped ways, so osm_city.py's --drop-ways draws no road
for it either.

Map data (c) OpenStreetMap contributors, ODbL.
"""

import argparse
import json
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from decks_mesh import _chains, _records  # noqa: E402

# A street group this low everywhere comes down (moderate). bridges.py's
# LOW_HEIGHT: a bridge over only water or ground.
STREET_LOW = 6.0
# A ramp end this close to the ground, and free, reaches it (aggressive).
GROUND = 1.5
HIGHWAY = {"motorway", "motorway_link", "trunk", "trunk_link"}
# A ramp system turning this much is a loop (hyper takes it out), and the
# exits (or entrances) of one carriageway this close are one interchange's.
LOOP = math.radians(150.0)
INTERCHANGE = 450.0


def _groups(decks, recs, chains):
    """Chains joined by twin_of: lists of record indices (into recs)."""
    rec_of = {r["way"]: i for i, r in enumerate(recs)}
    chain_of = np.zeros(len(recs), int)
    for ci, ch in enumerate(chains):
        for r, _ in ch:
            chain_of[r] = ci
    parent = list(range(len(chains)))

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    for r in recs:
        for t in r["twins"]:
            if t in rec_of:
                parent[find(chain_of[rec_of[r["way"]]])] = find(chain_of[rec_of[t]])
    groups = {}
    for ci, ch in enumerate(chains):
        groups.setdefault(find(ci), []).extend(r for r, _ in ch)
    return list(groups.values())


def _linked(d):
    return ([m["into"] for m in d.get("merges", [])] + [s["from"] for s in d.get("splits", [])]
            + [c["way"] for c in d.get("continues", [])])


def _stubs(raw, dropped):
    """Highway ways in <raw>/features.json, none of them dropped, that end
    in a dead end where a dropped way used to go on, and those that then
    do, until none."""
    ways = {}
    for el in json.load(open(os.path.join(raw, "features.json"), encoding="utf-8"))["elements"]:
        if el["type"] == "way" and el.get("tags", {}).get("highway") and len(el.get("nodes") or []) >= 2:
            ways[el["id"]] = (el["nodes"], el["tags"]["highway"] in HIGHWAY)
    use = {}  # node -> ways using it
    for w, (nodes, _) in ways.items():
        for n in set(nodes):
            use.setdefault(n, set()).add(w)
    gone = set(dropped)
    open_ = {n for w in dropped if w in ways for n in (ways[w][0][0], ways[w][0][-1])}
    stubs = set()
    while open_:
        n = open_.pop()
        live = use.get(n, set()) - gone
        if len(live) != 1:
            continue
        (w,) = live
        nodes, highway = ways[w]
        if not highway or n not in (nodes[0], nodes[-1]) or nodes[0] == nodes[-1]:
            continue
        gone.add(w)
        stubs.add(w)
        open_.add(nodes[-1] if n == nodes[0] else nodes[0])
    return stubs


def _turning(d):
    """How far record d's line turns, all told, in radians."""
    p = np.array([[n["x"], n["z"]] for n in d["nodes"]])
    t = np.diff(p, axis=0)
    t = t[np.hypot(*t.T) > 0.05]
    a = np.arctan2(t[:, 1], t[:, 0])
    return float(np.abs(np.angle(np.exp(1j * np.diff(a)))).sum())


def _path_turning(ways, near, by_way):
    """How far a ramp system turns along the way through it that turns
    most: a loop is often mapped as several ways, none turning much alone."""
    turn = {w: _turning(by_way[w]) for w in ways}
    best = 0.0

    def walk(w, seen, total):
        nonlocal best
        best = max(best, total)
        for o in near[w]:
            if o in turn and o not in seen:
                walk(o, seen | {o}, total + turn[o])

    for w in ways:
        walk(w, {w}, turn[w])
    return best


def _redundant_ramps(decks, by_way, chains, recs, gone):
    """The ramp systems hyper takes out of decks, less the ways in gone."""
    live = {d["way"] for d in decks} - gone
    near = {w: set() for w in live}
    for w in live:
        for o in _linked(by_way[w]):
            if o in live:
                near[w].add(o)
                near[o].add(w)
    ramps = {w for w in live if by_way[w]["class"].endswith("_link")}
    parent = {w: w for w in ramps}

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    for w in ramps:
        for o in near[w] & ramps:
            parent[find(w)] = find(o)
    systems = {}
    for w in ramps:
        systems.setdefault(find(w), []).append(w)
    chain_of = {recs[r]["way"]: ci for ci, ch in enumerate(chains) for r, _ in ch}
    out, kept = set(), {}
    rows = []
    for ways in systems.values():
        # A loop goes however it is joined on.
        turn = _path_turning(ways, near, by_way)
        if turn >= LOOP:
            out |= set(ways)
            continue
        joins = [(w, o) for w in ways for o in near[w] - ramps]
        if len(joins) != 1:
            continue
        w, o = joins[0]
        d = by_way[w]
        at = ([r["at_s"] for r in d.get("merges", []) if r["into"] == o]
              + [r["at_s"] for r in d.get("splits", []) if r["from"] == o])
        if not at:  # a continuation, or joined only from the highway's side
            continue
        mid = np.concatenate([[[n["x"], n["z"]] for n in by_way[x]["nodes"]] for x in ways]).mean(0)
        exit_ = at[0] < d["nodes"][-1]["s"] / 2
        rows.append((turn, (chain_of.get(o, o), exit_), mid, ways))
    for turn, key, mid, ways in sorted(rows, key=lambda r: r[0]):
        if any(np.hypot(*(mid - m)) < INTERCHANGE for m in kept.get(key, [])):
            out |= set(ways)
        else:
            kept.setdefault(key, []).append(mid)
    return out


def simplify(decks, level):
    recs = _records(decks)
    by_way = {d["way"]: d for d in decks}
    chains, _ = _chains(recs)
    groups = _groups(decks, recs, chains)
    flattened, dropped = set(), set()
    for g in groups:
        ways = {recs[r]["way"] for r in g}
        ds = [by_way[w] for w in ways]
        outside = {w for d in ds for w in _linked(d)} - ways
        if any(d["class"] in HIGHWAY for d in ds) or outside:
            continue
        if max(n["h"] for d in ds for n in d["nodes"]) < STREET_LOW:
            flattened |= ways
    if level in ("aggressive", "hyper"):
        for ch in chains:
            ways = {recs[r]["way"] for r, _ in ch}
            if not all(by_way[w]["class"].endswith("_link") for w in ways):
                continue
            # Each chain end: its record, and which end of that record.
            ends = [(ch[0][0], 1 if ch[0][1] else 0), (ch[-1][0], 0 if ch[-1][1] else 1)]
            grounded = any(e not in recs[r]["joined"] and recs[r]["h"][-1 if e else 0] < GROUND for r, e in ends)
            twinned = any(t not in ways for w in ways for t in by_way[w].get("twin_of") or [])
            if not grounded and not twinned:
                dropped |= ways
    if level == "hyper":
        dropped |= _redundant_ramps(decks, by_way, chains, recs, dropped)
    out = []
    for d in decks:
        if d["way"] in dropped:
            continue
        d = dict(d)
        d["merges"] = [m for m in d.get("merges", []) if m["into"] not in dropped]
        d["splits"] = [s for s in d.get("splits", []) if s["from"] not in dropped]
        d["continues"] = [c for c in d.get("continues", []) if c["way"] not in dropped]
        if d.get("twin_of"):
            d["twin_of"] = [t for t in d["twin_of"] if t not in dropped] or None
        if d["way"] in flattened:
            d["nodes"] = [dict(n, h=0.0) for n in d["nodes"]]
        out.append(d)
    return out, sorted(flattened), sorted(dropped)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("inp")
    ap.add_argument("out")
    ap.add_argument("--level", choices=("moderate", "aggressive", "hyper"), required=True)
    ap.add_argument("--raw", help="the raw dir the decks were seeded from: with it, the ground stubs go too")
    a = ap.parse_args()
    if os.path.basename(os.path.normpath(a.out)) == "new_orleans":
        sys.exit("decks_simplify: refusing to write into data/blockouts/new_orleans")
    doc = json.load(open(os.path.join(a.inp, "decks.json"), encoding="utf-8"))
    decks, flattened, dropped = simplify(doc["decks"], a.level)
    stubs = sorted(_stubs(a.raw, dropped)) if a.raw else []
    km = lambda ways: sum(d["nodes"][-1]["s"] for d in doc["decks"] if d["way"] in set(ways)) / 1000.0  # noqa: E731
    print("decks_simplify: %s: %d records brought down to the ground (%.1f km), %d ramps taken out (%.1f km)"
          ", %d of %d left up, %d ground stubs left by them taken out"
          % (a.level, len(flattened), km(flattened), len(dropped), km(dropped),
             len(decks) - len(flattened), len(doc["decks"]), len(stubs)), flush=True)
    doc = dict(doc, decks=decks, simplified={"level": a.level, "flattened": flattened, "dropped": sorted(dropped + stubs)})
    with open(os.path.join(a.out, "decks.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(doc, f, indent=1)


if __name__ == "__main__":
    main()
