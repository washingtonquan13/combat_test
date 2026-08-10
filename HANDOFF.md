# Handoff: Ladder Traversal System

_Last updated: 2026-08-09_

You're picking up work on a Godot 4.4 (Forward+) tactics/combat game at
`C:\Godot Projects\combat_test`. Read this fully before making changes.

## Goal
Add a ladder mechanic letting grounded units climb between two vertically-
separated points (e.g. up to a rooftop) that the game's custom C++
NavigationGrid pathfinder can't cross on its own — without modifying the
NavigationGrid engine itself. Modeled conceptually on Unreal's
NavLinkProxy / Unity's NavMeshLink: a manually-placed connector that lives
outside the pathfinder's own graph.

## Current status: feature-complete and committed, NOT yet play-tested
on this latest fix. Working tree is clean on `main`. Four commits, in order:
1. `966f000` "Ladder system" — new `ladder.gd`/`ladder.tscn`,
   `Ladder.find_route()`, a 3-stage journey added to `unit_movement.gd`
   (walk to near end -> Tween climb -> walk to real destination),
   ladder-aware preview in `movement_indicator.gd`, one `Ladder` instance
   placed in `main.tscn` under `LevelGeometry/Ladder`.
2. `a0f54e8` "Update main.tscn" — trivial (removed stray `layers = 2` on
   the ladder mesh).
3. `8960722` "Ladder fixes" — fixed 3 real bugs found by the user's own
   play-testing (see "What to avoid" below).
4. `e7e6a34` "Update movement_indicator.gd" — preview now draws the real
   climb geometry instead of a straight line.

Key files: `ladder.gd`, `unit_movement.gd` (ladder journey logic, search
`_ladder_stage`), `movement_indicator.gd` (`_update_ladder_preview`).

This environment cannot run a live Godot window — everything so far is
verified by code reasoning plus the user's own manual play-testing (that's
literally how the 3 "Ladder fixes" bugs were found). Don't claim something
works in-game without the user confirming it.

## Key decisions (don't relitigate without a real reason)
- Ladders live entirely OUTSIDE NavigationGrid — no C++/grid changes.
  Stitched together in GDScript from two ordinary
  `NavigationGrid.find_path()` calls + a direct `Tween` for the climb.
- No collision shape on the Ladder node/mesh, ever —
  `NavigationGrid::collect_static_shapes` walks every `StaticBody3D` with
  no exclusion mechanism, so any collider makes the grid treat the ladder
  as solid and blocks the walk-up to it.
- Grounded units only. Flying units skip the ladder check entirely in
  `move_to()` — they don't need one.
- Climbing is atomic: never partial. Affordability
  (`move_remaining >= cost_to_near + required_move`) is a hard
  precondition checked identically in `Ladder.find_route()` (real move)
  and `movement_indicator.gd` (preview) — they must never disagree.
- `required_move` defaults to 0 (climbing is free). Set higher per-ladder
  only if a specific ladder should feel like a real commitment.
- Ladders are discovered via `get_tree().get_nodes_in_group("ladders")`.
  This project generally prefers native Godot mechanisms over hand-rolled
  scene-tree "group" patterns, but that preference is scoped to UI
  plumbing (drag-drop/tooltips/popups) — this is gameplay/pathfinding,
  deliberately modeled on Unreal/Unity's own nav-link-proxy pattern.
  Don't "fix" this without checking with the user first.
- AI units already get ladder routing for free — `combat_ai.gd` calls
  `unit.move_to()`, which contains the ladder branch. No separate AI
  integration exists or is needed for the movement itself. Open question,
  not a bug: whether the AI's own destination-selection logic would ever
  deliberately pick a spot on the far side of a ladder — untested either
  way.

## What to avoid — bugs already found and fixed, don't reintroduce
1. Never lerp straight from base->top (or near->far) for the climb
   animation or its preview line — a straight diagonal can cut through
   solid corners. Always go through `Ladder.climb_waypoints(base, top)`
   (straight up at the base's own XZ, then across at the top's height)
   and `.reverse()` it for a descent. Shared by the real Tween and the
   preview so they can't diverge.
2. Never validate climb-path clearance with grounded (`flying=false`)
   rules — every mid-climb sample point has nothing solid directly below
   it by construction, so grounded validity rejects every climb,
   including clear ones. Must call `NavigationGrid.nearest_valid_point`
   with `flying=true`.
3. Never use `max_radius_cells=0` (exact/no-snap) for that same clearance
   check — the horizontal step deliberately lands ON the landing
   surface's own top boundary, and a zero-radius check can misclassify
   that boundary cell as still-solid. Current code uses a small nonzero
   `SNAP_RADIUS_CELLS = 1`.
4. Don't let "already standing at the ladder's near point" fall through
   as a failure. It's the common case right after climbing up (the next
   thing a player often does is climb right back down from ~the same
   spot). Must be treated as a legitimate zero-cost leg straight into the
   climb stage — this was a real bug: units got permanently stuck
   mid-journey with no way to progress.
5. Don't recompute `climb_waypoints`' shape relative to "whichever
   direction is being traveled." Always compute base->top canonically
   and let the caller `.reverse()` for descents. Anchoring the vertical
   run at the wrong end's XZ plunges through solid geometry on the
   return trip.
6. Never add real physics collision to the Ladder node/mesh (see Key
   decisions above).

## Very next step
No further ladder work has been requested yet — the last action was
committing the preview fix (`e7e6a34`). The natural next step is
in-editor play-testing:
- Climb up, then immediately climb back down from the same spot (the
  exact scenario bug #4 fixes) — confirm it works live, not just in
  reasoning.
- Try a climb near a corner/inset landing platform (bugs #1-3) to confirm
  no visible clipping in either direction.
- Only one `Ladder` instance exists in `main.tscn`
  (`LevelGeometry/Ladder`) — consider placing 1-2 more in different
  geometry configurations (sharper corner, longer vertical run) to stress
  `_climb_path_is_clear`.
- Ask the user directly what they've already play-tested since
  `8960722`/`e7e6a34` rather than assuming — this codebase's recurring
  pattern is that real bugs here are found by actual play, not by code
  review.

If the user brings a new, unrelated task instead, treat all of the above
as background context only — don't force ladder work that wasn't asked
for.
