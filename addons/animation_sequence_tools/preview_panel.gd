@tool
extends Control
## Bottom-panel dock: renders the shared rig in an isolated SubViewport
## and plays through whatever AnimationSequence plugin.gd's _edit() last
## handed it (see show_sequence()). Owns no sequence-selection logic of
## its own — that's plugin.gd's job via _handles/_edit/_make_visible.

const RigUtils := preload("res://addons/animation_sequence_tools/rig_utils.gd")

@onready var _header_label: Label = %HeaderLabel
@onready var _progress_label: Label = %ProgressLabel
@onready var _play_button: Button = %PlayButton
@onready var _advance_button: Button = %AdvanceButton
@onready var _model_root: Node3D = %ModelRoot
@onready var _phase_player: Node = %PhasePlayer  # preview_phase_player.gd

var _current_sequence: AnimationSequence = null


func _ready() -> void:
	var model: Node = RigUtils.instantiate_rig()
	_model_root.add_child(model)
	_phase_player.animation_player = model.get_node("AnimationPlayer")

	_play_button.pressed.connect(_on_play_pressed)
	_advance_button.pressed.connect(func(): _phase_player.advance_external())
	_phase_player.phase_changed.connect(_on_phase_changed)
	_phase_player.sequence_finished.connect(_on_sequence_finished)

	show_sequence(null)


## Called by plugin.gd's _edit() whenever an AnimationSequence becomes
## (or stops being) the Inspector's edited object. sequence may be null
## on deselect.
func show_sequence(sequence: AnimationSequence) -> void:
	_current_sequence = sequence
	_phase_player.stop()
	_advance_button.disabled = true
	_play_button.disabled = (sequence == null)
	if sequence:
		_header_label.text = sequence.resource_path.get_file() if sequence.resource_path != "" else "(unsaved sequence)"
		_progress_label.text = sequence.describe()
	else:
		_header_label.text = "(no sequence selected)"
		_progress_label.text = ""


## Called by plugin.gd's _make_visible() — stop playback when the panel
## isn't the visible bottom-panel tab rather than leaving it running
## unseen.
func set_active(active: bool) -> void:
	if not active:
		_phase_player.stop()
		_advance_button.disabled = true
		_play_button.disabled = (_current_sequence == null)


func _on_play_pressed() -> void:
	if _current_sequence:
		_play_button.disabled = true
		_phase_player.play(_current_sequence)


func _on_phase_changed(index: int, phase: AnimationPhase) -> void:
	_progress_label.text = "Phase %d/%d: %s" % [index + 1, _current_sequence.phases.size(), phase.describe()]
	_advance_button.disabled = phase.advance_trigger != AnimationPhase.AdvanceTrigger.EXTERNAL


func _on_sequence_finished() -> void:
	_progress_label.text = "Finished"
	_advance_button.disabled = true
	_play_button.disabled = false
