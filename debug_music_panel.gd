class_name DebugMusicPanel
extends Control
## The Music tab's content — debug-only "listen to a MusicTrack and
## watch its phase/position live" tool, for manually confirming the
## intro->loop->outro handoff sounds right (see music_manager.gd's own
## header for the bugs that transition has had). Root-level like
## DemonCompendiumPanel/DebugSpawnPanel, referenced via @onready from
## party_overview.gd the same way.
##
## The whole tab is debug-only: party_overview.gd hides %TabMusic
## itself, and this script's own _ready()/_process() additionally no-op
## outside a debug build as defense in depth — same belt-and-suspenders
## reasoning DebugSpawnPanel already uses.
##
## Shows time-to-loop-boundary specifically so you can deliberately
## time a Stop press to exercise EITHER of stop()'s two branches (quick
## fade vs. wait-for-boundary-then-outro), rather than only ever hitting
## whichever one luck lands on.

@onready var _track_list: ItemList = %MusicTrackList
@onready var _play_button: Button = %PlayTrackButton
@onready var _stop_button: Button = %StopTrackButton
@onready var _status_label: Label = %MusicStatusLabel

var _tracks: Array[MusicTrack] = []


func _ready() -> void:
	if not OS.is_debug_build():
		return
	_play_button.pressed.connect(_on_play_pressed)
	_stop_button.pressed.connect(MusicManager.stop)
	_populate_list()
	_update_status()


func _process(_delta: float) -> void:
	if not OS.is_debug_build() or not is_visible_in_tree():
		return
	_update_status()


func refresh() -> void:
	if not OS.is_debug_build():
		return
	_populate_list()
	_update_status()


func _populate_list() -> void:
	_tracks = MusicTrackDatabase.get_all()
	_track_list.clear()
	for track in _tracks:
		_track_list.add_item(track.id)


func _on_play_pressed() -> void:
	var selected: PackedInt32Array = _track_list.get_selected_items()
	if selected.is_empty():
		return
	MusicManager.play_track(_tracks[selected[0]])


func _update_status() -> void:
	var phase: int = MusicManager.get_phase()
	var track: MusicTrack = MusicManager.get_current_track()

	if phase == MusicManager.Phase.STOPPED or not track:
		_status_label.text = "Stopped."
		return

	var position: float = MusicManager.get_position()
	var length: float = MusicManager.get_length()
	var text: String = "%s — %s — %.1fs / %.1fs" % [track.id, _phase_label(phase), position, length]

	if phase == MusicManager.Phase.LOOP:
		text += "  (%.1fs to boundary)" % (length - position)

	_status_label.text = text


func _phase_label(phase: int) -> String:
	match phase:
		MusicManager.Phase.INTRO:
			return "Intro"
		MusicManager.Phase.LOOP:
			return "Loop"
		MusicManager.Phase.OUTRO:
			return "Outro"
		_:
			return "Stopped"
