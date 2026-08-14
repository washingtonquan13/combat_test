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
## Set the instant phase_changed fires, cleared on stop/finish — the only
## thing _process() needs to decide whether (and what) to draw into
## _progress_label. Existing purely so the live [elapsed/total] readout
## below has something to poll every frame; _on_phase_changed itself no
## longer writes the label directly, _process() is now the one place that
## does (see that function for why the split matters).
var _current_phase: AnimationPhase = null
var _current_phase_index: int = -1


func _ready() -> void:
	var model: Node = RigUtils.instantiate_rig()
	_model_root.add_child(model)
	_phase_player.animation_player = model.get_node("AnimationPlayer")

	_play_button.pressed.connect(_on_play_pressed)
	_advance_button.pressed.connect(func(): _phase_player.advance_external())
	_phase_player.phase_changed.connect(_on_phase_changed)
	_phase_player.sequence_finished.connect(_on_sequence_finished)

	show_sequence(null)


## Live per-frame readout for whichever phase is currently active — added
## specifically so an ON_FINISH phase's wait (e.g. Jump_Start, which has
## to fully finish before Loop/Advance is even reachable — that's an
## intentional gate, not a bug) is VISIBLE instead of just a disabled
## Advance button with no indication of how long or why. Also the
## easiest way to actually find out a clip's real authored length: this
## reads it straight off the same AnimationPlayer/clips real gameplay
## uses, no separate lookup needed.
func _process(_delta: float) -> void:
	if not _current_phase:
		return
	var anim_player: AnimationPlayer = _phase_player.animation_player
	var text: String = "Phase %d/%d: %s" % [_current_phase_index + 1, _current_sequence.phases.size(), _current_phase.describe()]

	match _current_phase.advance_trigger:
		AnimationPhase.AdvanceTrigger.ON_FINISH:
			if anim_player and anim_player.current_animation == _current_phase.animation_name:
				text += "  [%.2fs / %.2fs]" % [anim_player.current_animation_position, anim_player.current_animation_length]
		AnimationPhase.AdvanceTrigger.EXTERNAL:
			text += "  [waiting on an external event — click Advance]"

	_progress_label.text = text


## Called by plugin.gd's _edit() whenever an AnimationSequence becomes
## (or stops being) the Inspector's edited object. sequence may be null
## on deselect.
func show_sequence(sequence: AnimationSequence) -> void:
	_current_sequence = sequence
	_current_phase = null
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
		_current_phase = null
		_phase_player.stop()
		_advance_button.disabled = true
		_play_button.disabled = (_current_sequence == null)


func _on_play_pressed() -> void:
	if _current_sequence:
		_play_button.disabled = true
		_phase_player.play(_current_sequence)


func _on_phase_changed(index: int, phase: AnimationPhase) -> void:
	_current_phase = phase
	_current_phase_index = index
	_advance_button.disabled = phase.advance_trigger != AnimationPhase.AdvanceTrigger.EXTERNAL


func _on_sequence_finished() -> void:
	_current_phase = null
	_progress_label.text = "Finished"
	_advance_button.disabled = true
	_play_button.disabled = false
