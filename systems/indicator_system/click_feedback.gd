class_name ClickFeedback
extends Node3D
## What the player sees and hears the moment a click is decided, and the
## OS cursor between clicks. Owned by ClickRouter (built in its _ready)
## and told by it, at its decision points, what happened - this node
## decides nothing. A click that was taken gets a soft tick, and a move
## order also a shrinking white ring at the destination. A click that was
## refused gets a lower tick, a red ring and, when the router gave one, a
## short reason floating over the spot. Before this, a refused click and
## a click that missed looked identical: nothing happened either way.
##
## One node rather than calls scattered through the intents, so the look
## and sound of "yes" and "no" live in one place and every decision point
## reaches them the same way.
##
## Markers are top_level Decals, the same arrangement as the unit rings
## (UnitSelection): a decal paints whatever ground is under it, slopes and
## steps included, where a flat ribbon would float or sink, and its
## cull_mask leaves out Unit.RENDER_LAYER so a ring never paints a boot.

## Played on a click that was taken. Null means the code-built tick below,
## so the game needs no audio asset for this; drop a real stream in here
## to replace it.
@export var confirm_sound: AudioStream = null
## Played on a refused click. Null means the code-built low tick below.
@export var refuse_sound: AudioStream = null
## A UI sound, not a world one: non-positional, on Master (the project
## has only Master and Music).
@export var sound_bus: StringName = &"Master"
@export var confirm_volume_db: float = -14.0
@export var refuse_volume_db: float = -12.0

## Ring diameter at the start of the marker, in metres, and the fraction
## of it the ring shrinks to as it fades.
const MARKER_SIZE: float = 0.9
const MARKER_END_SCALE: float = 0.35
const MARKER_SECONDS: float = 0.5
## Ring width as a fraction of its radius - a UnitSelection ring texture,
## shared with every unit ring of that width.
const MARKER_RING_WIDTH: float = 0.22
## Decal box height: the vertical slop the ring tolerates, as for the
## unit rings (UnitSelection.DECAL_HEIGHT).
const MARKER_HEIGHT: float = 0.8
## A refusal's reason is read, not glanced at, so it stays a little
## longer than the ring and drifts up while it fades.
const REASON_SECONDS: float = 1.1
const REASON_HEIGHT: float = 0.9
const REASON_RISE: float = 0.35

var _confirm_player: AudioStreamPlayer
var _refuse_player: AudioStreamPlayer
## Only one reason is ever up: a second refusal replaces the first rather
## than stacking text over the same few cells while the player retries.
var _reason_label: Label3D = null
## What this node last set the OS default cursor to. Tracked so the
## router can hand in its answer every frame and Input only hears about
## changes - every set_default_cursor_shape sends a fake mouse motion
## through the input pipeline.
var _cursor_shape: Input.CursorShape = Input.CURSOR_ARROW


func _ready() -> void:
	_confirm_player = _make_player(confirm_sound if confirm_sound else _tick(1500.0, 1150.0, 0.04, 0.35, 120.0), confirm_volume_db)
	_refuse_player = _make_player(refuse_sound if refuse_sound else _tick(280.0, 190.0, 0.14, 0.4, 35.0), refuse_volume_db)


## The router carries this node between worlds (WorldManager reparents
## the attention nodes) and may be paused or disabled with a menu up; in
## every one of those it stops deciding the cursor, so the cursor must
## not stay saying "attack" over whatever is on screen next.
func _notification(what: int) -> void:
	if what == NOTIFICATION_EXIT_TREE or what == NOTIFICATION_PAUSED or what == NOTIFICATION_DISABLED:
		show_cursor(Input.CURSOR_ARROW)


## A move order was given: ring at the destination, tick.
func confirm_move(point) -> void:
	_confirm_player.play()
	if point is Vector3:
		_spawn_ring(point, IndicatorPalette.OK)


## A click was taken but needs no marker of its own (an ability cast -
## the cast itself is the answer on screen).
func confirm() -> void:
	_confirm_player.play()


## A click was refused. point may be null (the ray missed): then there is
## only the sound, since there is nowhere to put the ring or the reason.
func refuse(point, reason: String) -> void:
	_refuse_player.play()
	if not (point is Vector3):
		return
	_spawn_ring(point, IndicatorPalette.BLOCKED)
	if reason != "":
		_show_reason(point, reason)


## Sets the OS cursor. The router decides the shape; this only applies it
## when it changed. The default shape is what every Control left at
## CURSOR_ARROW shows too, so the router hands in the arrow whenever the
## mouse is over UI.
func show_cursor(shape: Input.CursorShape) -> void:
	if shape == _cursor_shape:
		return
	_cursor_shape = shape
	Input.set_default_cursor_shape(shape)


func _spawn_ring(point: Vector3, color: Color) -> void:
	var decal := Decal.new()
	decal.top_level = true
	decal.size = Vector3(MARKER_SIZE, MARKER_HEIGHT, MARKER_SIZE)
	decal.normal_fade = 0.6
	decal.upper_fade = 0.1
	decal.lower_fade = 0.1
	decal.albedo_mix = 1.0
	decal.cull_mask = 0xFFFFF & ~(1 << (Unit.RENDER_LAYER - 1))
	# Over the unit rings and ground surfaces, which sit at 1.0.
	decal.sorting_offset = 2.0
	var textures: Array = UnitSelection._ring_textures_for(MARKER_RING_WIDTH)
	decal.texture_albedo = textures[0]
	decal.texture_emission = textures[1]
	decal.modulate = color
	decal.emission_energy = color.a
	add_child(decal)
	decal.global_position = point

	# Bound to the decal, so a world freed mid-fade takes the tween with it.
	var end_size := Vector3(MARKER_SIZE * MARKER_END_SCALE, MARKER_HEIGHT, MARKER_SIZE * MARKER_END_SCALE)
	var faded := Color(color, 0.0)
	var tween: Tween = decal.create_tween().set_parallel(true)
	tween.tween_property(decal, "size", end_size, MARKER_SECONDS).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tween.tween_property(decal, "modulate", faded, MARKER_SECONDS).set_ease(Tween.EASE_IN)
	tween.tween_property(decal, "emission_energy", 0.0, MARKER_SECONDS)
	tween.chain().tween_callback(decal.queue_free)


## Styled like the movement preview's cost readout: billboarded, screen-
## constant, no depth test - so a wall in front of the spot cannot hide
## why the click there was refused.
func _show_reason(point: Vector3, reason: String) -> void:
	if is_instance_valid(_reason_label):
		_reason_label.queue_free()
	var label := Label3D.new()
	label.top_level = true
	label.text = reason
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.fixed_size = true
	label.pixel_size = 0.0012
	label.font_size = 26
	label.outline_size = 8
	label.outline_modulate = IndicatorPalette.EDGE
	label.modulate = IndicatorPalette.BLOCKED
	label.no_depth_test = true
	# On the units' layer, so no ground decal (these rings included)
	# paints over the text.
	label.layers = 1 << (Unit.RENDER_LAYER - 1)
	add_child(label)
	var start: Vector3 = point + Vector3(0.0, REASON_HEIGHT, 0.0)
	label.global_position = start
	_reason_label = label

	var tween: Tween = label.create_tween().set_parallel(true)
	tween.tween_property(label, "global_position", start + Vector3(0.0, REASON_RISE, 0.0), REASON_SECONDS).set_ease(Tween.EASE_OUT)
	tween.tween_property(label, "modulate:a", 0.0, REASON_SECONDS * 0.5).set_delay(REASON_SECONDS * 0.5)
	tween.tween_property(label, "outline_modulate:a", 0.0, REASON_SECONDS * 0.5).set_delay(REASON_SECONDS * 0.5)
	tween.chain().tween_callback(label.queue_free)


func _make_player(stream: AudioStream, volume_db: float) -> AudioStreamPlayer:
	var player := AudioStreamPlayer.new()
	player.stream = stream
	player.bus = sound_bus
	player.volume_db = volume_db
	add_child(player)
	return player


## A short decaying sine sweep, as 16-bit mono PCM - the default UI tick,
## so the feedback works without shipping an asset. The sub-millisecond
## attack keeps the first sample from popping; the decay is steep enough
## that the last sample is near silence, so the end does not pop either.
static func _tick(freq_from: float, freq_to: float, seconds: float, amplitude: float, decay: float) -> AudioStreamWAV:
	var rate: int = 22050
	var count: int = int(rate * seconds)
	var data := PackedByteArray()
	data.resize(count * 2)
	var phase: float = 0.0
	for i in count:
		var t: float = float(i) / rate
		phase += TAU * lerpf(freq_from, freq_to, t / seconds) / rate
		var envelope: float = exp(-t * decay) * minf(1.0, t * 2000.0)
		data.encode_s16(i * 2, int(sin(phase) * envelope * amplitude * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = rate
	wav.stereo = false
	wav.data = data
	return wav
