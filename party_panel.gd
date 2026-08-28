class_name PartyPanel
extends VBoxContainer
## Left-edge party display — always visible in and out of combat, no
## CombatManager gating at all. One row per core party member (a
## player-faction unit that wasn't itself summoned): that member's own
## portrait, followed by a small overlapping "hand of cards" fan of
## portrait chips for whatever it currently has summoned — inspired by
## BG3's action-economy fan next to each portrait. Replaces an earlier
## version that gave each summoner a separate text-labeled row below the
## core list ("Kael's summons — 3"); that Button's text-driven width
## could exceed the panel's own narrow column and spill out sideways,
## which is exactly the "too much horizontal real estate" this fan
## design fixes — a fan only grows by (chip width - overlap) per
## additional summon, not a full new row's worth of width, and there's
## no text at all left to overflow.
##
## Renders from live PartyManager.members when a world spawns the party
## (every world except the overworld today), and from PartyManager.roster
## — plain PartyMemberData, no live Unit at all — when it doesn't (see
## _on_world_loaded()). unit_portrait.gd's own data export is what makes
## a single portrait component serve both cases.
##
## Scene setup: VBoxContainer root placed directly under CanvasLayer,
## left-anchored — same convention AbilityHotbar/InitiativeRow already
## use (script attached straight to a Control in main.tscn, no wrapper
## scene). One child: CoreContainer (VBoxContainer, empty — populated at
## runtime with one HBoxContainer row per core unit). Assign slot_scene
## to unit_portrait.tscn — the same shared portrait/click-to-select
## component initiative_row.gd uses, instanced directly with no wrapper
## scene around it, for BOTH the core portrait and every summon chip in
## its fan.

@export var slot_scene: PackedScene
## Uniform size multiplier for summon chips relative to their authored
## size in unit_portrait.tscn — deliberately smaller than the core
## portrait's own 0.5 (see _add_core_slot) so a fan of chips reads as
## subordinate to the party member that owns it, card-hand style.
@export var summon_chip_scale: float = 0.35
## How many pixels each summon chip overlaps the previous one by, via
## negative separation on the fan HBoxContainer — Godot's own container
## layout does the actual overlapping/repacking, both when a chip is
## added and when one is removed, so nothing here ever repositions chips
## by hand. Tune this and summon_chip_scale live in the inspector to get
## the fan reading right — both are just starting points.
@export var summon_fan_overlap: int = 18

@onready var _core_container: VBoxContainer = $CoreContainer

## Keyed by Unit for a spawned world, or by PartyMemberData for a world
## that deliberately doesn't spawn the party (the overworld — see
## PartyManager.roster/WorldManager.spawns_party()). Untyped Dictionary,
## so both key shapes coexist without incident; a given row is always
## exactly one or the other, never both, since a world either spawns the
## party or it doesn't.
var _core_rows: Dictionary = {}  # (Unit | PartyMemberData) -> HBoxContainer
var _summon_fans: Dictionary = {}  # Unit (summoner) -> HBoxContainer (its fan, inside its own row) -- live units only
var _summon_chips: Dictionary = {}  # Unit (summon) -> the unit_portrait Button instance in its summoner's fan


## Reactive to PartyManager's own membership signals rather than a one-
## shot post-boot scan — the panel used to assume its units already
## existed in the same scene by the time a single deferred frame elapsed
## (true back when MainRoot pre-instanced the arena at edit time), which
## stopped holding the moment WorldManager made worlds load asynchronously
## at runtime, well after this panel's own _ready(). PartyManager is the
## single authoritative roster (see that file's own header) and every
## real path that should produce a portrait already calls add_member() —
## the initial bootstrap, a world reload's spawn_party(), and both debug
## spawn tools — so listening to it directly loses no case and closes the
## exact "two independently-drifting mechanisms" gap register_core_unit()
## used to paper over for just the debug-spawn path.
func _ready() -> void:
	visible = false
	PartyManager.member_added.connect(_on_member_added)
	PartyManager.member_removed.connect(_on_member_removed)
	PartyManager.leader_changed.connect(_on_leader_changed)
	WorldManager.world_loading.connect(_on_world_loading)
	WorldManager.world_loaded.connect(_on_world_loaded)
	# Deferred, same reasoning as before: safe even if this panel is ever
	# constructed after members already exist (e.g. a future scene that
	# doesn't boot through MainRoot at all).
	_rebuild_core.call_deferred()


func _rebuild_core() -> void:
	for unit in PartyManager.members:
		_add_core_slot(unit)
	_sort_rows()
	_update_visibility()


func _on_member_added(unit: Unit) -> void:
	_add_core_slot(unit)
	_sort_rows()
	_update_visibility()


func _on_member_removed(unit: Unit) -> void:
	_remove_core_slot(unit)
	_update_visibility()


func _on_leader_changed(_unit: Unit) -> void:
	_sort_rows()


## Fires after a load_world() call fully resolves — including, if the new
## world spawns the party, after every member_added it triggered along
## the way (see WorldManager.load_world()'s own ordering: spawn_party()
## runs, THEN world_loaded emits). So members being non-empty here means
## _on_member_added already built real rows and this has nothing to do;
## members being empty and roster non-empty means the new world opted out
## of spawning (spawns_party() -> false, the overworld) and this is the
## ONLY signal telling the panel to render data-only rows instead.
func _on_world_loaded(_world: Node) -> void:
	if PartyManager.members.is_empty() and not PartyManager.roster.is_empty():
		for record in PartyManager.roster:
			_add_data_slot(record)
		_sort_rows()
		_update_visibility()


## PartyManager.clear_members() deliberately emits no per-unit signals
## (see that method's own header — nothing needs to react to an
## incremental teardown, since every listener is about to see a whole new
## world instead) — this is what tells the panel to actually let go of
## its own rows before their Units are freed, rather than relying on a
## signal that was never going to fire. Fired at the very start of
## load_world(), before the outgoing world is freed, so every row here is
## still valid at the moment this runs.
func _on_world_loading(_scene: PackedScene) -> void:
	for row in _core_rows.values():
		if is_instance_valid(row):
			row.queue_free()
	_core_rows.clear()
	_summon_fans.clear()
	_summon_chips.clear()
	_update_visibility()


## Moves the leader's row (if any) to the front — the same leader-first
## ordering _rebuild_core() used to only apply via a full sort, now done
## incrementally via move_child() so an add/leader-change never has to
## rebuild every row (which would destroy each summoner's live fan of
## chips built by _register_summon()). Checks PartyManager.leader (a live
## Unit) first; when nothing is spawned (rendering from roster instead —
## see _on_world_loaded), falls back to whichever PartyMemberData record
## has is_leader set, since PartyManager.leader is null the whole time
## the party isn't spawned as real Units at all.
func _sort_rows() -> void:
	var leader: Unit = PartyManager.leader
	if leader and leader in _core_rows:
		_core_container.move_child(_core_rows[leader], 0)
		return

	for record in PartyManager.roster:
		if record.is_leader and record in _core_rows:
			_core_container.move_child(_core_rows[record], 0)
			return


func _add_core_slot(unit: Unit) -> void:
	if not slot_scene or unit in _core_rows:
		return

	var row := HBoxContainer.new()
	_core_container.add_child(row)

	var portrait: Button = slot_scene.instantiate()
	# unit must be assigned BEFORE add_child — add_child triggers the
	# slot's _ready() synchronously, and unit_portrait.gd's _ready()
	# reads unit immediately (portrait texture, signal hookups). Same
	# requirement initiative_row.gd's own _add_slot already follows.
	portrait.unit = unit
	row.add_child(portrait)
	portrait.set_fit_scale(0.5)

	var fan := HBoxContainer.new()
	fan.add_theme_constant_override("separation", -summon_fan_overlap)
	row.add_child(fan)

	_core_rows[unit] = row
	_summon_fans[unit] = fan

	if not unit.ability_used.is_connected(_on_core_unit_ability_used):
		unit.ability_used.connect(_on_core_unit_ability_used)


## Data-only counterpart to _add_core_slot() — a portrait rendered from a
## captured PartyMemberData record instead of a live Unit (see
## _on_world_loaded). No summon fan: nothing can be summoned by a unit
## that doesn't currently exist as a real Unit at all.
func _add_data_slot(record: PartyMemberData) -> void:
	if not slot_scene or record in _core_rows:
		return

	var row := HBoxContainer.new()
	_core_container.add_child(row)

	var portrait: Button = slot_scene.instantiate()
	portrait.data = record
	row.add_child(portrait)
	portrait.set_fit_scale(0.5)

	_core_rows[record] = row


## A core unit's own death is not listened to directly — every unit that
## can ever reach _core_rows is (or was) a PartyManager member, and
## PartyManager already connects its own death handler
## (see PartyManager.add_member -> _on_member_died -> remove_member(),
## which emits member_removed) — so _on_member_removed above already
## covers this case. A second direct unit.died listener here would just
## be the same "two independently-drifting mechanisms" problem this whole
## fix exists to close, one signal earlier.
func _remove_core_slot(unit: Unit) -> void:
	if unit not in _core_rows:
		return
	var row: Control = _core_rows[unit]
	if is_instance_valid(row):
		row.queue_free()
	_core_rows.erase(unit)
	_summon_fans.erase(unit)


## Detects a new summon the same way this project already communicates
## "an ability just did something interesting" — checking the
## ability_used result dict rather than adding a dedicated signal.
## SummonEffect.apply() already returns {"summoned": summon}; nothing
## else in this project's effects use that key, so this is unambiguous.
## Fires identically in and out of combat, since ability_used already
## does — no separate out-of-combat handling needed.
func _on_core_unit_ability_used(attacker: Unit, _target, result: Dictionary) -> void:
	# "summoned" is a per-EFFECT key (see SummonEffect.apply), not a
	# top-level one — use_ability() nests every effect's own result
	# dictionary inside result["effects"], it never merges them up a
	# level. Checking result.has("summoned") directly never matched
	# anything, which is why summons weren't appearing.
	for effect_result in result.get("effects", []):
		if not effect_result.has("summoned"):
			continue
		var summon: Unit = effect_result["summoned"]
		if summon and summon.is_player_controlled():
			_register_summon(attacker, summon)


func _register_summon(summoner: Unit, summon: Unit) -> void:
	if not slot_scene or summon in _summon_chips:
		return
	var fan: HBoxContainer = _summon_fans.get(summoner)
	if not fan:
		return

	var chip: Button = slot_scene.instantiate()
	chip.unit = summon
	fan.add_child(chip)
	chip.set_fit_scale(summon_chip_scale)

	_summon_chips[summon] = chip
	summon.died.connect(_on_summon_died, CONNECT_ONE_SHOT)


## Frees just this one summon's own chip — the fan HBoxContainer it lived
## in repacks the remaining chips automatically (that's the point of
## negative separation instead of manually-positioned chips: removal is
## exactly as free as insertion was). No group bookkeeping to refresh
## since nothing here is counted or labeled anymore — the fan's actual
## child count IS the visible count.
func _on_summon_died(summon: Unit) -> void:
	var chip: Control = _summon_chips.get(summon)
	if chip and is_instance_valid(chip):
		chip.queue_free()
	_summon_chips.erase(summon)


func _update_visibility() -> void:
	visible = not _core_rows.is_empty()
