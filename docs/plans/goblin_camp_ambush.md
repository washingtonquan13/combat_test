# Goblin camp ambush: triggered cutscene, new allied NPC, fight after

Reviewed against the code on 2026-11-11 (branch `pinst-prototype`). Nothing was run; every claim below is from reading the files named.

## Goal

When the party first walks up to the goblin camp in the Old Quarry (`world/goblin_quarry.tscn`), a cutscene plays: the goblins notice the party, a new NPC arrives, a few lines are spoken. When the cutscene ends (played through or skipped) a fight starts with the party and the NPC on one side and the camp goblins on the other. The NPC is AI-driven, never joins the party, and plays once per game.

## Rules for whoever builds this

- `.tscn` and `.tres` files have no comment syntax. Do not write `#` or `##` lines into them; a comment silently breaks the file.
- Close the Godot editor to the Project List before editing any `.tscn` outside it. An open editor writes its stale cached copy back over external edits.
- Edit GDScript with an Edit tool (exact string replacement), not `sed` line insertion.
- Do not `git checkout -- <file>`, `git stash` or `git reset`; the tree holds uncommitted user work.
- Tests come last and stay few (section 5). The user tests gameplay by hand; do not drive gameplay through the Godot MCP.

## 1. Findings: what the draft had right, wrong, and missing

### Confirmed

| Draft claim | Evidence |
|---|---|
| `entry_scene` / `combat_intro_scene` are the wrong hooks | `systems/world_system/game_area.gd:51-54`; `systems/cinematic_system/cinematic_cues.gd:57-87`: entry plays on first arrival in the area, combat intro plays on `combat_started`, after the fight already exists |
| Set the flag before playing | Same pattern and reason at `cinematic_cues.gd:70-74` |
| `cast.track_unit(...)` | Exists: `systems/cinematic_system/scene_cast.gd:60`. `track(role, resolver)` at line 52 is the general form; `track_unit` wraps it. The guide and `cinematic_cues.gd` do not conflict |
| `await CinematicDirector.play()` returns false on abort, true on finish or skip; caller releases the camera on true | `systems/cinematic_system/cinematic_director.gd:112-165`; `cinematic_cues.gd:92-102` |
| NPC must be authored in the area scene, not a SpawnBeat | A combatant without `persistent_id` is dropped from a saved fight (`systems/combat_system/encounter.gd:149-160`), and AreaState reconciliation only walks authored nodes (`systems/world_system/world_manager.gd:807-846`). Retry after a loss would bring the fight back without the ally |
| New faction must be in `CombatAi.ai_factions` | `systems/combat_system/combat_ai.gd:26,43`: a turn for a faction not in the list is driven by nobody and the fight stalls |
| DetectionManager does not know about cutscenes | No `CinematicDirector` reference anywhere in `systems/detection_system/detection_manager.gd` |
| Aggro pull is same-faction, 10 m | `systems/combat_system/combat_manager.gd:174-187` |

### Wrong

1. **`CombatManager.start_combat(roster, hobgoblin)` costs the hobgoblin its first attack.** The second parameter is `skip_first_action_for`, not an initiator (`combat_manager.gd:144`, `encounter.gd:129-135`). Call `start_combat(roster)` with one argument, and `roster` must be typed `Array[Unit]`.

2. **"Set the NPC's faction relation after the cinematic" is too late.** An unlisted faction pair is HOSTILE (`systems/faction_system/faction_relations.gd:91`). From the moment the area loads, the NPC is a detection observer (`detection_manager.gd:100-121`), and `_react_to` (`detection_manager.gd:295-316`) starts a fight when a hostile observer notices a party member. The parked NPC would attack the party, draw a red enemy ring (`systems/unit_system/unit_selection.gd:542-547`) and count as a threat for combat music (`systems/music_system/music_manager.gd:129-144`). The relation has to be true before the area exists.

3. **A relation set at runtime does not survive every load.** `FactionRelations.load_state` replaces the whole table with the save's `"base"` (`faction_relations.gd:161-164`). Every existing save already has a `"base"` key (an empty one), so seeding `_base` in `_ready()` alone still loads those saves with the pair missing, which is HOSTILE. Root cause: the saved table is treated as the complete table instead of as changes on top of the authored one. Fix in step 1.

### Missing

4. **Latecomer join pulls the NPC in by itself.** `_draw_in_latecomers` (`detection_manager.gd:138-177`) adds any unit hostile to a combatant within `HEARING_RADIUS` (22 m). If the player starts the camp fight some other way (ranged attack from outside the trigger, the ladder at the west side, the cave exit), an NPC parked within 22 m of it joins with no introduction. Parking distance matters (step 4).

5. **Detection must be gated for the whole cutscene, not avoided by zone placement.** WalkTo beats move goblins toward the party in real time (`systems/cinematic_system/beats/walk_to_beat.gd:79-90`), so they end inside sight range (18 m, `data/units/demons/hobgoblin.tres:41`) however far away the zone is. Without a gate a goblin's notice roll starts a fight mid-cutscene through `start_combat_from_hostile_act`.

6. **Party members keep walking.** Input is blocked in CUTSCENE (`systems/camera_system/camera_director.gd:55-58`), but a move order given before the trigger keeps running; nothing in the cinematic system calls `stop_moving()`. The handler must stop the party (`unit.gd:1278`).

7. **The trigger can fire into a situation the cutscene cannot stage.** A goblin already dead or already fighting, a party member already in a fight, a conversation open. The handler needs preconditions, and when they fail it must leave the flag unset.

8. **The roster should not be "the party".** `start_combat` adopts every unit it is given, wherever it stands. A member left behind in town would be put into a fight 60 m away. Give it the party members near the trigger; the latecomer rule (finding 4) brings the others in when they walk up.

9. **Winner reporting is cosmetic but visible.** `_check_combat_end` reports `winners[0].faction` in turn order (`encounter.gd:588-590`), so the log can read "townsfolk wins", in the enemy colour (`systems/log_system/log_format.gd:21`). XP is unaffected: `Progression` asks whether the winner is hostile to the player (`systems/progression_system/progression.gd:83-87`) and `player_took_part` is set by the party being in the fight (`encounter.gd:241`). Left as an open decision.

### Checked and fine (no work needed)

- **Fight end with a third faction.** Pairwise hostility, not two sides (`encounter.gd:572-591`). Party + ally vs goblins ends when the last goblin dies. If the NPC dies the fight carries on.
- **Game over.** `PartyManager.is_defeated()` counts party members only (`systems/party_system/party_manager.gd:296-305`); when the party is all Downed the game over screen ends the fight even if the NPC still stands (`ui/game_over.gd:40-69`). Correct behaviour.
- **AI targeting.** Every target query goes through `is_hostile_to` (`systems/ai_system/ai_scorer.gd:288,880,930` and the behaviours). A townsfolk unit targets goblins and never the party; goblins target both. Area abilities use `attacker.is_hostile_to` for the ally/hostile split (`systems/unit_system/unit_query.gd:185-189`, `systems/ability_system/cone_targeting.gd:120-124`).
- **Friendly fire in the fight.** `_maybe_trigger_combat` returns early for a unit already in combat (`systems/unit_system/unit_combat.gd:1289`), so a party area spell that clips the NPC during the fight does not turn townsfolk hostile. Attacking the NPC outside combat does, until that fight ends; that is the existing rule for any non-hostile unit.
- **Rings and outlines.** A non-player ally draws the NEUTRAL colour, by design (`unit_selection.gd:537-547`). The NPC cannot be selected (`unit.gd:1188-1189`).
- **Saving.** Refused while a cutscene runs (`systems/save_system/save_manager.gd:296-310`, mode is CUTSCENE). `start_combat` writes the fight autosave after the cutscene (`combat_manager.gd:147-148`); `play()` clears its running state before returning (`cinematic_director.gd:163`), so that save is allowed. It holds the flag, every named unit's transform (`unit.gd:2364-2376`) and the turn order by `persistent_id`. Faction is not in a unit's saved state, which is right: it comes from the definition.
- **Other systems during a cutscene.** There is no ambient AI, patrol or bark system in `systems/`. CombatAi only acts on a turn. Detection is the only world-reaction system that needs the gate.

## 2. Build steps

### Step 1. Author the `townsfolk` faction (code, no scenes)

Files:
- `systems/faction_system/faction_relations.gd`
- `systems/combat_system/combat_ai.gd`

Changes:
- In `FactionRelations._ready()`, before the `_authored_defaults = _base.duplicate()` line (line 59), seed `_base[_pair_key(&"townsfolk", Unit.PLAYER_FACTION)] = Tier.ALLIED`. Write `_base` directly rather than calling `set_relation`, so no signal fires during boot. The header comment at lines 44-53 already names this as the place for authored relations.
- In `load_state` (line 163), build the new table as `_authored_defaults.duplicate()` and then `merge(state.get("base", {}), true)`, so a save overrides authored pairs it mentions and keeps authored pairs it does not. This is the cause fix for finding 3. Update the comment above it, and the stale comment at lines 135-139 that says saving is never allowed in combat.
- In `combat_ai.gd:26`, add `&"townsfolk"` to the `ai_factions` default.

Leave townsfolk-enemy unlisted: it defaults to HOSTILE, which is what is wanted. Townsfolk-neutral is NEUTRAL through the existing wildcard.

Done when: `FactionRelations.is_hostile(&"townsfolk", &"player")` is false on a new game, after `load_state({})`, and after `load_state({"base": {}})`; and is true for `(&"townsfolk", &"enemy")`.

### Step 2. Gate detection while the director holds the scene

File: `systems/detection_system/detection_manager.gd`

At the top of `scan()` (line 80), return when `CinematicDirector.is_active()`. `scan()` and not `_physics_process`, because `scan()` is public and is the one entry for both the notice sweep and the latecomer join. Autoload order is safe: CinematicDirector is created before DetectionManager (`project.godot` lines 42, 45).

Root cause: detection decides what the world does about the player, and it has no notion that the director currently owns what the world does.

Done when: with a cutscene running, a goblin moved next to a party member starts no fight and builds no awareness; one scan interval after it ends, detection behaves as before.

### Step 3. The NPC definition

New file: `data/units/npcs/quarry_watchman.tres` (copy the shape of `data/units/demons/hobgoblin.tres`; `data/units/npcs/townsperson.tres` is the minimal form).

Proposed placeholder, fitting the "Raiders at the Gate" quest given by the Scared Townperson at the town edge:

- `id = "quarry_watchman"`, `display_name = "Town Watchman"`
- `faction = &"townsfolk"`
- `model_scene = res://scenes/character_models/placeholder_model.tscn` (what every humanoid uses today)
- `unit_scene = res://systems/unit_system/unit.tscn`
- `abilities = [res://data/abilities/basic_attack_melee.tres]`
- `equipment = {12: res://data/items/iron_sword.tres}` (12 is the main-hand melee slot the hobgoblin uses)
- `ai_archetype = res://data/ai_archetypes/brute.tres`
- `stats` around `{ST 12, DX 12, HT 12}`, `level = 1`, `move_speed = 4.0`
- `portrait_texture`: reuse an existing portrait under `assets/portraits/`
- `negotiable = false`, no `dialogue_options`

A UnitDefinition needs nothing else: `Unit.definition`'s setter copies faction, stats, abilities, AI and vision onto the unit (`unit.gd:21-61`).

Done when: the file loads in the editor with no errors and shows the fields above.

### Step 4. Place the NPC, the marks and the trigger in the area

File: `world/goblin_quarry.tscn`. Close the editor to the Project List first, or make these edits inside the editor. No comments in the file.

Add:
- **`Watchman`**: instance of `res://systems/unit_system/unit.tscn`, `definition` = the step 3 file, `persistent_id = &"goblin_quarry_watchman"`. Parked on walkable ground more than 22 m from every camp goblin (they stand at z -45.5 to -57.5) and off the road the party walks. Suggested: behind the cart near (3.5, -1.9, -2), facing north.
- **Marks**: `Marker3D` nodes in group `scene_marks` (the pattern at `world/cathedral_of_shadows.tscn:44-53`), -Z facing the way an actor should look:
  - `CampAmbush`: the stage anchor, at the spot where the party will be standing
  - `AmbushHobgoblin`, `AmbushRogue`, `AmbushShaman`: where each goblin ends, 6 to 8 m in front of `CampAmbush`, each on a straight unobstructed line from where that goblin stands now (WalkTo does not path-find, `walk_to_beat.gd:8-15`)
  - `AmbushWatchmanEnter` (out of shot, behind the party) and `AmbushWatchmanStand` (beside the party, 2 m clear of `CampAmbush`)
- **`CampAmbushTrigger`**: `Area3D` with one `CollisionShape3D` (a box across the road). Default layer and mask are fine; units are `CharacterBody3D` on layer 1 (`systems/unit_system/unit.tscn:13`). Place it about 22 m from the nearest goblin, around z -24 on the road between `LowWall` (z -14) and the camp crates (z -41). Farther than sight range (18 m) so the party normally reaches it unseen; if they are seen first the fight simply starts without the cutscene (step 6 preconditions).

Done when: the area opens in the editor without errors, the watchman stands idle at his parking spot in play, shows a neutral-colour ring on hover, does not react to the party, and the goblins behave as before.

### Step 5. The stage

New file: `cinematics/goblin_camp_ambush.tscn`. In the editor run `tools/new_cinematic.gd` (File > Run), which creates `res://cinematics/new_cinematic.tscn`; rename it. Follow `systems/cinematic_system/CINEMATICS.md`; `cinematics/demo_conversation.tscn` is the reference.

- Stage: `anchor_mark = &"CampAmbush"`; `world_marks` lists the six marks from step 4.
- Roles: `leader`, `hobgoblin`, `rogue`, `shaman`, `watchman`. All are tracked by the caller, so none drives its actor.
- Shots: `camp_wide` (subject hobgoblin), `hobgoblin_close`, `watchman_close`.
- Timeline `scene`, one Call Method track per beat, callback mode Immediate:
  1. `camp_wide`. WalkTo for the three goblins to their marks.
  2. `hobgoblin_close`. LineBeat for the hobgoblin (waits for advance).
  3. PlaceBeat `watchman` at `AmbushWatchmanEnter`, then WalkTo `AmbushWatchmanStand`; `watchman_close`. LineBeat for the watchman.
  4. `camp_wide`. FaceBeats so both sides face each other. Short LineBeat with `wait_for_advance` off and `auto_seconds` set, as the charge bark.
- Keep it under about 20 seconds. Skip must leave everyone on their end marks, which WalkTo and PlaceBeat already do (`walk_to_beat.gd:110-117`).

Line text is placeholder; see open decision 2.

Done when: the stage previews in the editor with no configuration warnings.

### Step 6. The trigger handler

File: `world/goblin_quarry.gd` (Edit tool).

In `_ready()`, connect `$CampAmbushTrigger.body_entered` to a handler. The handler, in order:

1. Return unless `body is Unit` and `body.is_player_controlled()`.
2. Return if `FlagManager.has_flag("goblin_camp.ambush_played")`.
3. Preconditions; on any failure return and leave the flag unset so a later entry tries again:
   - `GameMode.current_mode() == GameMode.Mode.EXPLORATION` (no cutscene, conversation, loot screen or watched fight)
   - `Hobgoblin`, `GoblinRogue`, `GoblinShaman` and `Watchman` all resolve with `get_node_or_null`, are alive and are not `in_combat()`. Dead ones are already freed by reconciliation, as the existing quest watcher notes (`goblin_quarry.gd:18-21`)
   - the entering unit is not `in_combat()`
4. `FlagManager.set_flag("goblin_camp.ambush_played")`.
5. Collect the nearby party: `PartyManager.group_of(body).live_units()`, kept if alive, not in combat and within 22 m of `body`. Call `stop_moving()` on each.
6. Build the cast: `track_unit(&"leader", body)` and one `track_unit` per goblin and for the watchman.
7. `var finished: bool = await CinematicDirector.play(STAGE, cast)`. If false, return: the director has already released everything and something else owns the screen.
8. Release the camera: `var camera := CinematicDirector.camera()`, and `camera.release()` if it is not null (it is null headless).
9. Build `var roster: Array[Unit]` from the nearby party, the three goblins and the watchman, re-checking each is still valid, alive and not in combat. `CombatManager.start_combat(roster)`, one argument.

Preload the stage as a const. Keep the handler in this script; it is one area's one moment and does not justify a reusable trigger system yet.

Done when (manual): walking into the zone plays the scene once, the fight starts only after it ends, the watchman takes AI turns against goblins, and walking through the zone again does nothing.

### Step 7. Tests, last

See section 5.

## 3. Edge cases and how the steps cover them

| Case | Result |
|---|---|
| Party seen before reaching the zone, or fight started from another direction | Fight starts normally. Zone entry fails preconditions, flag stays unset, no cutscene. Watchman joins by hearing only if the fight comes within 22 m of him |
| A goblin killed earlier (stealth kill, earlier visit) | Preconditions fail forever; the cutscene never plays. Open decision 3 |
| Party split, one member far away | Not in the roster; joins by the latecomer rule on approach |
| Player skips | Counts as finished; end state applied; fight starts |
| Load of a save from before the trigger | Flag unset, everything replays |
| Retry after losing (fight autosave) | Flag set, units on their end marks, fight restored with the watchman by `persistent_id` |
| Save mid-fight, save after the fight | Watchman's position, HP and death persist through AreaState. Faction and relation come from the definition and step 1, not the save |
| Save from before this feature existed | Step 1's merge keeps townsfolk allied |
| Watchman dies | Marked removed for the area like any named unit (`systems/unit_system/unit_death.gd:68-69`); fight continues |
| After the fight | Watchman stands where the fight left him, neutral ring, nothing to say. Open decision 4 |

Not covered, by choice: the quest watcher in `goblin_quarry.gd:22-35` resolves the quest on the rogue and hobgoblin only, not the shaman. Existing behaviour, outside this feature; raise it with the user rather than changing it here.

## 4. Open decisions for the user

1. **Who the NPC is.** Recommendation: "Town Watchman", sword, placeholder model, as in step 3. Cheap to rename later; only the `.tres` and the stage lines change.
2. **The lines.** Recommendation: the builder writes three short placeholder lines (hobgoblin threat, watchman arrival, charge bark) and the user rewrites them in the editor.
3. **Cutscene when a camp goblin is already dead.** Recommendation: no cutscene, as built. A variant stage for a partial camp is content for later.
4. **The watchman after the fight.** Recommendation: leave him standing for now. A thank-you dialogue or walking back to town is a follow-up, and a dialogue root can be added to his definition without touching this work.
5. **Approaches that bypass the zone.** Recommendation: accept that a player who flanks by the ladder or the cave gets a plain fight. Making detection itself raise the cutscene is a system change, and the current direction is content before systems.
6. **"townsfolk wins" in the log, in the enemy colour.** Recommendation: leave it. If it bothers in play, the fix is in `Encounter._check_combat_end` (prefer a player-faction unit among the standing winners) and `LogFormat.faction_name` (colour by relation to the player), two small changes with their own check.
7. **Should the Scared Townperson also be `townsfolk`?** Recommendation: no. She is `&"neutral"` so that she stays out of fights; changing her faction would make her join any goblin fight within 22 m.

## 5. Verification

Manual, by the user, in a new game:
1. Walk north past the cart: the watchman is idle, neutral ring, ignores the party.
2. Walk into the zone: cutscene plays; no fight starts during it; clicks do nothing.
3. Cutscene ends: camera returns, fight starts, initiative row shows party, three goblins and the watchman; the hobgoblin can attack on its first turn.
4. Watchman attacks goblins on his turns and the turn passes without stalling.
5. Win: fight ends when the last goblin dies; XP is awarded; the quest flag behaves as before.
6. Reload the fight autosave: fight resumes with the watchman in it. Walk through the zone after the fight: nothing happens.
7. Repeat once pressing skip during the cutscene.
8. Repeat once attacking the camp from the ladder side: plain fight, no cutscene, no errors.

Automated, after the above works, two small scene tests under `tests/` (run with `bash tests/run.sh`):
- `tests/detection/`: with `CinematicDirector` active, `DetectionManager.scan()` starts no fight for a hostile observer standing next to a party unit; after it ends, it does. Sabotage check: remove the step 2 guard and confirm the test goes red.
- `tests/combat/`: `FactionRelations.load_state({"base": {}})` leaves townsfolk-player not hostile, and a three-faction encounter (player, townsfolk, enemy) ends when the last enemy dies. Save and restore `CombatAi.ai_factions` if the test touches it, as the existing tests do.

Mind the headless gotchas already on record: a new `class_name` needs a rescan before the suite sees it, and lambdas capture locals by value.
