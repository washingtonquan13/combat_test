class_name SfzEventList
extends RefCounted

# A compiled piece's events, held as columns rather than one Dictionary each.
#
# The compilers emit Dictionaries (see SfzScoreCompiler) and everything that
# reads a compile directly keeps them. A prepared player holds its piece for
# as long as it plays, though, and so does a preloaded one: a loop written
# out once per variation is tens of thousands of events, and as Dictionaries
# each cost about 930 bytes - 17 MB for the combat score, held twice when the
# next piece is preloaded beside it. As columns each costs about 45.
#
# at() builds the event back as the very Dictionary it was: the same keys in
# the same order, each value of the same type. An event that does not have
# one of the four compiled shapes exactly - a marker the player makes for
# itself, a key a compiler starts adding - is kept as it came, so packing can
# never change what plays; it only stops saving memory for that event.
#
# Every at() is a new Dictionary, so changing one changes nothing held here.
# `for event: Dictionary in list` iterates the same way.

const KINDS: Array[String] = ["note", "hit", "cc", "art"]
# Each kind's keys, in the order the compilers write them. A lane in an
# intensity layer adds "layer" just before "section".
const SHAPES := {
	"note": ["kind", "t", "part", "key", "velocity", "duration", "perf", "section"],
	"hit": ["kind", "t", "part", "drum", "velocity", "perf", "section"],
	"cc": ["kind", "t", "part", "control", "value", "perf", "section"],
	"art": ["kind", "t", "part", "art", "perf", "section"],
}
const AS_IT_CAME := 255
const NO_LAYER := -1

var _kind := PackedByteArray()      # index into KINDS, or AS_IT_CAME
var _t := PackedFloat64Array()
var _part := PackedInt32Array()     # these four index _values
var _perf := PackedInt32Array()
var _text := PackedInt32Array()     # drum, control or art
var _layer := PackedInt32Array()    # or NO_LAYER
var _section := PackedInt32Array()
var _number := PackedInt32Array()   # key, or a control's valuewd
var _velocity := PackedInt32Array()
var _duration := PackedFloat64Array()
var _values: Array = []             # each distinct string and layer once
var _as_it_came := {}               # index -> the event, for any other shape


static func pack(events: Array) -> SfzEventList:
	var list := SfzEventList.new()
	var n := events.size()
	list._kind.resize(n)
	list._t.resize(n)
	list._part.resize(n)
	list._perf.resize(n)
	list._text.resize(n)
	list._layer.resize(n)
	list._section.resize(n)
	list._number.resize(n)
	list._velocity.resize(n)
	list._duration.resize(n)
	var seen := {}
	for i in n:
		var event: Dictionary = events[i]
		var kind := KINDS.find(event.get("kind", ""))
		if kind < 0 or not _fits(event):
			list._kind[i] = AS_IT_CAME
			list._as_it_came[i] = event
			continue
		list._kind[i] = kind
		list._t[i] = event["t"]
		list._part[i] = list._value(event["part"], seen)
		list._perf[i] = list._value(event["perf"], seen)
		list._layer[i] = list._value(event["layer"], seen) if event.has("layer") else NO_LAYER
		list._section[i] = event["section"]
		match KINDS[kind]:
			"note":
				list._number[i] = event["key"]
				list._velocity[i] = event["velocity"]
				list._duration[i] = event["duration"]
			"hit":
				list._text[i] = list._value(event["drum"], seen)
				list._velocity[i] = event["velocity"]
			"cc":
				list._text[i] = list._value(event["control"], seen)
				list._number[i] = event["value"]
			"art":
				list._text[i] = list._value(event["art"], seen)
	return list


# Whether `event` has its kind's keys in their order, every value of the type
# at() gives back, and every int within a column's reach.
static func _fits(event: Dictionary) -> bool:
	var shape: Array = SHAPES[event["kind"]]
	var keys := event.keys()
	if event.has("layer"):
		shape = shape.duplicate()
		shape.insert(shape.size() - 1, "layer")
		if typeof(event["layer"]) != TYPE_ARRAY:
			return false
	if keys != shape:
		return false
	for key: String in keys:
		var value: Variant = event[key]
		match key:
			"t", "duration":
				if typeof(value) != TYPE_FLOAT:
					return false
			"section", "key", "velocity", "value":
				if typeof(value) != TYPE_INT or value != clampi(value, -0x80000000, 0x7fffffff):
					return false
			"kind", "part", "perf", "drum", "control", "art":
				if typeof(value) != TYPE_STRING:
					return false
	return true


func _value(value: Variant, seen: Dictionary) -> int:
	var at: int = seen.get(value, -1)
	if at < 0:
		at = _values.size()
		_values.append(value)
		seen[value] = at
	return at


func size() -> int:
	return _kind.size()


func is_empty() -> bool:
	return _kind.is_empty()


# The event at `i`, as the compiler wrote it.
func at(i: int) -> Dictionary:
	var kind := _kind[i]
	if kind == AS_IT_CAME:
		return (_as_it_came[i] as Dictionary).duplicate(true)
	var event := {"kind": KINDS[kind], "t": _t[i], "part": _values[_part[i]]}
	match kind:
		0:
			event["key"] = _number[i]
			event["velocity"] = _velocity[i]
			event["duration"] = _duration[i]
		1:
			event["drum"] = _values[_text[i]]
			event["velocity"] = _velocity[i]
		2:
			event["control"] = _values[_text[i]]
			event["value"] = _number[i]
		3:
			event["art"] = _values[_text[i]]
	event["perf"] = _values[_perf[i]]
	if _layer[i] != NO_LAYER:
		event["layer"] = (_values[_layer[i]] as Array).duplicate()
	event["section"] = _section[i]
	return event


# The parts of at() the player reads for every event, without building it.
func t_at(i: int) -> float:
	return _t[i] if _kind[i] != AS_IT_CAME else float(_as_it_came[i]["t"])


func kind_at(i: int) -> String:
	return KINDS[_kind[i]] if _kind[i] != AS_IT_CAME else String(_as_it_came[i]["kind"])


func to_array() -> Array:
	var out: Array = []
	out.resize(size())
	for i in size():
		out[i] = at(i)
	return out


func _iter_init(iter: Array) -> bool:
	iter[0] = 0
	return size() > 0


func _iter_next(iter: Array) -> bool:
	iter[0] += 1
	return iter[0] < size()


func _iter_get(iter: Variant) -> Variant:
	return at(iter)
