# Combat AI regression suite

```bash
"D:/PortablePrograms/Godot_v4.4.1-stable_win64.exe/Godot_v4.4.1-stable_win64_console.exe" --path . --headless res://tests/test_runner.tscn
```

Or `tests/run.sh` from the project root, which is the same command with the
path filled in. Exits **0** when everything passes and **1** on any failure,
so it can be wired into a hook or CI without parsing output.

## Adding a test

Drop a file in `tests/ai/` that extends `AiTestCase` and overrides `run()`.
The runner discovers it by scanning the directory — nothing to register.

```gdscript
extends AiTestCase

func run() -> void:
    var avian: Unit = spawn_demon("avian", Vector3.ZERO)
    var brute: Unit = spawn_brute(1.0)
    check("it does the thing", AiScorer.best_plan(avian) != null)
    free_spawned()
```

`AiTestCase` gives each case a fresh scene root, a ground plane, and
fixtures (`spawn_demon`, `spawn_brute`, `spawn_unit`, `behavior_of`,
`score_proposals`, `best_baseline_attack_score`). Use `check()` /
`check_equalf()` to assert.

## Three things that will bite you

**Run it as a scene, never as an autoload.** The old convention here was a
temporary `verify_*.gd` wired in as the last autoload and deleted after.
That wiring lives in `project.godot`, and a suite that isn't cleaned up
perfectly leaves a line behind that breaks the game on launch — which
happened during this system's development. A scene has no such coupling.

**A test scene has no NavigationGrid until you ask for one.** It's an
engine singleton that rasterises the current scene lazily, so it otherwise
holds whatever the last scene built, or nothing. `AiTestCase.setup()` calls
`NavigationGrid.invalidate()` after placing the floor. Skipping that
segfaults the whole process — not an error, a signal 11 — the first time
anything plans a route.

**A sub-test that `await`s must be `await`ed by `run()`.** Call it bare
and it returns a coroutine, `run()` carries on, and it resumes later into
a world where a subsequent case's teardown has already freed its units.
The failure looks like "previously freed" errors in a test that reads
fine.

**`queue_free()` is deferred, so tear down for the NEXT case, not just
this one.** `AiTestCase` removes units from the "units" group immediately
for exactly this reason — a ghost in that group is still returned by every
`UnitQuery` scan for the rest of the frame, and a detection test duly had
its observer identify a *previous* case's intruder. Anything else a case
builds (a wall, say) has to leave the tree the same way, or the next case
places its units inside it.

**Never `free()` a Unit; `queue_free()` it.** A Unit registers with the
NavigationGrid extension and wires components to autoloads. Tearing one
down synchronously mid-frame crashes the process once enough cases run
together. `AiTestCase` handles this, but it's the same rule the game
itself follows.

The ground plane is load-bearing, not scenery: `AiScorer` raycasts
downward to price landings and falls. Without a floor those queries report
"nothing below," every descent looks free, and the flight tests pass for
entirely the wrong reason.

## What's covered

| Suite | Guards |
|---|---|
| `test_behavior_contract` | propose-never-price; `movement_intent`; no authored bias above the ceiling |
| `test_archetypes` | all 8 roles load; the cascade onto a live Unit; every demon with abilities has a role |
| `test_behaviors` | each behavior on the situation it exists for |
| `test_flight_decisions` | every flight bug that reached a player, as a named regression |
| `test_scoring` | threat/kill value, tie-breaking, positional value, adopt-restore |
| `test_turn_economy` | a free action must not cost the turn |
| `test_encounters` | fights as instances; a unit outside one is free; GameMode refcounting |
| `test_world_scoping` | two live World3Ds prove cross-world isolation; WorldContext lifetime |
| `test_detection` | sight cone, line of sight, what starts a fight and what doesn't |
| `test_join_leave_combat` | hearing a fight joins it; escaping one leaves it |
| `test_sight_cone_indicator` | the drawn cone agrees with the cone detection rolls against |
| `test_detection_perf` | a detection sweep stays inside its budget |

Every check in `test_flight_decisions` is a bug someone actually saw. The
comments say which — keep that habit; it's what makes a failure legible a
year from now.

## Known noise

Runs intermittently print one or two `!is_inside_tree()` / `data.tree is
null` engine errors during teardown, and always `19 resources still in use
at exit` (which predates this suite — it happens on a bare game boot too).
Neither has ever changed a result: the check count and pass/fail are stable
across repeated runs. Worth fixing if it ever masks something real, not
worth chasing before that.

## Not covered

The AI scorer's performance (still unprofiled — `score_position` fans out
over every hostile and fires a raycast, once per candidate; detection IS
measured, see `test_detection_perf`), and anything requiring a real
multi-turn fight. `CombatAI`'s turn flow is asserted by
reading its source, which catches deletion but not subtler breakage.
