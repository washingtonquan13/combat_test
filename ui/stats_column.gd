class_name StatsColumn
extends MarginContainer
## Reusable character-stats block — shown in BOTH party_overview.tscn's
## Inventory and Character tabs (same data, same component, matching
## unit_portrait.gd's own "one shared component instanced wherever it's
## needed" precedent rather than two copies of the same onready refs
## silently drifting out of sync with each other).
##
## HP/FP, ST/DX/IQ/HT/Will/Per, Basic Speed, Move (with Air Move for a
## unit that can fly), Thrust/Swing; the active defenses and DR; every
## attack the unit has now, both weapon sets at once since both are
## always live; and its conditions.

@onready var _name_label: Label = %NameLabel
@onready var _hp_value: Label = %HPValue
@onready var _hp_fill: ColorRect = %HPFill
@onready var _fp_value: Label = %FPValue
@onready var _fp_fill: ColorRect = %FPFill
@onready var _st_value: Label = %STValue
@onready var _dx_value: Label = %DXValue
@onready var _iq_value: Label = %IQValue
@onready var _ht_value: Label = %HTValue
@onready var _will_value: Label = %WillValue
@onready var _per_value: Label = %PerValue
@onready var _dr_value: Label = %DRValue
@onready var _move_value: Label = %MoveValue
@onready var _thrust_value: Label = %ThrustValue
@onready var _swing_value: Label = %SwingValue
@onready var _basic_speed_value: Label = %BasicSpeedValue
@onready var _dodge_value: Label = %DodgeValue
@onready var _parry_value: Label = %ParryValue
@onready var _block_value: Label = %BlockValue
@onready var _defense_note: Label = %DefenseNote
@onready var _attack_list: VBoxContainer = %AttackList
@onready var _condition_list: HFlowContainer = %ConditionList

const DIM := Color(1, 1, 1, 0.5)


func refresh(unit: Unit) -> void:
	_name_label.text = unit.get_display_name()

	_hp_value.text = "%d / %d" % [unit.get_pool(StatIds.HP), unit.get_stat(StatIds.HP)]
	_hp_fill.anchor_right = _fraction(unit.get_pool(StatIds.HP), floori(unit.get_stat(StatIds.HP)))
	_fp_value.text = "%d / %d" % [unit.get_pool(StatIds.FP), unit.get_stat(StatIds.FP)]
	_fp_fill.anchor_right = _fraction(unit.get_pool(StatIds.FP), floori(unit.get_stat(StatIds.FP)))

	_st_value.text = StatDefinition.format(unit.get_stat(StatIds.ST))
	_dx_value.text = StatDefinition.format(unit.get_stat(StatIds.DX))
	_iq_value.text = StatDefinition.format(unit.get_stat(StatIds.IQ))
	_ht_value.text = StatDefinition.format(unit.get_stat(StatIds.HT))
	_will_value.text = StatDefinition.format(unit.get_stat(StatIds.WILL))
	_per_value.text = StatDefinition.format(unit.get_stat(StatIds.PER))

	_dr_value.text = StatDefinition.format(unit.get_stat(StatIds.DR))
	_move_value.text = StatDefinition.format(unit.get_stat(StatIds.MOVE))
	if unit.can_fly():
		_move_value.text += ", Air %s" % StatDefinition.format(unit.get_stat(StatIds.AIR_MOVE))

	_thrust_value.text = unit.describe_damage(UnitCombat.DamageType.THRUST, 0)
	_swing_value.text = unit.describe_damage(UnitCombat.DamageType.SWING, 0)
	_basic_speed_value.text = "%.2f" % unit.get_stat(StatIds.BASIC_SPEED)

	_dodge_value.text = str(unit.dodge_target())
	_parry_value.text = str(unit.parry_target())
	_block_value.text = str(unit.block_target()) if unit.holds_shield() else "–"
	var db: int = floori(unit.get_stat(StatIds.DB))
	_defense_note.text = "Shield DB +%d included" % db if db > 0 else ""
	_defense_note.visible = db > 0

	_refresh_attacks(unit)
	_refresh_conditions(unit)


## One row per weapon attack: name, damage, the number to roll against
## (no target, so no range or SM), and ½D/Max for a ranged one. Abilities
## with no attack row behind them (Reload) are not attacks.
func _refresh_attacks(unit: Unit) -> void:
	for child in _attack_list.get_children():
		child.queue_free()
	for ability in unit.combat_abilities():
		var gear: GearDamageEffect = null
		for effect in ability.effects:
			if effect is GearDamageEffect:
				gear = effect
		if not gear or not gear.row:
			continue
		var detail: String = "%s · %d" % [gear.row.describe_damage(unit), unit.to_hit_target(null, ability)]
		if gear.row.kind == AttackRow.Kind.RANGED:
			detail += " · %s/%s" % [StatDefinition.format(gear.row.half_damage_range), StatDefinition.format(gear.row.max_range)]
		_attack_list.add_child(_row(ability.ability_name, detail))
	if _attack_list.get_child_count() == 0:
		var none := Label.new()
		none.text = "No attacks."
		none.modulate = DIM
		_attack_list.add_child(none)


func _refresh_conditions(unit: Unit) -> void:
	for child in _condition_list.get_children():
		child.queue_free()
	var statuses: Array[StatusEffect] = unit.active_statuses()
	if statuses.is_empty():
		var none := Label.new()
		none.text = "None"
		none.modulate = DIM
		_condition_list.add_child(none)
	for status in statuses:
		var chip := Label.new()
		chip.text = status.status_name
		_condition_list.add_child(chip)


func _row(left: String, right: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	var name_label := Label.new()
	name_label.text = left
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.clip_text = true
	var value_label := Label.new()
	value_label.text = right
	row.add_child(name_label)
	row.add_child(value_label)
	return row


func _fraction(current: int, maximum: int) -> float:
	if maximum <= 0:
		return 0.0
	return clampf(float(current) / float(maximum), 0.0, 1.0)
