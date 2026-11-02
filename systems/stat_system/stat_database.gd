@tool
class_name StatDatabase
extends RefCounted
## Every stat in the game — whatever StatDefinition files sit in
## res://data/stats/. Static, scan-once-and-cache, the same shape as
## SkillDatabase, with one addition: it CHECKS what it loads, once, before
## anything reads a stat. A formula that does not parse, names a stat that
## does not exist, or depends on itself through other stats is reported
## by name the moment the database loads, instead of quietly reading 0 in
## the middle of a fight.
##
## @tool only so the Inspector can offer stat ids as suggestions
## (editor_ids below) for fields like StatModifierBehavior.stat_name; the
## runtime path never runs in the editor.

const STATS_DIR: String = "res://data/stats/"

static var _catalog: ResourceCatalog
## Sorted by StatDefinition.order — what every stat list shows.
static var _ordered: Array[StatDefinition] = []
## Derived stats in an order where each comes after every stat it reads.
static var _derived_order: Array[StatDefinition] = []
## Parsed once per derived stat: {expression: Expression, inputs: PackedStringArray}.
static var _formulas: Dictionary = {}
static var _loaded: bool = false


## Null for an id no stat file declares.
static func find(id: StringName) -> StatDefinition:
	_ensure_loaded()
	return _catalog.find(id) as StatDefinition


static func has(id: StringName) -> bool:
	return find(id) != null


## Every stat, in display order.
static func get_all() -> Array[StatDefinition]:
	_ensure_loaded()
	return _ordered


## The stats chargen buys with points — those with a point_buy table.
static func get_bought() -> Array[StatDefinition]:
	var result: Array[StatDefinition] = []
	for definition in get_all():
		if definition.point_buy != null:
			result.append(definition)
	return result


## A derived stat's formula as a reader sees it, each input named and
## valued — "floor(Speed 7.25) + 3" — for a tooltip's breakdown.
static func describe_formula(definition: StatDefinition, values: Dictionary) -> String:
	var text: String = definition.formula.replace("floori(", "floor(")
	for input_id in inputs_of(definition):
		var input := find(StringName(input_id))
		var named: String = "%s %s" % [input.label(), StatDefinition.format(values.get(StringName(input_id), 0.0))]
		var word := RegEx.create_from_string("\\b%s\\b" % input_id)
		text = word.sub(text, named, true)
	return text


## A derived stat's formula result for these input values (id -> float),
## fraction kept.
static func evaluate(definition: StatDefinition, values: Dictionary) -> float:
	_ensure_loaded()
	var parsed: Dictionary = _formulas.get(definition.id, {})
	if parsed.is_empty():
		return 0
	var inputs: Array = []
	for input_id in parsed.inputs:
		inputs.append(values.get(StringName(input_id), 0))
	var expression: Expression = parsed.expression
	var result: Variant = expression.execute(inputs, null, false)
	if expression.has_execute_failed() or not (result is int or result is float):
		push_error("Stat '%s': formula '%s' failed: %s" % [definition.id, definition.formula, expression.get_error_text()])
		return 0
	return float(result)


## One stat's full value: a primary's base, or a derived stat's formula
## over its inputs' full values plus its own bonus — then, either way,
## its modifiers, then its multiplier (multiplier_of(id) -> float, left
## out where nothing can multiply — a species with no unit, chargen),
## rounded up. A multiplier is a halving of the stat itself (B419,
## B426), so a derived stat reads its inputs whole: Exhausted halves ST
## but not the HP that ST sets. base_of(id) -> int and modifier_of(id) -> int supply
## the per-unit numbers, so the same arithmetic serves a live unit
## (UnitStats) and a species with no unit at all (UnitDefinition).
## Recomputed on every read, never cached: a status landing or a gear
## swap is reflected the next time anything asks.
## Fractions are kept (Basic Speed 5.25); a caller that needs a whole
## number — a roll target, DR against whole damage — drops it with floori,
## as GURPS does.
static func value_of(id: StringName, base_of: Callable, modifier_of: Callable, multiplier_of: Callable = Callable()) -> float:
	var definition := find(id)
	if definition == null:
		push_error("No stat '%s' — see res://data/stats/." % id)
		return 0.0
	var value: float = base_of.call(id)
	if definition.is_derived():
		var inputs: Dictionary = {}
		for input_id in inputs_of(definition):
			inputs[StringName(input_id)] = value_of(StringName(input_id), base_of, modifier_of)
		value += evaluate(definition, inputs)
	value += int(modifier_of.call(id))
	if multiplier_of.is_valid():
		var multiplier: float = multiplier_of.call(id)
		if multiplier != 1.0:
			value = ceilf(value * multiplier)
	return value


## The ids a derived stat's formula reads.
static func inputs_of(definition: StatDefinition) -> PackedStringArray:
	_ensure_loaded()
	return _formulas.get(definition.id, {}).get("inputs", PackedStringArray())


static func derived_in_order() -> Array[StatDefinition]:
	_ensure_loaded()
	return _derived_order


## Forces a re-scan — after adding or editing a stat file at runtime.
static func refresh() -> void:
	_loaded = false
	if _catalog:
		_catalog.refresh()
	_ensure_loaded()


## Stat ids for an Inspector suggestion list. Read straight off the files:
## in the editor the stat scripts are placeholders, so nothing here may
## call into ResourceCatalog.
static func editor_ids() -> PackedStringArray:
	var ids := PackedStringArray()
	for file in DirAccess.get_files_at(STATS_DIR):
		file = file.trim_suffix(".remap")
		if not file.ends_with(".tres"):
			continue
		var resource: Resource = load(STATS_DIR + file)
		if resource and resource.get("id"):
			ids.append(String(resource.get("id")))
	return ids


## Suggestion hint for a property naming a stat — call from a @tool
## resource's _validate_property.
static func suggest_ids(property: Dictionary) -> void:
	property.hint = PROPERTY_HINT_ENUM_SUGGESTION
	property.hint_string = ",".join(editor_ids())


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	if not _catalog:
		var extract_id := func(resource: Resource) -> Variant:
			var definition := resource as StatDefinition
			return definition.id if definition and definition.id != &"" else null
		# First wins plus the duplicate check below: two files claiming one
		# id is an authoring mistake to report, not a tie to break quietly.
		_catalog = ResourceCatalog.new(STATS_DIR, false, extract_id, true, false, true)

	_ordered.clear()
	var seen: Dictionary = {}
	for resource in _catalog.all():
		var definition := resource as StatDefinition
		if seen.has(definition.id):
			push_error("Stats: two files declare id '%s' (%s and %s); the first is used." % [definition.id, seen[definition.id], definition.resource_path])
			continue
		seen[definition.id] = definition.resource_path
		_ordered.append(definition)
	_ordered.sort_custom(func(a: StatDefinition, b: StatDefinition) -> bool:
		return a.order < b.order if a.order != b.order else String(a.id) < String(b.id))
	if _ordered.is_empty():
		push_error("Stats: no stat definitions found under %s." % STATS_DIR)

	_parse_formulas()
	_order_derived()


static func _parse_formulas() -> void:
	_formulas.clear()
	var ids: Array = []
	for definition in _ordered:
		ids.append(String(definition.id))
	var identifier := RegEx.create_from_string("[A-Za-z_][A-Za-z0-9_]*")
	for definition in _ordered:
		if not definition.is_derived():
			continue
		if definition.formula.strip_edges() == "":
			push_error("Stat '%s' is derived but has no formula." % definition.id)
			continue
		# Only the names the formula actually uses become inputs, so the
		# expression is executed with a short array, not every stat.
		var inputs := PackedStringArray()
		# Names that are neither a stat nor a call — Expression's own error
		# for these ("self can't be used") does not say which name.
		var unknown := PackedStringArray()
		for found in identifier.search_all(definition.formula):
			var name: String = found.get_string()
			if name in ids:
				if not name in inputs:
					inputs.append(name)
			elif not definition.formula.substr(found.get_end()).strip_edges().begins_with("("):
				unknown.append(name)
		if not unknown.is_empty():
			push_error("Stat '%s': formula '%s' names no stat called %s — see res://data/stats/." % [definition.id, definition.formula, ", ".join(unknown)])
			continue
		var expression := Expression.new()
		if expression.parse(definition.formula, inputs) != OK:
			push_error("Stat '%s': formula '%s' does not parse: %s" % [definition.id, definition.formula, expression.get_error_text()])
			continue
		# A trial run with every input at 10 catches the rest — a name that
		# is not a stat, a function that does not exist — at load, not in
		# play.
		var trial: Array = []
		trial.resize(inputs.size())
		trial.fill(10)
		var result: Variant = expression.execute(trial, null, false)
		if expression.has_execute_failed() or not (result is int or result is float):
			push_error("Stat '%s': formula '%s' does not evaluate: %s" % [definition.id, definition.formula, expression.get_error_text()])
			continue
		_formulas[definition.id] = {"expression": expression, "inputs": inputs}


static func _order_derived() -> void:
	_derived_order.clear()
	var state: Dictionary = {}  # id -> 1 visiting, 2 done
	for definition in _ordered:
		if definition.is_derived():
			_visit(definition, state, [])


static func _visit(definition: StatDefinition, state: Dictionary, path: Array) -> void:
	var mark: int = state.get(definition.id, 0)
	if mark == 2:
		return
	if mark == 1:
		push_error("Stats: formulas depend on each other in a loop: %s." % " -> ".join(path + [String(definition.id)]))
		_formulas.erase(definition.id)
		return
	state[definition.id] = 1
	for input_id in _formulas.get(definition.id, {}).get("inputs", PackedStringArray()):
		var input: StatDefinition = _catalog.find(StringName(input_id)) as StatDefinition
		if input and input.is_derived():
			_visit(input, state, path + [String(definition.id)])
	state[definition.id] = 2
	_derived_order.append(definition)
