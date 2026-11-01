# Party

**Files:** `systems/party_system/` — `party_manager.gd` (961, autoload), `party_group.gd` (119, RefCounted), `party_member_data.gd` (92, Resource record), `party_skill_record.gd` (11). Party-side halves of travel live in `systems/world_system/world_manager.gd` (`_disembody` :405-427, `_embody_into` :470-499).
**Autoloads owned:** `PartyManager`.

## Purpose
Owns who is in the player's party, how it is split into groups (embodied in a world vs abstract records), who leads, and the party's save/restore and spawn-from-record paths. It is NOT responsible for the Unit's own runtime state (HP, statuses, turns: see unit.md), for summoned demons (DemonRoster; `add_member` refuses summons, party_manager.gd:235), for inventory contents (party_overview, see inventory.md), or for deciding when travel happens (WorldManager).

## State it owns (source of truth)
| State | Where (file:line) | Persisted? (save key) |
|---|---|---|
| Groups (list of PartyGroup) | party_manager.gd:39 | Yes `party` (save_state :470-496) |
| Active group | party_manager.gd:43 | Yes (index in `party`) |
| Per-group embodied units / abstract records | party_group.gd:60-63 | Records yes via `_save_one` :499-561; units are folded to records first |
| Group abstract area / overworld position | party_group.gd:40, :67 | Yes |
| Leader | party_manager.gd:63 | Yes |
| pending_leader (chargen handoff) | party_manager.gd:88 | No (cleared by new_game, save_manager.gd:605) |
| fallen (members who died) | party_manager.gd:93 | No |
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
- Combat/dialogue/cutscene: no party-specific hooks; Downed handled by Unit (unit.gd:1246-1247).

## Known issues
| # | Issue | Evidence (file:line) | Status |
|---|---|---|---|
| 1 | `embody`/`spawn_group` append the unit to `group.units` before `add_member`, whose `if unit in members: return` then skips the `died` connection and `member_added` | party_manager.gd:817-819, :852-853, :238 vs :245-246 | CONFIRMED (UI masks it via party_panel.gd:303-306; `fallen`/`member_removed` never fire for world-spawned members; party_panel.gd:401 assumes the connection) |
| 2 | Save/capture use a fixed field list: statuses (incl. Downed), buffs, move_remaining, has_attacked dropped; Unit.save_state has statuses but isn't used | party_manager.gd:499-561, :360-407; unit.gd:1480-1489 | CONFIRMED; stats half FIXED (data-driven stats, uncommitted) — every stat base and pool travels as `record.stats` (`stats_to_dict`/`stats_from_dict`) |
| 3 | `leader = null` without `leader_changed` | world_manager.gd:417-418; party_manager.gd:424 | CONFIRMED |
| 4 | `_disembody` frees members without `member_removed` | world_manager.gd:405-427 | CONFIRMED |
| 5 | `load_state` emits no signals | party_manager.gd:569-605 | CONFIRMED |
| 6 | `spawn_member` instantiates Item scenes to equip but never parents them: orphan nodes per spawn | party_manager.gd:752-755 | NEW |
| 7 | Only `gear_data` is captured for equipment; Item-level state is lost | party_manager.gd:402-405 | NEW |
| 8 | `fallen` is written but nothing reads it | party_manager.gd:93, :270-272 | NEW |
| 9 | PartyMemberData header assumes no combat saves | party_member_data.gd:16-21 | NEW (STALE comment) |

## Tests
`tests/world/`: test_party_split.gd, test_split_stability.gd, test_a_split_party_survives_a_save.gd, test_party_panel_rows.gd, test_member_reachability.gd, test_the_starting_party_has_bodies.gd, test_a_new_game_is_new.gd, test_persistence.gd, test_load_restores_combat_elsewhere.gd, test_arrival_placement.gd, test_residency.gd; plus tests/dialogue/test_the_party_stays_reachable.gd. Gaps: no test that a world-spawned member's death reaches `_on_member_died` (issue 1), no test that statuses survive save (issue 2), no `leader_changed` assertion on travel.
