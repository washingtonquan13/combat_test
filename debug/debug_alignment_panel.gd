class_name DebugAlignmentPanel
extends Control
## The Alignment tab's content — debug-only "set the party leader's raw
## alignment and watch the overworld spin react" tool. Root-level like
## DebugMusicPanel/DebugSpawnPanel, referenced via @onready from
## party_overview.gd the same way, and the whole tab is debug-only
## (party_overview.gd hides %TabAlignment itself; this script's own
## _ready()/_process() additionally no-op outside a debug build, same
## belt-and-suspenders convention as the other debug tabs).
##
## Reads/writes through PartyManager.leader_alignment()/
## set_leader_alignment() — the same dual live-Unit-or-roster-record path
## OverworldAvatar's own spin uses — so this works identically whether
## you're standing in a level or the overworld when you open it. That's
## also why this panel exists at all: the alignment grid on the Character
## tab only shows the currently-open unit, which is frequently not the
## leader, and shows nothing at all when there's no live Unit (the
## overworld) to open on.
##
## The live readout (category / extremity / motion) exists so the spin
## mapping can be confirmed from the numbers, not just inferred by eye —
## see overworld_avatar.gd's own _apply_alignment_spin for the mapping
## this mirrors.

@onready var _slider: HSlider = %AlignmentSlider
@onready var _value_label: Label = %AlignmentValueLabel
@onready var _readout_label: Label = %AlignmentReadoutLabel

const _PRESETS: Dictionary = {
	"ChaosExtremeButton": -100,
	"ChaosMildButton": -40,
	"NeutralMildButton": 5,
	"NeutralExtremeButton": 24,
	"LawMildButton": 40,
	"LawExtremeButton": 100,
}


func _ready() -> void:
	if not OS.is_debug_build():
		return
	_slider.min_value = -100
	_slider.max_value = 100
	_slider.step = 1
	_slider.value_changed.connect(_on_slider_changed)
	for button_name in _PRESETS:
		var button: Button = get_node("%" + button_name)
		button.pressed.connect(_apply_value.bind(_PRESETS[button_name]))
	refresh()


func _process(_delta: float) -> void:
	if not OS.is_debug_build() or not is_visible_in_tree():
		return
	# Live, not just on refresh() — the wobble/spin extremity is worth
	# watching update in real time as the slider is dragged, not only
	# when the tab is reopened.
	_update_readout()


func refresh() -> void:
	if not OS.is_debug_build():
		return
	_slider.set_value_no_signal(PartyManager.leader_alignment())
	_update_readout()


func _apply_value(value: int) -> void:
	_slider.value = value


func _on_slider_changed(value: float) -> void:
	PartyManager.set_leader_alignment(int(value))
	_update_readout()


func _update_readout() -> void:
	var alignment: int = PartyManager.leader_alignment()
	_value_label.text = str(alignment)

	var category: int = UnitAlignment.category_for(alignment)
	var category_name: String = ["Chaos", "Neutral", "Law"][category + 1]

	var threshold: float = float(UnitAlignment.ALIGNMENT_NEUTRAL_THRESHOLD)
	var motion: String
	var extremity: float
	if category == 0:
		extremity = clampf(absf(alignment) / threshold, 0.0, 1.0)
		motion = "wobbling"
	else:
		var full_scale: float = AlignmentGrid.DISPLAY_RANGE
		extremity = clampf((absf(alignment) - threshold) / (full_scale - threshold), 0.0, 1.0)
		motion = "spinning clockwise" if category > 0 else "spinning counter-clockwise"

	_readout_label.text = "%s · extremity %.2f · %s" % [category_name, extremity, motion]
