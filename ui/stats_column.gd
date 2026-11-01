class_name StatsColumn
extends MarginContainer
## Reusable character-stats block — shown in BOTH party_overview.tscn's
## Inventory and Character tabs (same data, same component, matching
## unit_portrait.gd's own "one shared component instanced wherever it's
## needed" precedent rather than two copies of the same onready refs
## silently drifting out of sync with each other).
##
## ST/DX/IQ/HT/Will/Per, HP/FP, DR, and Move (with Air Move for a unit
## that can fly).

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


func _fraction(current: int, maximum: int) -> float:
	if maximum <= 0:
		return 0.0
	return clampf(float(current) / float(maximum), 0.0, 1.0)
