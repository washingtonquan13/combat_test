extends VBoxContainer
## Left-edge party display — always visible in and out of combat, no
## CombatManager gating at all. Two sections: a list of core party
## members (one row per player-faction unit that wasn't itself
## summoned), and a grouped summons list (one row per summoner currently
## owning 1+ living summons, NOT one row per summoned unit — mass
## summoning is meant to be a central mechanic eventually, and a panel
## that grows one row per summon doesn't survive that).
##
## Scene setup: VBoxContainer root placed directly under CanvasLayer,
## left-anchored — same convention AbilityHotbar/InitiativeRow already
## use (script attached straight to a Control in main.tscn, no wrapper
## scene). Children: CoreContainer (VBoxContainer, empty — populated at
## runtime), SummonsHeader (Label), SummonsContainer (VBoxContainer,
## empty). Assign slot_scene to unit_portrait.tscn — the same shared
## portrait/click-to-select component initiative_row.gd uses, instanced
## directly with no wrapper scene around it (an earlier version wrapped
## it in its own Button to add click-to-select; unit_portrait.gd now
## has that built in, so the wrapper was just a source of layout bugs
## for no remaining reason to exist).

@export var slot_scene: PackedScene

@onready var _core_container: VBoxContainer = $CoreContainer
@onready var _summons_header: Label = $SummonsHeader
@onready var _summons_container: VBoxContainer = $SummonsContainer

var _core_slots: Dictionary = {}  # Unit -> the unit_portrait Button instance
var _summon_group_rows: Dictionary = {}  # Unit (summoner) -> Button (group row)
## Unit (summon) -> Unit (summoner) — the live membership this panel is
## tracking. Looked up when a summon's own died signal fires (its
## summoned_by is still readable then too, but going through this map
## keeps registration/unregistration symmetric and doesn't assume
## summoned_by survives however far into cleanup death has gotten).
var _summon_owners: Dictionary = {}


func _ready() -> void:
	visible = false
	_summons_header.visible = false
	# Deferred — CanvasLayer (and this panel under it) is declared before
	# the actual unit nodes in main.tscn, so scanning "units" immediately
	# here could run before every unit has added itself to that group in
	# its own _ready(). One frame later, everything's settled.
	_rebuild_core.call_deferred()


func _rebuild_core() -> void:
	for node in get_tree().get_nodes_in_group("units"):
		var unit := node as Unit
		if unit and unit.is_player_controlled() and unit.summoned_by == null:
			_add_core_slot(unit)
	_update_visibility()


func _add_core_slot(unit: Unit) -> void:
	if not slot_scene or unit in _core_slots:
		return

	var slot: Button = slot_scene.instantiate()
	# unit must be assigned BEFORE add_child — add_child triggers the
	# slot's _ready() synchronously, and unit_portrait.gd's _ready()
	# reads unit immediately (portrait texture, signal hookups). Same
	# requirement initiative_row.gd's own _add_slot already follows.
	slot.unit = unit
	_core_container.add_child(slot)
	slot.set_fit_scale(0.5)
	_core_slots[unit] = slot

	if not unit.died.is_connected(_on_core_unit_died):
		unit.died.connect(_on_core_unit_died)
	if not unit.ability_used.is_connected(_on_core_unit_ability_used):
		unit.ability_used.connect(_on_core_unit_ability_used)


func _on_core_unit_died(unit: Unit) -> void:
	if unit not in _core_slots:
		return
	var slot: Control = _core_slots[unit]
	if is_instance_valid(slot):
		slot.queue_free()
	_core_slots.erase(unit)
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
	_summon_owners[summon] = summoner
	summon.died.connect(_on_summon_died, CONNECT_ONE_SHOT)
	_refresh_summon_group(summoner)


func _on_summon_died(summon: Unit) -> void:
	var summoner: Unit = _summon_owners.get(summon)
	_summon_owners.erase(summon)
	if summoner:
		_refresh_summon_group(summoner)


## Rebuilds summoner's own group row from the current _summon_owners
## membership — counts, relabels, creates the row on the first summon,
## frees it once the count reaches zero. Called after every
## registration/death rather than incrementing/decrementing a stored
## count, so it can never drift out of sync with _summon_owners.
func _refresh_summon_group(summoner: Unit) -> void:
	var count: int = 0
	for summon in _summon_owners:
		if _summon_owners[summon] == summoner:
			count += 1

	if count <= 0:
		if summoner in _summon_group_rows:
			var stale_row: Button = _summon_group_rows[summoner]
			if is_instance_valid(stale_row):
				stale_row.queue_free()
			_summon_group_rows.erase(summoner)
		_summons_header.visible = not _summon_group_rows.is_empty()
		return

	var row: Button
	if summoner in _summon_group_rows and is_instance_valid(_summon_group_rows[summoner]):
		row = _summon_group_rows[summoner]
	else:
		row = Button.new()
		row.pressed.connect(_on_summon_group_pressed.bind(summoner))
		_summons_container.add_child(row)
		_summon_group_rows[summoner] = row

	row.text = "%s's summons — %d" % [summoner.name, count]
	_summons_header.visible = true


func _on_summon_group_pressed(summoner: Unit) -> void:
	var first: bool = true
	for summon in _summon_owners:
		if _summon_owners[summon] != summoner:
			continue
		if first:
			SelectionManager.select(summon)
			first = false
		else:
			SelectionManager.add(summon)


func _update_visibility() -> void:
	visible = not _core_slots.is_empty()
