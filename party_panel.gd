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

var _core_rows: Dictionary = {}  # Unit -> HBoxContainer (that unit's portrait + its summon fan)
var _summon_fans: Dictionary = {}  # Unit (summoner) -> HBoxContainer (its fan, inside its own row)
var _summon_chips: Dictionary = {}  # Unit (summon) -> the unit_portrait Button instance in its summoner's fan


func _ready() -> void:
	visible = false
	add_to_group("party_panel")
	# Deferred — CanvasLayer (and this panel under it) is declared before
	# the actual unit nodes in main.tscn, so scanning "units" immediately
	# here could run before every unit has added itself to that group in
	# its own _ready(). One frame later, everything's settled.
	_rebuild_core.call_deferred()


func _rebuild_core() -> void:
	for unit in UnitQuery.core_party_units(get_tree()):
		_add_core_slot(unit)
	_update_visibility()


## Public entry point for a core party member that joins AFTER the
## initial _rebuild_core scan — the debug spawn tool's own friendly
## spawns, found via ground_click_target.gd through the "party_panel"
## group rather than a direct reference, same reasoning
## give_item_effect.gd already uses to reach PartyOverview through the
## "party_overview" group. _add_core_slot is already idempotent (skips
## a unit already present), so this is safe to call more than once for
## the same unit.
func register_core_unit(unit: Unit) -> void:
	_add_core_slot(unit)
	_update_visibility()


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

	if not unit.died.is_connected(_on_core_unit_died):
		unit.died.connect(_on_core_unit_died)
	if not unit.ability_used.is_connected(_on_core_unit_ability_used):
		unit.ability_used.connect(_on_core_unit_ability_used)


func _on_core_unit_died(unit: Unit) -> void:
	if unit not in _core_rows:
		return
	var row: Control = _core_rows[unit]
	if is_instance_valid(row):
		row.queue_free()
	_core_rows.erase(unit)
	_summon_fans.erase(unit)
	_update_visibility()


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
