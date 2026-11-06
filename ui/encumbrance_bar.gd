class_name EncumbranceBar
extends VBoxContainer
## The weight a unit wears against its encumbrance levels, under the
## weapon sets on the Inventory tab. One segment per level (None to
## Extra-Heavy), in order under Segments — each a ProgressBar spanning
## that level's band of Basic Lifts, so the bar reads like a CRPG
## carry meter while the bands stay GURPS's uneven 1/2/3/6/10.
## Hovering shows the numbers behind it (StatTip).

@onready var _level_label: Label = %LevelLabel
@onready var _weight_label: Label = %WeightLabel
@onready var _segments: HBoxContainer = %Segments

const DIM := Color(0.553, 0.541, 0.502, 1)


func refresh(unit: Unit) -> void:
	var levels: Array = UnitEquipment.ENCUMBRANCE_LEVELS
	var weight: float = unit.worn_weight()
	var lift: float = unit.basic_lift()
	var level: int = unit.encumbrance_level()
	_level_label.text = levels[level].name
	var fill: StyleBoxFlat = _segments.get_child(level).get_node("Bar").get_theme_stylebox("fill")
	_level_label.add_theme_color_override("font_color", fill.bg_color if level > 0 else DIM)
	_weight_label.text = "%s / %s lb" % [_lb(weight), _lb(lift * levels[-1].limit)]
	var floor_lb: float = 0.0
	for i in _segments.get_child_count():
		var segment: Control = _segments.get_child(i)
		var bar: ProgressBar = segment.get_node("Bar")
		bar.min_value = floor_lb
		bar.max_value = lift * levels[i].limit
		bar.value = weight
		floor_lb = bar.max_value
		var name_label: Label = segment.get_node("Name")
		name_label.modulate = Color.WHITE if i == level else DIM
	tooltip_text = _tip(unit, weight, lift, level)


func _tip(unit: Unit, weight: float, lift: float, level: int) -> String:
	var levels: Array = UnitEquipment.ENCUMBRANCE_LEVELS
	var lines: PackedStringArray = ["Encumbrance: %s" % levels[level].name,
			"What is worn and wielded, against Basic Lift (ST × ST ÷ 5). Each level lowers Move and Dodge; nothing more can be put on past %d × Basic Lift. The party bag doesn't count." % levels[-1].limit]
	lines.append("Basic Lift (ST %s)\t%s lb" % [StatDefinition.format(unit.get_stat_unhalved(StatIds.ST)), _lb(lift)])
	lines.append("Worn\t%s lb" % _lb(weight))
	lines.append("Levels")
	for i in levels.size():
		var effect: String = "—" if i == 0 else "Move ×%s, Dodge −%d" % [String.num(levels[i].move), i]
		lines.append("%s, to %s lb\t%s" % [levels[i].name, _lb(lift * levels[i].limit), effect])
	return "\n".join(lines)


func _make_custom_tooltip(for_text: String) -> Object:
	return StatTip.build(for_text)


## Whole pounds plain, a half-pound glove as "0.5".
static func _lb(pounds: float) -> String:
	var rounded: float = snappedf(pounds, 0.1)
	return str(int(rounded)) if is_equal_approx(rounded, roundf(rounded)) else "%.1f" % rounded
