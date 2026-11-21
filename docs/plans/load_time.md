# Area load time: findings, saved for later

Measured 2026-11-21. Goblin Quarry, windowed, on the real path
(`WorldManager.travel_area` → `load_area`), first trip in a session. Nothing
here is built yet.

## Where the time goes (~8.6 s to enter the area, plus ~5 s at startup)

| Phase | Time | Main costs |
|---|---|---|
| Startup | ~5.0 s | The bare engine takes 1.0–1.6 s; the rest is GDScript compile pulled in by the autoloads (93k lines) |
| Load | ~3.7 s | `terrain.scn` 0.74 s; the 7 animation .tres files ~1.1 s; `goblin_quarry.gd` compile 0.22 s; CC/townsperson model files ~0.35 s; portraits 0.15 s |
| `load_area` | ~4.0 s | Character models ~2.3 s; nav grid bake 0.69 s; instantiate + `_ready` ~0.5 s |
| First frame | ~0.9 s | Probably shader/pipeline compile |

What `terrain.scn` holds:

| Content | Size |
|---|---|
| MultiMesh instances | 279k (22 MB buffer) |
| Concave collision faces | 419k |
| Mesh vertices | 1.33M |
| File size | 43 MB compressed |

Uncompressed it is 98.5 MB and loads only slightly faster, so not worth it.

First-time cost per CC body type, from `cc_look.gd` `_ready` (a second
character on the same body costs about nothing):

| Body | Load body scene | `fix_shape_tangents` | Materials | Hair |
|---|---|---|---|---|
| Female | 1.25 s | 0.42 s | 0.19 s | 0.21 s |
| Male | 0.26 s | 0.42 s | 0.13 s | 0.19 s |

## Candidate fixes, ranked

1. Load the CC body scenes with the area, behind the fade, instead of in
   `CharacterPreset.make_body()` at runtime. Saves ~1.25 s. First find out what
   dominates the female body's 1.25 s.
2. Fix the blend-shape tangents at import, or bake them once, instead of
   rebuilding them on the CPU every run (`CCMaterials.fix_shape_tangents`). This
   fixes the cause, the bad FBX import tangents. Saves ~0.4 s per base.
3. Save the nav grid to disk and rebake it only when the area changes, instead
   of baking it in `WorldContext.new`. Saves ~0.7 s.
4. Find out why hair costs ~0.2 s even when it should come from the baked
   cache (`attach_hair`), and whether the cache is being missed. Up to ~0.4 s.
5. Check whether the animation libraries stay cached between trips. If they are
   reloaded, keep them loaded: ~1.1 s per trip after the first. Converting them
   to .res is DECLINED for version-control reasons.
6. Terrain: simpler collision for ground nobody walks on, and a look at the
   instance count. The biggest single item; needs a closer look first.
7. First frame, 0.9 s: shader compiling. Look at it last.
8. Startup GDScript compile is engine cost. It shrinks only if the autoloads
   pull in less code.

Items 1–4 should cut entering the area from ~8.6 s to ~5.5 s. Second-trip
(warm) timings are not measured yet.

## Probes (in `tools/_probe`, never committed)

- `area_load_probe.tscn -- goblin_quarry`: the real load path, with time
  charged to each gap between nodes
- `load_deps.gd`: time to load each dependency
- `cc_body_probe.tscn`: the CC body setup, step by step
- `terrain_census.gd`: what `terrain.scn` holds
