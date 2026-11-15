# Party

**Files:** `systems/party_system/` — `party_manager.gd` (1112, autoload), `party_group.gd` (119, RefCounted), `party_member_data.gd` (85, Resource record), `party_skill_record.gd` (11), `starting_party.gd` (94, new: `StartingParty.bootstrap` builds the new-game party, called from three area scripts). Party-side halves of travel live in `systems/world_system/world_manager.gd` (`_disembody` :405-427, `_embody_into` :470-499).
**Autoloads owned:** `PartyManager`.

## Purpose
Owns who is in the player's party, how it is split into groups (embodied in a world vs abstract records), who leads, and the party's save/restore and spawn-from-record paths. It is NOT responsible for the Unit's own runtime state (HP, statuses, turns: see unit.md), for summoned demons (DemonRoster; `add_member` refuses summons, party_manager.gd:235), for inventory contents (PartyManager holds the bag as `inventory`, but its rules are inventory.md's), or for deciding when travel happens (WorldManager).

## State it owns (source of truth)
| State | Where (file:line) | Persisted? (save key) |
|---|---|---|
| Groups (list of PartyGroup) | party_manager.gd:39 | Yes `party` (save_state :470-496) |
| Active group | party_manager.gd:43 | Yes (index in `party`) |
| Per-group embodied units / abstract records | party_group.gd:60-63 | Records yes via `_save_one` :499-561; units are folded to records first |
| Group abstract area / overworld position | party_group.gd:40, :67 | Yes |
| Leader | party_manager.gd:63 | Yes |
| pending_leader (chargen handoff) | party_manager.gd:88 | No (cleared by new_game, save_manager.gd:605) |
| fallen (members who died) | party_manager.gd:102 | Yes (party_manager.gd:670, :739-740; review 11-15 doc drift fixed: was "No"); nothing reads it |
| Leader alignment | party_manager.gd:303-319 | Yes |
| PartyMemberData fields (`stats` dict, skills, gear paths, alignment, model) | party_member_data.gd:30-92 | Yes, fixed field list |

## Derived / cached state
- `members` and `roster` are derived getters over groups (party_manager.gd:55-62, :75-80) — no separate list to drift.
- `PartyGroup.current_area_id` derived from `WorldManager.area_of` (party_group.gd:48-56), but `abstract_area_id` (:40) is a stored copy used while abstract.
- `PartyMemberData` is a snapshot of a Unit taken by `_capture_one` (party_manager.gd:360-407). Whenever a group is abstract the record is the truth; anything `_capture_one` does not copy (statuses, buffs, move_remaining, inventory) is lost — see issue 2.
- `ui/party_panel.gd` keeps rows built from member signals (party_panel.gd:111-113) and resyncs on world load (:303-306).

## Public surface
- **Calls in:** `active()` :106, `group_of` :114, `groups_in_area` :125, `split_off` :142-172, `merge_in_area` :179-198, `prune_groups` :203, `everyone` :220, `add_member` :234-246, `remove_member` :256-267, `set_leader` :281, `capture` :347-357, `clear_members` :417-424, `spawn_member` :693-757, `embody` :792-826, `spawn_party` :833, `spawn_group` :840-855, `place_at_landing` :867-916, `relocate` :934-961. Callers: WorldManager travel (world_manager.gd:405-499), SaveManager (save_manager.gd:324, :605, :613), test_arena.gd:43-60, debug_spawner.gd:115, debug_spawn_panel.gd:54-55/118/150, character_creation.gd:445, overworld_avatar.gd:284.
- **Signals out:** `member_added`, `member_removed`, `leader_changed` (party_manager.gd:32-34) → ui/party_panel.gd:111-113, HUD.
- **Signals in:** each member's `Unit.died` → `_on_member_died` :270-272 (connected only inside `add_member` :245).

## Depends on
- SaveManager.register `&"party"` (party_manager.gd:447-448).
- WorldManager.area_of (party_group.gd:48-56); WorldManager drives disembody/embody (world_manager.gd:405-499).
- Unit/UnitDefinition construction and `unit.equip_item` (party_manager.gd:752-755); Item scene instantiation (ITEM_SCENE, same lines).

## Assumptions and invariants
- Every party Unit has passed through `add_member` (so `died` is connected and UI was told). Broken by embody/spawn_group — issue 1.
- `party_member_data.gd:16-21` says statuses are not captured because travel only happens out of combat. **STALE**: SaveManager allows saving in COMBAT (save_manager.gd:292-302) and Downed is now a status (commit 28ba573), so a mid-combat save drops Downed/buffs.
- `clear_members` sets `leader = null` without emitting `leader_changed`, documented as deliberate (party_manager.gd:413-416, :424).
- One leader across all groups (party_manager.gd:63); split groups share it.

## Lifecycle
- Autoload, lives forever. New game: SaveManager calls `load_state({})` on every registered target (save_manager.gd:540-627), then `pending_leader=null` (:605) and `clear_members` (:613); test_arena bootstraps from `pending_leader` (test_arena.gd:57-60).
- Save: `capture` (save_manager.gd:324) folds live units to records, then `save_state`. Load: `load_state` :569-605 builds abstract groups (`embodied=false` :596) and emits no signals; WorldManager embodies them.
- Travel out: `_disembody` captures (world_manager.gd:408), dismisses fielded demons (:409), nulls leader (:417-418), disconnects `died` (:419-420), frees units (:427). Travel in: `_embody_into` merges (:492) and embodies (:499). Area-to-area with the same bodies uses `relocate` :934-961, which reparents and keeps real state.
- Combat/dialogue/cutscene: Downed is handled by Unit (unit.gd:1246-1247). Since the baseline the party also hooks it: `downed_changed` -> `_check_defeat` (party_manager.gd:255, :288-290), `is_defeated` :296-305 and the `defeated` signal :37, which the game over screen listens to (ui/game_over.gd:30). That wiring is made only in `add_member` (:254-255), so it is missing for members built by `embody`/`spawn_group` (issue 1, WLD-1). No area script builds the party itself any more; `StartingParty.bootstrap` does (test_arena.gd:9, spider_cave.gd:10, goblin_quarry.gd:72), and it consumes `pending_leader` (starting_party.gd:52-54).

## Known issues
| # | Issue | Evidence (file:line) | Status |
|---|---|---|---|
| 1 | `embody`/`spawn_group` append the unit to `group.units` before `add_member`, whose `if unit in members: return` then skips the `died` connection and `member_added` | party_manager.gd:817-819, :852-853, :238 vs :245-246 | CONFIRMED (UI masks it via party_panel.gd:303-306; `fallen`/`member_removed` never fire for world-spawned members; party_panel.gd:401 assumes the connection); review 11-15: still open and worse, no longer masked: it disables game over after a load or overworld trip, see WLD-1 (lines now :247 vs :254-255, :973-975, :1008-1009) |
| 2 | Save/capture use a fixed field list: statuses (incl. Downed), buffs, move_remaining, has_attacked dropped; Unit.save_state has statuses but isn't used | party_manager.gd:499-561, :360-407; unit.gd:1480-1489 | CONFIRMED; stats half FIXED (data-driven stats, uncommitted) — every stat base and pool travels as `record.stats` (`stats_to_dict`/`stats_from_dict`); review 11-15: still open for statuses, Downed and turn state, see WLD-2 (lines now :528-566, :674-727, :774-841; `Unit.save_state` is unit.gd:2364-2376; `active_weapon_set` added to both) |
| 3 | `leader = null` without `leader_changed` | world_manager.gd:417-418; party_manager.gd:424 | CONFIRMED; review 11-15: still open, see WLD-17 (party_manager.gd:585) |
| 4 | `_disembody` frees members without `member_removed` | world_manager.gd:405-427 | CONFIRMED; review 11-15: still open, see WLD-17 |
| 5 | `load_state` emits no signals | party_manager.gd:569-605 | CONFIRMED; review 11-15: still open, see WLD-17 (now :735-771) |
| 6 | `spawn_member` instantiates Item scenes to equip but never parents them: orphan nodes per spawn | party_manager.gd:752-755 | FIXED, confirmed by review 11-15: `spawn_member` equips `ItemInstance` copies (:906), no Item scenes |
| 7 | Only `gear_data` is captured for equipment; Item-level state is lost | party_manager.gd:402-405 | FIXED, confirmed by review 11-15: the whole `ItemInstance` is captured and saved via `to_dict/from_dict` |
| 8 | `fallen` is written but nothing reads it | party_manager.gd:93, :270-272 | FIXED (`fallen` is now saved and loaded, party_manager.gd:670, :739-740), confirmed by review 11-15; still nothing reads it, and it is only written for wired members (WLD-1) |
| 9 | PartyMemberData header assumes no combat saves | party_member_data.gd:16-21 | NEW (STALE comment); review 11-15: still open |

### Review 2026-11-15 (HEAD 14cb4ad9)
| id | Issue | Evidence | Cause | Sustainable fix | Root | Size | Status |
|---|---|---|---|---|---|---|---|
| WLD-1 | Members built by `embody`/`spawn_group` are never wired for `died` or `downed_changed`, so game over does not fire after a load or an overworld trip: after Retry a second wipe shows no game-over screen, the dead leader stays leader and `fallen` is not written. A fresh new game is wired (`StartingParty.bootstrap` calls `add_member` on a unit not yet in a group), which hides it in a first session. | party_manager.gd:247 vs :254-255, :973-975, :1008-1009; ui/game_over.gd:30, :80-82 | `members` is computed from `group.units`, which those two paths append to before `add_member`, so its `if unit in members: return` always fires; game over (5c9e994f) and Downed (82eb3dc7) then hung the loss condition on that connection. | One idempotent `_adopt(unit, group)` (group append, connections, `member_added`) that checks the connection, not membership; `embody`, `spawn_group` and `add_member` all call it. Test: load, kill the party, expect `defeated`. | R5 | S | KNOWN (#1) |
| WLD-2 | Two serializers for one unit: NPCs go through `Unit.save_state`, party members through a hand-kept field list that drops statuses, Downed, move left, parries and flight altitude. A Downed member comes back from a load or overworld trip standing at negative HP with the death tallies gone; a mid-combat save clears every party status and gives a fresh turn. | unit.gd:2364-2376 vs party_manager.gd:528-566, :674-727, :774-841; world_manager.gd:777-778, :799-802; save_manager.gd:297-299, :306-310; party_member_data.gd:16-21 | The party record predates `Unit.save_state`; combat saves and Downed were built before README fix-queue step 5 (one `Unit.save_state`). | `PartyMemberData` keeps identity and build and gains one opaque `unit_state` from `Unit.save_state()` minus transform; `spawn_member` ends with `unit.load_state(record.unit_state)`; delete per-field copies it covers; fix the three comments that promise the opposite. | R2, R4 | M | KNOWN (#2) |
| WLD-7 | `_unchained` and `_chain_walkers` survive a load and a new game and are not saved: unchain a companion, load an older save, and it is still unchained; quit and reload and it is chained again. | party_manager.gd:335, :339, :576-585, :735-771; save_manager.gd:596-620 | Chain state is kept in autoload dictionaries keyed by persistent_id, outside the party record, and nothing clears them. | Store `chained` on the member record (it is a party fact) and clear it in `load_state`. | R2, R3 | S | BUG |
| WLD-17 | Signals skipped on teardown leave `leader` and listeners stale: `leader = null` with no `leader_changed`, `_disembody` frees members with no `member_removed` and disconnects only `died`, and `load_state` emits nothing. | party_manager.gd:585, :572-575, :735-771; world_manager.gd:417-420 | The stated reason ("every listener is about to see a whole new world via world_loaded") is false for travel to the overworld or a facility, where no party is embodied afterwards. | Emit the signals (or a single `party_changed`) on teardown and load; disconnect `downed_changed` as well as `died`. | R5 | S | KNOWN (#3, #4, #5) |
| UI-19 | same as WLD-1 (party.md): game over depends on the `defeated` wiring, and `_check_defeat` can fire on a half-rebuilt party during a load | ui/game_over.gd:24-41; party_manager.gd:308-310 | | | R2, R5 | | see ui.md |

## Tests
`tests/world/`: test_party_split.gd, test_split_stability.gd, test_a_split_party_survives_a_save.gd, test_party_panel_rows.gd, test_member_reachability.gd, test_the_starting_party_has_bodies.gd, test_a_new_game_is_new.gd, test_persistence.gd, test_load_restores_combat_elsewhere.gd, test_arrival_placement.gd, test_residency.gd; plus tests/dialogue/test_the_party_stays_reachable.gd. Gaps: no test that a world-spawned member's death reaches `_on_member_died` (issue 1), no test that statuses survive save (issue 2), no `leader_changed` assertion on travel.
