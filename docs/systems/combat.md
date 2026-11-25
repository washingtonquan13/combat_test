# Combat (CombatManager + Encounter)

**Files:** `systems/combat_system/` — `combat_manager.gd` (577), `encounter.gd` (631), `initiative_row.gd` (291), `end_turn_button.gd` (116), `line_of_sight.gd` (126), `damage_resolver.gd` (120), plus the body-plan and injury data classes (`body_plan.gd`, `body_row.gd`, `hit_location.gd`, `injury_preset.gd`, `injury_profile.gd`, `injury_rule.gd`; no section in this doc yet), `success_roll.gd` — `roll_vs` plus `chances(target)`, exact odds over all 216 rolls, cached, sharing `_outcome` with the roll. `combat_ai.gd` (180) is covered in `ai.md`.
**Autoloads owned:** `CombatManager` (project.godot:21)

## Purpose
Each fight is an `Encounter` Node. It owns its turn order, round counter, phase machine and current unit, and it starts, advances and ends turns (encounter.gd:61-125). `CombatManager` holds the set of encounters for each world. It picks the `focused_encounter`, relays encounter signals as global signals, and starts fights, adds units to them and restores them from saves (combat_manager.gd:35-146, 237-263, 360-383). It does NOT decide what an AI does (`ai.md`), resolve abilities or damage (unit/ability docs), compute paths (`navigation.md`), or own GameMode. The Encounter header forbids touching GameMode or reading CombatManager (encounter.gd:22-36).

## State it owns (source of truth)
| State | Where (file:line) | Persisted? (save key) |
|---|---|---|
| Encounters per world | `WorldContext.encounters`, read via `_encounter_list_for` combat_manager.gd:102-108 | yes, `[combat] encounters` via WorldManager.encounters_by_area world_manager.gd:1102-1114, save_manager.gd:356 |
| Encounters with no world loaded | `_detached_encounters`, combat_manager.gd:69-72 | no |
| `focused_encounter` | combat_manager.gd:113 | no (recomputed) |
| `turn_order` | encounter.gd:90 | yes, as unit ids (encounter.gd:145-162) |
| `_turn_index` | encounter.gd:116 | yes, `turn_index` |
| `round_number` | encounter.gd:94 | yes, `round` |
| `phase` (OUT_OF_COMBAT/TURN_STARTING/ACTIVE/TURN_ENDING) | encounter.gd:96-101 | no (set to ACTIVE on resume, 172-188) |
| `current_unit` | encounter.gd:106-110 | derived from index on resume |
| `_pending_delay_positions` | encounter.gd:117 | no |
| `_skip_first_action_for` | encounter.gd:125 | no |
| `_world` (owning world) | encounter.gd:114, `world_3d` 222 | implicit (save is per area) |
| Attention queue `_awaiting` | combat_manager.gd:473 | no |

## Derived / cached state
- `Unit.in_combat` and `Unit.is_my_turn` are read off the unit's encounter (unit.gd:897-903). These are fine as long as `_adopt`/`_release` keep `unit.encounter` in sync (encounter.gd:226-257).
- The `encounters` getter returns only the **focused** context's list (combat_manager.gd:69-72). `all_encounters` walks every context (85-94). `_find_by_id` searches only the focused context (289-298).
- NavigationGrid occupancy is live (62f265d4 "nav occupancy live"); Encounter no longer refreshes a snapshot at turn boundaries and no `update_occupancy` call is left in `encounter.gd`. See `navigation.md`.
- InitiativeRow and EndTurnButton rebuild from relayed signals (initiative_row.gd:43-46, 178-182; end_turn_button.gd:16-17, 89).

## Public surface
- **Calls in**
  - Starting fights:
    - `start_combat(units)` (combat_manager.gd:135-146) is called by the debug harness (debug_combat_harness.gd:45-47), by `start_combat_from_hostile_act` (160-173) and, as a third path, by area scripts that start a fight after a cutscene with a hand-made roster (world/goblin_quarry.gd:145, 271; see C-11 below). This is deliberate: POC story wiring in the area script (goblin ambush 6f345c96; raid 1515bdab, 14cb4ad9). It autosaves first when the player is involved (combat_manager.gd:147-148).
    - DetectionManager calls `start_combat_from_hostile_act` (detection_manager.gd:292-313).
  - Ending and delaying turns:
    - `end_turn(unit)` (185-188) is called by EndTurnButton (end_turn_button.gd:101-106) and by CombatAI (combat_ai.gd:65, 81, 102, 111, 132, 144, 148).
    - `delay_turn(unit)` (191-193).
  - Membership and lifetime:
    - `add_unit_to_combat` (199-226) is called by DetectionManager latecomers (detection_manager.gd:170).
    - `end_combat` (339-342).
    - `restore_combat(state)` (237-263) is called by SaveManager on area load (save_manager.gd:840-847).
  - Queries:
    - `combat_running_in_world_of` (275-286)
    - `running_encounter_in_world_of` (307-315)
    - `any_combat_running` (120-127)
    - `a_watched_fight_is_running` (437-443)
- **Signals out**
  - Encounter-local signals (encounter.gd:61-79). CombatManager also emits two named signals: `round_started_in(encounter, n)` (combat_manager.gd:58; surfaces age from it) and `encounter_finished(encounter, faction)` (:62; only Progression listens): `combat_started`, `turn_started`, `turn_ended`, `combat_ended`, `round_started`, `phase_changed`, `unit_joined_combat`, `unit_left_combat`.
  - CombatManager relays them through `_relay` (combat_manager.gd:35-42, 360-383):
    - `turn_started` from **every** encounter (362-365) reaches:
      - CombatAI (combat_ai.gd:39)
      - crpg_camera (crpg_camera.gd:276, 335)
      - SurfaceManager (surface_manager.gd:49-51, 168-176)
      - ability_hotbar (ability_hotbar.gd:56, 110-114, filtered by `_in_view`)
      - SelectionManager (selection_manager.gd:37, 43-47, filtered by context)
      - EndTurnButton, InitiativeRow
    - `round_started` **only from `focused_encounter`** (378-381). Goes to SurfaceManager (surface_manager.gd:159-165).
    - `combat_ended(faction)` for every encounter that ends (404). It reaches:
      - SurfaceManager (182-184)
      - FactionRelations (faction_relations.gd:58, 128-132)
      - InitiativeRow (initiative_row.gd:182)
      - ability_hotbar (130-139)
      - crpg_camera (347)
      - MusicManager (music_manager.gd:77)
    - `combat_ended_in_world` (53, 405) goes to DetectionManager (detection_manager.gd:65, 326-330).
    - `combat_started` goes to cinematic_cues (cinematic_cues.gd:39, 80-87).
  - `attention_changed` (47) goes to party_panel (party_panel.gd:122).
- **Signals in**
  - Each adopted unit's `died` and `downed_changed` (`_adopt` connects only these two, encounter.gd:237-246).
  - A ONE_SHOT `became_idle` while waiting for a busy unit (encounter.gd:349-351, 380-381).
  - `WorldManager.world_focused`, connected deferred, for attention (combat_manager.gd:476-491, 525-537).

## Depends on
- NavigationGrid occupancy is read live; Encounter calls no `update_occupancy` any more (62f265d4).
- Unit API:
  - `is_busy` (unit.gd:1022)
  - `reset_turn_actions` / `tick_statuses` (encounter.gd:468-470)
  - `is_hostile_to` (encounter.gd:553-572)
  - `became_idle` (unit.gd:477)
- `WorldManager` contexts and focus (combat_manager.gd:69-108, 446-457).
- `WorldContext.dispose` finishes encounters (world_context.gd:88-92).
- `UnitQuery.living_units` is used by aggro pull, `AGGRO_PULL_RADIUS` 10 (combat_manager.gd:59, 160-173).
- `LineOfSight.has_clear_shot` (line_of_sight.gd) and `SuccessRoll` (success_roll.gd) are static helpers that combat and detection share.
  - Units share physics layer 1 with walls. The LoS ray steps past any Unit it meets, so only the environment blocks a shot. Before this, every unit in the way blocked it.

## Assumptions and invariants
- Initiative is exact Basic Speed (fraction kept) descending, then DX (GURPS's own tie rule), then a d6 tiebreak rolled up front (encounter.gd `begin`; uncommitted). It is fixed for the whole fight; joiners are inserted by `add_unit` (268-288).
- Turns always advance deferred (encounter.gd:213, 361, 602-603). This is reentrancy-safe only if nothing ends the next turn in the same frame. Issue 1 breaks this.
- The round increments when `_turn_index` wraps to 0 (encounter.gd:456-458). Downed units skip their turn (485-489).
- A fight ends when no two remaining units are pairwise hostile (encounter.gd:553-572).
- Disengage: a unit leaves the fight beyond 25 m, or beyond 14 m with cover (encounter.gd:84, 88, 514-541).
- STALE — "one fight at a time". CombatManager's header says there are no global `in_combat`/`current_unit` accessors (combat_manager.gd:16-29). Several listeners still treat global `combat_ended` / `turn_started` as "the fight": issues 4-5.
- STALE — "no saving in combat". `can_save` now allows COMBAT (save_manager.gd:292-303). The doc comment above it (285-291) still says mid-combat saves are refused. FactionRelations relies on the same stale assumption (faction_relations.gd:135-139).
- Autoload order is solved with `call_deferred` registration in `CombatManager`, `FlagManager` and `FactionRelations` (combat_manager.gd:496-501, flag_manager.gd:41-42, faction_relations.gd:60), each with a comment saying so (C-15 below).
- STALE — "one focused world". `round_started` is relayed only for `focused_encounter` (combat_manager.gd:378-381), and `_find_by_id` searches only the focused context (289-298).

## Lifecycle
- **New game:** no encounters exist. Contexts are disposed with their worlds (world_context.gd:88-107), and `dispose` calls `finish` on each encounter.
- **Combat start:**
  - `start_combat` builds an Encounter and files it in the world's list (combat_manager.gd:135-146).
  - `begin` sorts initiative, emits `combat_started` and defers `_advance_turn` (encounter.gd:191-213).
- **Turn:**
  1. `_advance_turn` refreshes occupancy, then calls `reset_turn_actions` / `tick_statuses` (encounter.gd:419-491).
  2. `turn_started` fires.
  3. `end_turn` waits for idle, refreshes occupancy, fires `turn_ended`, tries disengage, then defers the next advance (341-361).
- **Combat end:**
  - `finish` stabilizes downed units, releases everyone and emits `combat_ended` (encounter.gd:312-326).
  - CombatManager then erases the encounter, refocuses, emits both end signals and calls `queue_free` (combat_manager.gd:386-406).
- **Save:** `Encounter.save_state` writes `{turn_order: ids, turn_index, round}` (encounter.gd:145-162). Units without a name are dropped with a warning (156).
- **Load:** on area load, SaveManager calls `restore_combat(state)` (save_manager.gd:840-847). It resolves ids, requires at least 2 units and 2 factions, then calls `resume` (combat_manager.gd:237-263; encounter.gd:172-188).
- **World travel:** encounters stay in their world's context. Attention moves with `world_focused` (combat_manager.gd:525-537).
- **Dialogue / cutscene:** combat has no gating of its own. GameMode decides what input reaches it (outside this doc).

## Known issues
| # | Issue | Evidence (file:line) | Status |
|---|---|---|---|
| 1 | A ONE_SHOT `became_idle -> end_turn` connection survives `_release` and death. Sequence: `end_turn` arrives while the unit is busy and connects (encounter.gd:349-351). The unit dies mid-busy, and `_on_unit_died` advances to the next unit (602-603). The corpse lives `death_cleanup_delay` (unit.gd:370; 2.0 s on unit.tscn per tests/combat/test_selection_is_a_node.gd:233). Its pending `end_busy` then emits `became_idle`, which ends the **next** unit's turn. Pending end_busy sources: unit_combat.gd:389-391, unit_movement.gd:303/340/611, move_caster_effect.gd:67, grant_flight_effect.gd:76. `_release` disconnects only died/downed/ability_used (247-257). The downed path is safe because no advance happens first (609-615). | encounter.gd:247-257, 349-351, 602-603 | FIXED: `_drop_turn_requests` disconnects both idle hookups on `_release` and at the top of every `_advance_turn` (no test) |
| 2 | Same leak for `delay_turn` through `_on_unit_idle_for_delay`. | encounter.gd:380-381, 388-392 | FIXED with 1 |
| 3 | `resume()` skips turn-start bookkeeping: no `update_occupancy`, no `reset_turn_actions` / `tick_statuses`, no downed skip. It emits `turn_started` straight away. | encounter.gd:172-188 vs 468-489 | CONFIRMED; review 11-15: still open (now encounter.gd:176-192; the "no `update_occupancy`" part no longer applies), see C-14 |
| 3a | On resume, a downed current unit gets `turn_started`. The skip exists only in `_advance_turn`. | encounter.gd:172-188, 485-489 | NEW |
| 3b | The saved `turn_index` refers to the full saved order, but it is applied to the list after missing or dead units are filtered out. One missing unit shifts who is current. | combat_manager.gd:238-242, 262; encounter.gd:172-180 | NEW |
| 3c | `_skip_first_action_for` and delay positions are not saved, so a joiner's skipped action is lost on reload. | encounter.gd:117, 125, 145-162 | NEW |
| 4 | `round_started` is relayed only from `focused_encounter`. Surfaces in other worlds, and in NPC-only fights (no player in the fight, so `focused_encounter` is null, 142-143), never age. | combat_manager.gd:142-143, 378-381; surface_manager.gd:159-165 | FIXED for surfaces (`round_started_in`, combat_manager.gd:58, :387-391; surface_manager.gd:82), confirmed by review 11-15. `round_started` stays focused-only for the HUD, by design |
| 5 | `turn_started` is relayed from every encounter. The camera follows units in any fight with no world filter (crpg_camera.gd:335), and SurfaceManager tests other-world units against focused-world surfaces (surface_manager.gd:168-176). | combat_manager.gd:362-365 | HALF FIXED: SurfaceManager now listens at surface_manager.gd:83 (whether it tests the unit's world is for the surf scope to confirm); the camera half is still open (crpg_camera.gd:376-377, 388-389); review 11-15, see C-7 |
| 6 | `combat_ended` fires per encounter, but listeners treat it as "all combat over". On any fight ending: FactionRelations clears **all** temporary hostility (faction_relations.gd:128-132), InitiativeRow `_clear_all` (initiative_row.gd:182), the hotbar disarms (ability_hotbar.gd:130-139), the camera nulls its focus (crpg_camera.gd:347), and focused surfaces expire (surface_manager.gd:182-184). DetectionManager correctly uses `combat_ended_in_world`. | combat_manager.gd:404-405 | CONFIRMED; review 11-15: still open (FactionRelations cite right; InitiativeRow and EndTurnButton now filter by world, initiative_row.gd:75-103, end_turn_button.gd:43-72), see C-7 and C-8 |
| 7 | cinematic_cues plays the **current** world's combat intro on any `combat_started`, even for a fight in another world. | cinematic_cues.gd:39, 80-87 | NEW; review 11-15: still open (same as cinematics.md #4) |
| 8 | `_on_unit_died` with no current unit calls `update_occupancy([])` with no world_ref. It then stamps whichever world the grid has active. | encounter.gd:582; navigation_grid.cpp:793-890 | FIXED (call removed with the occupancy snapshot, 62f265d4), confirmed by review 11-15 |
| 9 | The `can_save` doc comment says mid-combat saves are refused, but the body allows COMBAT. | save_manager.gd:285-291 vs 292-303 | NEW; review 11-15: still open (comment now at save_manager.gd:288-295) |

### Review 2026-11-15 (HEAD 14cb4ad9)
| id | Issue | Evidence | Cause | Sustainable fix | Root | Size | Status |
|---|---|---|---|---|---|---|---|
| C-7 | `turn_started`, `combat_started` and `combat_ended` are relayed without saying which fight, and "a fight ended" has three vocabularies (`combat_ended(faction)`, `combat_ended_in_world(world)`, `encounter_finished(encounter, faction)`). Every unnamed listener must re-derive scope itself; FactionRelations, crpg_camera and cinematic_cues do not. | combat_manager.gd:375-383, 414-416, 58, 62; initiative_row.gd:75-103; end_turn_button.gd:43-72; faction_relations.gd:128; crpg_camera.gd:376; cinematic_cues.gd:80 | Each named signal was added for one listener (detection, then progression acd94dff) and the old unnamed one was left; the header says the relays were kept so the ~26 connections would not have to learn about encounters. | Every relayed signal carries the encounter first (`turn_started(encounter, unit)`, `combat_started(encounter, order)`, `combat_ended(encounter, faction)`); listeners filter by `encounter.world_3d()` or `player_took_part`; drop `combat_ended_in_world` and `encounter_finished`. About 26 connections, mechanical. | R1 | L | BUG |
| C-11 | A third way into combat: area scripts call `start_combat` with a hand-made roster after a cutscene. It skips `start_combat_from_hostile_act` (no pull of same-faction units, no escalation, no `skip_first_action_for`) and works only because goblins are base-hostile and the watchman base-allied; a staged fight against a neutral cast would end in the same frame. `start_combat` also autosaves first, so the fight autosave is taken after the cutscene with the played flags already set. | world/goblin_quarry.gd:145, 271; detection_manager.gd:298-300; combat_manager.gd:144, 147-148 | 6f345c96 (the fight starts when the scene ends) and 1515bdab (the fight starts where the raid left it) each wrote the roster in the area script. | One public entry `CombatManager.start_staged_fight(cast_units, reason)` that escalates any non-hostile pair it is told to, runs the same join pull as the hostile-act path, and documents the autosave; a director beat calls it so area scripts stop building rosters. | R7, R4 | M | INTENTIONAL; document why: POC story wiring in the area script (goblin ambush 6f345c96; raid 1515bdab, 14cb4ad9) |
| C-12 | `focused_encounter` and `watched_fight()` answer "which fight is on screen" differently. `focused_encounter` is any fight with a player unit in any world, so an off-screen fight relays `round_started` to the HUD, and `end_turn()` with no unit (and `end_turn(unit)` for an already released unit, ai.md #10) ends that off-screen fight's current turn. | combat_manager.gd:156-157, 238-240, 408-411, 454-461, 201-204, 353-362, 389; debug_combat_harness.gd:57, 63 | The stored focus predates per-world encounters and was never reduced to the derived `watched_fight()`. | Delete the stored `focused_encounter` (make it a getter returning `watched_fight()`); `_encounter_for(unit)` returns `unit.encounter` or null with no fallback; `end_turn()` with no unit resolves through `watched_fight()`. | R1, R4 | M | BUG |
| C-13 | Encounter naming and restore lookup use the focused world. Names (`"Encounter%d" % (encounters.size() + 1)`) collide across worlds; `_find_by_id` searches only the focused context, so a save taken while the off-screen group fights loses that fight (returns null with a warning). Latent. | combat_manager.gd:151, 153, 268, 303-312, 260-262; save_manager.gd:870-883 | The `encounters` getter returns only the focused context's list. | Name from a monotonic counter; `restore_combat` takes the context (or resolves ids through `UnitQuery` across all resident contexts) and SaveManager saves fights per context. | R1 | S (naming), M (restore) | BUG (latent) |
| C-14 | `resume()` still skips turn bookkeeping, and fight state is saved partially: the index clamps on the filtered list, `_skip_first_action_for` is not saved, and the new `defeated_foe_levels` restarts empty after a load, so Progression pays only for kills after the load. Old parts are rows 3, 3a, 3b, 3c above. | encounter.gd:176-192, 184, 124-131, 241-242; progression.gd:86 | `Encounter.save_state` writes only order, index and round. | `save_state` writes the current unit id (not the index), `defeated_foe_levels` and the skip/delay state; `resume` goes through the same `_begin_turn(unit, continuing := true)` as `_advance_turn` so the downed skip lives in one place. | R2 | M | BUG |
| C-15 | Autoload order is solved by `call_deferred` registration in four places, with the same comment text copied each time. | combat_manager.gd:496-501; flag_manager.gd:41-42; faction_relations.gd:60 | SaveManager and WorldManager must exist before their clients push their registration. | Order the autoloads so dependencies come first, or have SaveManager/WorldManager pull (`get_nodes_in_group("persist")`) instead of clients pushing. | R5 | S | INTENTIONAL; document why: autoload order is dodged with `call_deferred`, and each place has a comment saying so (no commit named in the report) |
| CINE-3 | same as C-11 (combat.md): the same two call sites repeat "play, release camera, start fight" | goblin_quarry.gd:134-145, 255-271 | | | R4 | | see cinematics.md |

## Breakable props (breakable.gd, loot_pile.gd, prop_explosion.gd)
A `Breakable` is a child Node3D of a prop, such as a crate or a barrel. It makes the prop something you can hit and break, following BG3's rules with GURPS numbers. It is **not a Unit**: it has no turn, no stats and no defense, and the AI ignores it.
- **What it owns:** `hp`. On a MovableProp it is saved with the prop (`MovableProp.save_state` writes `hp` and the StashComponent's contents beside the transform), so a damaged crate stays damaged. On any other prop it is not saved.
- **Numbers:**
  - HP is 4 × the cube root of the weight in lb (B558). The weight comes from `weight_lb` or the MovableProp's weight.
  - `dr` comes from the material.
  - `injury_preset` is Unliving by default.
  - `vulnerable_to` doubles damage of those types after DR.
  - Every hit uses the torso row; there are no hit locations.
- **How it is hit:**
  - It is the `target` of `UnitCombat.use_ability`, the same path a unit goes through.
  - There is no active defense and no to-hit bonus against objects.
  - `DamageResolver.injury` takes a Unit or a Breakable, reading `dr` instead of the DR stat.
  - The damage effects pass a null hit location for a Breakable.
- **Breaking (0 HP):**
  - `AreaState.mark_removed`, keyed by the prop's persistent_id, so an authored prop stays broken.
  - It spawns debris: rigid bodies on Corpse.BODY_LAYER that freeze after 3 s and that the grid never sees.
  - Its StashComponent becomes a `LootPile`. The pile is spawned, so it is not saved and is lost on reload.
  - The prop leaves the tree, then `NavigationGrid.invalidate_region` re-bakes its box, then the prop is freed.
- **Spill and explosion (oil barrels):**
  - `spill` (a Surface, `spill_radius`) is laid where the prop stood when it breaks cold: a smashed oil barrel leaves grease.
  - `explosion` (a `PropExplosion`) makes it go off instead when fire breaks it. Fire is a FIRE-element ability that hits it (`UnitCombat._fire_reaches`: the target, or what an area or cone catches) or FIRE ground under it (`SurfaceManager._burn_breakables`). Either calls `heat()` before the damage and `ignite()` after it, so a barrel the fire did not finish still goes off.
  - `PropExplosion.detonate` burns every living unit in `radius` (dice through DR as an area hit, no to-hit, no defense, starts no fight), burns other props, and lays `leaves` (fire). An explosive prop it catches is not hurt: it goes off `CHAIN_DELAY` (0.35 s) later (`ignite` then heats it, so one whose world left the tree meanwhile is not left primed), so a row of barrels goes up one after another. The fire is laid on the ground, never on prop tops (`_burst_cells` looks for the floor through breakable props' bodies; its sight ray still stops at them, so a crate shadows the ground behind it). A blast's damage has no line-of-sight check, though its fire does. Two barrels caught by one fire spell, or standing in one burning patch, go off in the same frame. `_burn_breakables` reads who stands in what before burning anything, so fire a barrel lays there catches nothing until the next round. Known gap: that fire is aged in the same tick (`_age_grid` runs after), so it lasts a round less than a cast's. A broken prop's removal is recorded against the area it stands in (`WorldManager.area_of`), not the focused one.
  - Props: `systems/interaction_system/props/` crate, barrel (both hold loot, `loot_rolls` 2, weak to burning) and oil_barrel (`data/explosions/oil_barrel.tres`, 3d6 burning, 3 m). Placed in goblin_quarry by the MovableBox.
- **Signals out:** `damaged(amount)` and `broken`.
- **Found by:** the "breakables" group, or `Breakable.of(node)`.

## Tests
- tests/interaction/test_props_break.gd (Breakable: HP from weight, attack lands, blast catches, DR, break leaves debris, a crate saves its loot and damage)
- tests/interaction/test_oil_barrel.gd (cold break spills grease; ignite burns a unit and a crate, leaves fire, sets off the next barrel a beat later)
- tests/combat/test_encounters.gd (multi-encounter, world scoping; also :224 detection join)
- tests/combat/test_downed.gd
- tests/combat/test_commanding.gd
- tests/combat/test_mode_is_derived.gd
- tests/combat/test_selection_is_a_node.gd
- tests/world/test_persistence.gd — `_a_fight_resumes_where_it_was_left` at 247-334: identity, is_running, current_unit

**Gaps:**
- Nothing covers death during a busy `end_turn` wait (issue 1) or delay (issue 2).
- Nothing resumes with a missing unit (3b) or a downed current unit (3a).
- Nothing checks that `round_started` is emitted only for the focused fight (4).
- Nothing checks listener behaviour when one of two concurrent fights ends (6).
