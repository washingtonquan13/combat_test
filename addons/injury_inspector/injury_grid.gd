@tool
extends VBoxContainer
## The grid behind injury_inspector.gd. edit_row() is a BodyRow's numbers,
## one wound type per line; show_effective() is a read-only table of every
## location of an InjuryProfile, cells the preset or a missing location
## changed tinted, with the reason in the tooltip.

const W := DamageResolver.WoundType
const CHANGED := Color(1.0, 0.75, 0.35)
const FIELDS: PackedStringArray = ["Mult", "Max", "DR"]

var _row: BodyRow
var _spins: Array[SpinBox] = []
var _source: Object
var _table: GridContainer


func edit_row(row: BodyRow) -> void:
	_row = row
	var grid := GridContainer.new()
	grid.columns = 4
	add_child(grid)
	for heading in ["Type"] + Array(FIELDS):
		grid.add_child(_label(heading, true))
	for wound_type in W.size():
		grid.add_child(_label(DamageResolver.ABBREVIATION[wound_type]))
		for field in InjuryRule.Field.size():
			var spin := SpinBox.new()
			spin.min_value = 0.0
			spin.max_value = 99.0
			spin.step = 0.01 if field == InjuryRule.Field.MULTIPLIER else 1.0
			spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			spin.tooltip_text = ["0 is immune", "0 is no cap", "added to the unit's DR"][field]
			spin.value_changed.connect(_on_spin.bind(field, wound_type))
			grid.add_child(spin)
			_spins.append(spin)
	row.changed.connect(_refresh_row)
	_refresh_row()


func show_effective(source: Object) -> void:
	_source = source
	var title := _label("Effective injury", true)
	title.tooltip_text = "What each wound type does per location, preset applied. Tinted cells were changed by the preset or a missing location."
	add_child(title)
	_table = GridContainer.new()
	add_child(_table)
	EditorInterface.get_inspector().property_edited.connect(_refresh_table.unbind(1))
	if source is Resource:
		source.changed.connect(_refresh_table)
	_refresh_table()


func _on_spin(value: float, field: int, wound_type: int) -> void:
	var property: String = ["multipliers", "max_injury", "dr"][field]
	var before: Variant = _row.get(property)
	var after: Variant = before.duplicate()
	after[wound_type] = value
	var undo := EditorInterface.get_editor_undo_redo()
	undo.create_action("Set %s %s" % [DamageResolver.ABBREVIATION[wound_type], FIELDS[field]], UndoRedo.MERGE_ENDS)
	undo.add_do_property(_row, property, after)
	undo.add_do_method(_row, "emit_changed")
	undo.add_undo_property(_row, property, before)
	undo.add_undo_method(_row, "emit_changed")
	undo.commit_action()


func _refresh_row() -> void:
	for wound_type in W.size():
		for field in InjuryRule.Field.size():
			_spins[wound_type * 3 + field].set_value_no_signal(_row.get_value(field, wound_type))


func _refresh_table() -> void:
	if not is_instance_valid(_table):
		return
	for child in _table.get_children():
		child.queue_free()
	var plan: BodyPlan = BodyPlan.human()
	var preset: InjuryPreset
	var missing: Array[HitLocation] = []
	if _source is BodyPlan:
		plan = _source
	elif _source is InjuryPreset:
		preset = _source
	elif _source is UnitDefinition:
		if _source.body_plan:
			plan = _source.body_plan
		preset = _source.injury_preset
		missing.assign(_source.missing_locations)
	# The rows and the preset are sub-resources; an edit to one doesn't
	# reach the inspector's property_edited or the source's own changed.
	var watched: Array[Resource] = [plan, preset]
	if preset:
		watched.append_array(preset.rules)
	if plan:
		watched.append_array(plan.rows())
	for resource in watched:
		if resource and not resource.changed.is_connected(_refresh_table):
			resource.changed.connect(_refresh_table)
	if plan == null or plan.torso == null:
		_table.columns = 1
		_table.add_child(_label("No torso row on the plan"))
		return
	var profile := InjuryProfile.build(plan, preset, missing, true)
	var rows: Array[BodyRow] = profile.rows()
	_table.columns = rows.size() + 1
	_table.add_child(_label(""))
	for index in rows.size():
		var location: HitLocation = plan.rows()[index].location
		_table.add_child(_label(location.display_name if location else "?", true))
	for wound_type in W.size():
		_table.add_child(_label(DamageResolver.ABBREVIATION[wound_type], true))
		for index in rows.size():
			_table.add_child(_cell(profile, rows[index], index, wound_type))


func _cell(profile: InjuryProfile, row: BodyRow, index: int, wound_type: int) -> Label:
	var text: String = "x" + String.num(row.multipliers[wound_type], 2)
	if row.multipliers[wound_type] <= 0.0:
		text = "immune"
	if row.max_injury[wound_type] > 0:
		text += " max %d" % row.max_injury[wound_type]
	if row.dr[wound_type] > 0:
		text += " DR+%d" % row.dr[wound_type]
	var cell := _label(text)
	var names := PackedStringArray()
	for field in InjuryRule.Field.size():
		var source: String = profile.sources.get("%d:%d:%d" % [index, field, wound_type], "")
		if source != "" and not names.has(source):
			names.append(source)
	if not names.is_empty():
		cell.add_theme_color_override("font_color", CHANGED)
		cell.tooltip_text = ", ".join(names)
	return cell


func _label(text: String, bold: bool = false) -> Label:
	var label := Label.new()
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_PASS
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if bold and Engine.is_editor_hint():
		label.add_theme_font_override("font", EditorInterface.get_editor_theme().get_font("bold", "EditorFonts"))
	return label
