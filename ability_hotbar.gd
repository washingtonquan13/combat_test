extends GridContainer
## Ability hotbar — shows the current turn's abilities (if it's a
## player-controlled unit's turn) and lets the player click one to "arm"
## it via AbilityManager, for their next click-to-target (see
## Unit._on_input_event). Hidden during the AI's turns and outside of
## combat, same visibility rule as movement_indicator.gd.
##
## Scene setup: attach to a GridContainer (set its `columns` in the
## Inspector — a plain HBoxContainer stopped being enough once the
## ability list grew past what fits in one row; wraps into additional
## rows instead of running off-screen). Assign slot_scene to the
## HotbarSlot scene (hotbar_slot.gd).
##
## Disarms at the start of every turn — clicking an enemy with nothing
## explicitly armed falls back to Unit.default_ability() (abilities[0]),
## so "just click and attack" keeps working without the player having to
## re-pick their basic attack each turn; picking a hotbar slot is only
## needed when they want something OTHER than the default.

@export var slot_scene: PackedScene

var _slots: Array[Button] = []
var _current_unit: Unit = null


func _ready() -> void:
	CombatManager.turn_started.connect(_on_turn_started)
	CombatManager.combat_ended.connect(_on_combat_ended)
	AbilityManager.ability_armed.connect(_on_ability_armed)
	visible = false


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
	_disconnect_current_unit()
	_clear()
	visible = false


func _disconnect_current_unit() -> void:
	if _current_unit and is_instance_valid(_current_unit) and _current_unit.ability_used.is_connected(_on_ability_used):
		_current_unit.ability_used.disconnect(_on_ability_used)
	_current_unit = null


func _rebuild(unit: Unit) -> void:
	_clear()
	if not slot_scene:
		return

	for ability in unit.abilities:
		var slot: Button = slot_scene.instantiate()
		# ability/unit must be assigned BEFORE add_child — add_child
		# triggers the slot's _ready() synchronously, which reads them
		# immediately (icon, tooltip). Setting them after add_child means
		# _ready() already ran against still-unset values.
		slot.ability = ability
		slot.unit = unit
		add_child(slot)
		slot.pressed.connect(_on_slot_pressed.bind(ability))
		_slots.append(slot)

	_update_slot_states()


## A self-targeting ability (see AbilityTargeting.resolves_immediately)
## fires immediately on press rather than arming — there's no further
## input to wait for, the target is already known. Every other ability
## keeps the existing arm/disarm toggle, waiting for Unit._on_input_event
## or ground_click_target.gd to actually supply a target.
func _on_slot_pressed(ability: Ability) -> void:
	if ability.targeting and ability.targeting.resolves_immediately():
		_current_unit.use_ability(ability, _current_unit)
		return

	if AbilityManager.armed_ability == ability:
		AbilityManager.disarm()
	else:
		AbilityManager.arm(ability)


func _on_ability_armed(_ability: Ability) -> void:
	_update_slot_states()


func _on_ability_used(_attacker: Unit, _target, _result: Dictionary) -> void:
	# Using one ability can make OTHERS unusable too (has_attacked), so
	# refresh every slot's disabled state, not just the one that fired.
	_update_slot_states()


func _update_slot_states() -> void:
	for slot in _slots:
		if not is_instance_valid(slot):
			continue
		slot.set_armed(slot.ability == AbilityManager.armed_ability)
		slot.disabled = slot.ability.uses_attack_action and slot.unit.has_attacked


func _clear() -> void:
	for slot in _slots:
		if is_instance_valid(slot):
			slot.queue_free()
	_slots.clear()
