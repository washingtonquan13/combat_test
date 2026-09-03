extends HBoxContainer
## Ability hotbar — three fixed sections left to right (Common,
## Abilities, Custom — see Ability.Category / Unit.custom_slots),
## separated by two draggable HotbarDivider instances that trade whole
## columns between their two neighbor GridContainers (see
## _on_divider_dragged). Shows the current turn's abilities in combat, or
## the first selected unit's abilities out of combat (see
## _refresh_out_of_combat_unit) — visible whenever there's a
## player-controlled unit to show, either way.
##
## Casting works out of combat too, not just display/arm — see
## PlayerInteractionState.get_active_unit() (resolves the first selected
## unit out of combat, the acting unit in combat) and ClickRouter,
## both of which route through that one function rather than checking
## CombatManager.in_combat separately. No turn economy applies out of
## combat (UnitCombat.use_ability's already_acted/has_attacked gating is
## combat-only, same convention as move budget everywhere else in this
## project) and no per-turn status/surface decay happens either — an
## out-of-combat buff/debuff/DoT just sits at full duration until a real
## combat session runs, a deliberate, accepted characteristic, not a bug.
##
## Scene setup: this script now attaches to the HBoxContainer itself (was
## a GridContainer pre-rework — see main.tscn). Children, left to right,
## all scene-authored and PERMANENT (never added/removed at runtime,
## unlike the ability slot Buttons inside each grid): CommonGrid
## (GridContainer), DividerCommonAbilities (HotbarDivider), AbilitiesGrid
## (GridContainer), DividerAbilitiesCustom (HotbarDivider), CustomGrid
## (GridContainer). Assign slot_scene to the HotbarSlot scene, same as
## before. Each grid's `columns` in the Inspector is just its STARTING
## width — dragging a divider mutates it live afterward, and _rebuild()
## never touches it, so a section's width survives switching which unit
## is displayed.

@export var slot_scene: PackedScene

@onready var _common_grid: GridContainer = $CommonGrid
@onready var _abilities_grid: GridContainer = $AbilitiesGrid
@onready var _custom_grid: GridContainer = $CustomGrid
@onready var _divider_common_abilities: HotbarDivider = $DividerCommonAbilities
@onready var _divider_abilities_custom: HotbarDivider = $DividerAbilitiesCustom

var _slots: Array[Button] = []
var _current_unit: Unit = null

## Column counts snapshotted at the start of whichever divider is
## currently mid-drag, keyed by the divider itself. Only ever holds an
## entry for a divider actually being dragged right now — one mouse can't
## drag both at once, but keying by divider rather than hardcoding two
## slots keeps _on_divider_dragged one shared implementation instead of
## two near-duplicates.
var _drag_start_columns: Dictionary = {}


func _ready() -> void:
	CombatManager.turn_started.connect(_on_turn_started)
	CombatManager.combat_ended.connect(_on_combat_ended)
	AbilityManager.ability_armed.connect(_on_ability_armed)
	SelectionManager.selection_changed.connect(_on_selection_changed)

	_wire_divider(_divider_common_abilities, _common_grid, _abilities_grid)
	_wire_divider(_divider_abilities_custom, _abilities_grid, _custom_grid)

	visible = false


func _wire_divider(divider: HotbarDivider, left_grid: GridContainer, right_grid: GridContainer) -> void:
	divider.drag_started.connect(_on_divider_drag_started.bind(divider, left_grid, right_grid))
	divider.columns_dragged.connect(_on_divider_dragged.bind(divider, left_grid, right_grid))


func _on_divider_drag_started(divider: HotbarDivider, left_grid: GridContainer, right_grid: GridContainer) -> void:
	_drag_start_columns[divider] = Vector2i(left_grid.columns, right_grid.columns)


## Trades whole columns between exactly the two grids THIS divider sits
## between — positive delta moves the divider right (left grows, right
## shrinks by the same amount), clamped so neither side can be pushed
## below 1 column. delta is the TOTAL signed offset since this drag
## gesture began, so this always recomputes both sides fresh from the
## drag-start snapshot rather than adjusting incrementally.
func _on_divider_dragged(delta: int, divider: HotbarDivider, left_grid: GridContainer, right_grid: GridContainer) -> void:
	var start: Vector2i = _drag_start_columns.get(divider, Vector2i(left_grid.columns, right_grid.columns))
	var min_delta: int = 1 - start.x   # most negative: left shrinks to 1
	var max_delta: int = start.y - 1   # most positive: right shrinks to 1
	var clamped: int = clampi(delta, min_delta, max_delta)
	left_grid.columns = start.x + clamped
	right_grid.columns = start.y - clamped


func _on_turn_started(unit: Unit) -> void:
	AbilityManager.disarm()
	_disconnect_current_unit()

	if not unit.is_player_controlled():
		visible = false
		_clear()
		return

	_current_unit = unit
	unit.ability_used.connect(_on_ability_used)
	_rebuild(unit)
	visible = true


func _on_combat_ended(_winning_faction: StringName) -> void:
	AbilityManager.disarm()
	_disconnect_current_unit()
	_clear()
	visible = false
	# Combat's own turn-based unit just went away — fall back to
	# whatever's selected immediately, same as any other selection-driven
	# refresh, instead of sitting hidden until the next unrelated
	# selection change.
	_refresh_out_of_combat_unit()


## Mirrors _on_turn_started for the out-of-combat case. Ignored while
## combat is running — turn_started/combat_ended are authoritative then,
## and the acting unit is never necessarily the same as the current
## selection (an AI turn, or the player having other units selected).
func _on_selection_changed(_selected_units: Array[Unit]) -> void:
	_refresh_out_of_combat_unit()


## Follows the selection whether or not a fight is running. The guard
## that used to sit here — return early while in_combat — is what made
## selecting a party member outside a battle do nothing at all: the bar
## kept showing the combatant's abilities, so there was no way to reach
## anybody else's. Whether the displayed unit can actually USE what is
## shown is a per-unit question now (Unit.is_commandable), not a
## question about whether a fight exists somewhere.
func _refresh_out_of_combat_unit() -> void:

	var unit: Unit = SelectionManager.selected_units[0] if not SelectionManager.selected_units.is_empty() else null
	if unit == _current_unit:
		return  # same displayed unit already — don't disturb an in-progress arm

	AbilityManager.disarm()
	_disconnect_current_unit()

	if not unit:
		visible = false
		_clear()
		return

	_current_unit = unit
	unit.ability_used.connect(_on_ability_used)
	_rebuild(unit)
	visible = true


func _disconnect_current_unit() -> void:
	if _current_unit and is_instance_valid(_current_unit) and _current_unit.ability_used.is_connected(_on_ability_used):
		_current_unit.ability_used.disconnect(_on_ability_used)
	_current_unit = null


## Filters unit.abilities into CommonGrid/AbilitiesGrid by
## Ability.category, then fills CustomGrid from unit.custom_slots
## index-for-index, including null entries (an empty Custom slot is
## still a real slot — see hotbar_slot.gd). Never touches any grid's
## `columns` — section widths are a layout preference, not rebuild state.
func _rebuild(unit: Unit) -> void:
	_clear()
	if not slot_scene:
		return

	for ability in unit.abilities:
		var target_grid: GridContainer = _common_grid if ability.category == Ability.Category.COMMON else _abilities_grid
		_add_slot(target_grid, unit, ability, -1)

	for i in unit.custom_slots.size():
		_add_slot(_custom_grid, unit, unit.custom_slots[i], i)

	_update_slot_states()


## custom_index >= 0 marks this as a Custom-section slot (and which
## element of unit.custom_slots it mirrors) — see hotbar_slot.gd's
## is_custom_slot/custom_slot_index. -1 means Common/Abilities: a fixed
## display of one of unit.abilities, never a drop target.
func _add_slot(grid: GridContainer, unit: Unit, ability: Ability, custom_index: int) -> void:
	var slot: Button = slot_scene.instantiate()
	# Fields assigned BEFORE add_child — add_child triggers the slot's
	# _ready() synchronously, which reads them immediately (icon,
	# tooltip).
	slot.unit = unit
	slot.ability = ability
	slot.is_custom_slot = custom_index >= 0
	slot.custom_slot_index = custom_index
	grid.add_child(slot)
	_slots.append(slot)


func _on_ability_armed(_ability: Ability) -> void:
	_update_slot_states()


func _on_ability_used(_attacker: Unit, _target, _result: Dictionary) -> void:
	# Using one ability can make OTHERS unusable too (has_attacked), so
	# refresh every slot's disabled state, not just the one that fired.
	_update_slot_states()


func _update_slot_states() -> void:
	for slot in _slots:
		if is_instance_valid(slot):
			slot.refresh_state()


func _clear() -> void:
	for slot in _slots:
		if is_instance_valid(slot):
			slot.queue_free()
	_slots.clear()
