@tool
extends Node
## Preview-only AnimationSequence phase player. Same three AdvanceTrigger
## semantics as unit_animator.gd's real player (ON_FINISH/ON_TIMER/
## EXTERNAL), deliberately stripped of everything that exists there only
## to survive interruption or juggle a live Unit: no _sequence_token
## (nothing else ever calls .play() on this AnimationPlayer, so a stale
## timer from an abandoned play-through can't fire — stop() halts the
## Timer outright before a new play() ever starts one), no pose/hit-
## reaction rest-state (nothing else ever plays a clip on this
## AnimationPlayer to return from), and no interruption handling (the
## only thing that ever drives this player is the preview panel's own
## Play/Advance buttons).

signal phase_changed(index: int, phase: AnimationPhase)
signal sequence_finished()

var animation_player: AnimationPlayer = null

var _sequence: AnimationSequence = null
var _phase_index: int = -1
var _playing: bool = false
var _timer: Timer = Timer.new()


func _ready() -> void:
	_timer.one_shot = true
	add_child(_timer)
	_timer.timeout.connect(_on_timer_timeout)


func play(sequence: AnimationSequence) -> void:
	stop()
	_sequence = sequence
	_phase_index = -1
	_playing = true
	if animation_player and not animation_player.animation_finished.is_connected(_on_animation_finished):
		animation_player.animation_finished.connect(_on_animation_finished)
	_advance()


func stop() -> void:
	_playing = false
	_timer.stop()
	_sequence = null
	_phase_index = -1


func advance_external() -> void:
	var phase: AnimationPhase = _current_phase()
	if _playing and phase and phase.advance_trigger == AnimationPhase.AdvanceTrigger.EXTERNAL:
		_advance()


func _current_phase() -> AnimationPhase:
	if not _sequence or _phase_index < 0 or _phase_index >= _sequence.phases.size():
		return null
	return _sequence.phases[_phase_index]


func _advance() -> void:
	_timer.stop()
	_phase_index += 1
	var phase: AnimationPhase = _current_phase()
	if not phase:
		_playing = false
		sequence_finished.emit()
		return

	if animation_player and animation_player.has_animation(phase.animation_name):
		animation_player.play(phase.animation_name)
	else:
		push_warning("Preview: phase %d references unknown clip \"%s\"." % [_phase_index, phase.animation_name])

	phase_changed.emit(_phase_index, phase)

	if phase.advance_trigger == AnimationPhase.AdvanceTrigger.ON_TIMER:
		_timer.start(phase.duration)


func _on_animation_finished(anim_name: StringName) -> void:
	if not _playing:
		return
	var phase: AnimationPhase = _current_phase()
	if phase and phase.advance_trigger == AnimationPhase.AdvanceTrigger.ON_FINISH and anim_name == phase.animation_name:
		_advance()


func _on_timer_timeout() -> void:
	if _playing:
		_advance()
