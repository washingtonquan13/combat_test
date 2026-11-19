class_name FaceDriver
extends Node
## Moves a face that is made of blend shapes: blinks on its own, holds an
## expression, and mouths whatever line it is given.
##
## Belongs to a CharacterModel whose meshes carry the ARKit face units
## (eyeBlinkLeft, jawOpen, mouthSmileLeft...) and the Meta visemes
## (viseme_aa, viseme_PP...), which is what tools/characters/bake_character.py
## puts on every MPFB human. Every mesh under the model that has a shape of
## the right name follows it, so a blink takes the lids AND the lashes and
## an open jaw takes the teeth and tongue along.
##
## A rig that names its shapes otherwise (Character Creator: Eye_Blink_L,
## V_Open...) says so with shape_names; one name may drive several shapes.
##
## The mouth is read from the TEXT, letter by letter, not from audio: there
## is no voice to listen to yet. That is enough to make a line look spoken
## rather than mimed, and talk() is the one place a real lip-sync track
## would replace it.

## Shape weights per expression name. An expression is held until another
## replaces it; "neutral" is all of them at rest.
const EXPRESSIONS: Dictionary = {
	&"neutral": {},
	&"smile": {"mouthSmileLeft": 0.8, "mouthSmileRight": 0.8,
			"cheekSquintLeft": 0.4, "cheekSquintRight": 0.4},
	&"frown": {"mouthFrownLeft": 0.7, "mouthFrownRight": 0.7,
			"browInnerUp": 0.5},
	&"angry": {"browDownLeft": 1.0, "browDownRight": 1.0,
			"noseSneerLeft": 0.5, "noseSneerRight": 0.5,
			"mouthFrownLeft": 0.5, "mouthFrownRight": 0.5},
	&"surprised": {"browInnerUp": 0.9, "browOuterUpLeft": 0.8,
			"browOuterUpRight": 0.8, "eyeWideLeft": 0.7, "eyeWideRight": 0.7,
			"jawOpen": 0.25},
	&"wary": {"eyeSquintLeft": 0.5, "eyeSquintRight": 0.5,
			"browDownLeft": 0.35, "browDownRight": 0.35,
			"mouthPressLeft": 0.4, "mouthPressRight": 0.4},
}

## Letters to the viseme that shapes them. Two-letter sounds are checked
## first. Anything not here (digits, symbols) leaves the mouth where it was.
const DIGRAPHS: Dictionary = {"th": "viseme_TH", "sh": "viseme_CH",
		"ch": "viseme_CH", "ee": "viseme_I", "oo": "viseme_U"}
const LETTERS: Dictionary = {
	"a": "viseme_aa", "e": "viseme_E", "i": "viseme_I", "y": "viseme_I",
	"o": "viseme_O", "u": "viseme_U", "w": "viseme_U",
	"p": "viseme_PP", "b": "viseme_PP", "m": "viseme_PP",
	"f": "viseme_FF", "v": "viseme_FF",
	"t": "viseme_DD", "d": "viseme_DD", "l": "viseme_DD",
	"k": "viseme_kk", "g": "viseme_kk", "c": "viseme_kk", "q": "viseme_kk",
	"s": "viseme_SS", "z": "viseme_SS", "x": "viseme_SS",
	"n": "viseme_nn", "r": "viseme_RR", "j": "viseme_CH", "h": "viseme_sil",
}

## Seconds a letter is held. About fifteen letters a second is how fast
## people talk.
@export_range(0.02, 0.2, 0.005, "suffix:s") var seconds_per_letter: float = 0.065
## How long a comma or full stop closes the mouth for.
@export_range(0.0, 1.0, 0.01, "suffix:s") var pause_seconds: float = 0.22
## How far a viseme goes. Full strength reads as shouting.
@export_range(0.0, 1.0, 0.05) var mouth_strength: float = 0.75
## How fast every shape chases where it is meant to be, per second. Higher
## snaps; lower slurs one sound into the next.
@export_range(1.0, 60.0, 0.5) var follow_rate: float = 22.0
## This rig's names for the shapes above; null for ARKit and Meta names.
@export var shape_names: FaceShapeNames
@export var blinks: bool = true
@export_range(0.5, 10.0, 0.1, "suffix:s") var blink_every_min: float = 2.2
@export_range(0.5, 10.0, 0.1, "suffix:s") var blink_every_max: float = 5.5

const BLINK_SECONDS: float = 0.16

## mesh -> {shape name: index}
var _shape_index: Dictionary = {}
var _current: Dictionary = {}
var _expression: Dictionary = {}
var _expression_from: Dictionary = {}
var _expression_fade: float = 0.0
var _expression_elapsed: float = 0.0
## Each entry is [viseme name or "", seconds held].
var _mouth_track: Array = []
var _mouth_elapsed: float = 0.0
var _blink_in: float = 0.0
var _blink_elapsed: float = -1.0


## The face [param unit]'s body declares, or null if it has none.
static func of(unit: Node) -> FaceDriver:
	if unit == null:
		return null
	# The face on screen: a unit shown by a stand-in talks with the copy's.
	var body: CharacterModel = StandIn.body_of(unit)
	return body.face if body and is_instance_valid(body.face) else null


func _ready() -> void:
	var body: Node = get_parent()
	for mesh in body.find_children("*", "MeshInstance3D", true, false):
		var instance := mesh as MeshInstance3D
		# Only an ArrayMesh carries blend shapes; a primitive (the highlight
		# disc) has none to ask about.
		var array_mesh := instance.mesh as ArrayMesh
		if array_mesh == null or array_mesh.get_blend_shape_count() == 0:
			continue
		# Name -> the shape indices it drives.
		var shapes: Dictionary = {}
		for i in array_mesh.get_blend_shape_count():
			shapes[String(array_mesh.get_blend_shape_name(i))] = [i]
		if shape_names:
			for name in shape_names.names:
				var indices: Array = []
				for own in shape_names.names[name]:
					indices.append_array(shapes.get(own, []))
				if not indices.is_empty():
					shapes[name] = indices
		_shape_index[instance] = shapes
	_blink_in = randf_range(blink_every_min, blink_every_max)
	set_process(not _shape_index.is_empty())


## Mouths [param text] from now, for as long as it takes to say.
func talk(text: String) -> void:
	_mouth_track = _track_for(text.to_lower())
	_mouth_elapsed = 0.0


## Closes the mouth now, mid-word or not.
func hush() -> void:
	_mouth_track.clear()


func is_talking() -> bool:
	return not _mouth_track.is_empty()


## Moves to a named expression over [param fade_seconds], at [param weight]
## of its full strength. An unknown name is warned about and changes nothing.
func express(expression: StringName, weight: float = 1.0, fade_seconds: float = 0.25) -> void:
	if not EXPRESSIONS.has(expression):
		push_warning("FaceDriver: no expression called '%s'." % expression)
		return
	_expression_from = _expression_now()
	_expression = {}
	for shape in EXPRESSIONS[expression]:
		_expression[shape] = EXPRESSIONS[expression][shape] * weight
	_expression_fade = maxf(fade_seconds, 0.0)
	_expression_elapsed = 0.0


func _process(delta: float) -> void:
	var target: Dictionary = _expression_now()
	_expression_elapsed += delta

	var viseme: String = _viseme_now()
	_mouth_elapsed += delta
	if not _mouth_track.is_empty() and _mouth_elapsed >= _track_length():
		_mouth_track.clear()
	if viseme != "":
		target[viseme] = maxf(target.get(viseme, 0.0), mouth_strength)

	var lid: float = _blink_now(delta)
	if lid > 0.0:
		for shape in ["eyeBlinkLeft", "eyeBlinkRight"]:
			target[shape] = maxf(target.get(shape, 0.0), lid)

	var step: float = clampf(follow_rate * delta, 0.0, 1.0)
	for shape in target.keys() + _current.keys():
		var to: float = target.get(shape, 0.0)
		var now: float = lerpf(_current.get(shape, 0.0), to, step)
		# A blink is too quick to chase; it is set where it should be.
		if shape.begins_with("eyeBlink"):
			now = to
		if absf(now) < 0.001 and to == 0.0:
			_current.erase(shape)
			now = 0.0
		else:
			_current[shape] = now
		_apply(shape, now)


func _apply(shape: String, weight: float) -> void:
	for mesh in _shape_index:
		if not is_instance_valid(mesh):
			continue
		for index: int in _shape_index[mesh].get(shape, []):
			(mesh as MeshInstance3D).set_blend_shape_value(index, weight)


func _expression_now() -> Dictionary:
	var t: float = 1.0 if _expression_fade <= 0.0 else clampf(_expression_elapsed / _expression_fade, 0.0, 1.0)
	var blended: Dictionary = {}
	for shape in _expression_from.keys() + _expression.keys():
		blended[shape] = lerpf(_expression_from.get(shape, 0.0), _expression.get(shape, 0.0), t)
	return blended


func _blink_now(delta: float) -> float:
	if _blink_elapsed >= 0.0:
		_blink_elapsed += delta
		if _blink_elapsed >= BLINK_SECONDS:
			_blink_elapsed = -1.0
			return 0.0
		# Down fast, up a little slower, the way lids move.
		var half: float = BLINK_SECONDS * 0.4
		return _blink_elapsed / half if _blink_elapsed < half \
				else 1.0 - (_blink_elapsed - half) / (BLINK_SECONDS - half)
	if not blinks:
		return 0.0
	_blink_in -= delta
	if _blink_in <= 0.0:
		_blink_in = randf_range(blink_every_min, blink_every_max)
		_blink_elapsed = 0.0
	return 0.0


func _viseme_now() -> String:
	var at: float = 0.0
	for entry in _mouth_track:
		at += entry[1]
		if _mouth_elapsed < at:
			return entry[0]
	return ""


func _track_length() -> float:
	var total: float = 0.0
	for entry in _mouth_track:
		total += entry[1]
	return total


func _track_for(text: String) -> Array:
	var track: Array = []
	var i: int = 0
	while i < text.length():
		var pair: String = text.substr(i, 2)
		var letter: String = text[i]
		if DIGRAPHS.has(pair):
			track.append([DIGRAPHS[pair], seconds_per_letter * 1.5])
			i += 2
			continue
		if LETTERS.has(letter):
			track.append([LETTERS[letter], seconds_per_letter])
		elif letter in ",.;:!?—-":
			track.append(["", pause_seconds])
		elif letter == " ":
			track.append(["", seconds_per_letter * 0.5])
		i += 1
	return track
