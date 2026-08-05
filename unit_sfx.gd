extends Node
## Reactive SFX trigger, synced to the SAME anchors driving animation and
## VFX — but owning ONLY the two moments nothing else already covers:
## entering an armed stance, and holding it. Mirrors unit_animator.gd/
## unit_vfx.gd's exact wiring pattern: zero combat logic of its own,
## purely reactive to signals that already exist (or, for arming
## specifically, to AbilityManager's existing signal, filtered to
## whether THIS unit is the one doing the arming — AbilityManager itself
## is global/unit-agnostic, on purpose, same as everywhere else it's
## used in this project).
##
## Deliberately NON-BLOCKING throughout — nothing here ever awaits
## anything, every sound is fire-and-forget, matching how BG3/DOS2/WotR/
## PoE2 actually handle this: combat never waits on audio length. What
## makes it feel synced is that each sound STARTS at the exact right
## moment, not that anything is gated on it finishing.
##
## Launch and impact SFX are explicitly NOT handled here — see
## Ability.impact_vfx's doc comment. They belong as PlaySoundStep
## entries inside the ability's own VfxEffect sequence, already
## correctly synced by being awaited in order alongside everything else
## in that sequence. Duplicating those two moments here would create a
## second, competing source of truth for timing that's already solved.

@export var unit: Unit
@export var default_armed_enter_sfx: AudioStream
@export var default_armed_hold_sfx: AudioStream

## The looping "holding a stance" player, parented directly under `unit`
## (not the scene root, unlike VfxEffect's one-shot sequences) —
## deliberately: this loop represents THIS unit's own "armed, waiting to
## act" state, which should end the instant they die, same as any other
## per-unit state. VFX sequences use the scene root instead specifically
## so an in-flight fireball can finish even if its caster died right
## after casting — that reasoning doesn't apply here; there's nothing
## left to finish once the unit holding the stance is gone.
var _hold_player: AudioStreamPlayer3D


func _ready() -> void:
	if not unit:
		push_warning("unit_sfx.gd needs `unit` assigned in the Inspector.")
		return

	AbilityManager.ability_armed.connect(_on_ability_armed)
	unit.ability_use_started.connect(_on_ability_use_started)


func _on_ability_armed(ability: Ability) -> void:
	if CombatManager.current_unit != unit:
		return

	_stop_hold_loop()

	if not ability:
		return  # disarmed — nothing more to play

	var enter_sfx: AudioStream = ability.armed_enter_sfx if ability.armed_enter_sfx else default_armed_enter_sfx
	_play_one_shot(enter_sfx)

	var hold_sfx: AudioStream = ability.armed_hold_sfx if ability.armed_hold_sfx else default_armed_hold_sfx
	_start_hold_loop(hold_sfx)


## Launching ANY ability ends the "holding a stance" state, regardless
## of whether it was specifically the armed one that fired (e.g.
## clicking an enemy with nothing explicitly armed, falling back to
## default_ability() — see AbilityManager) — either way, the unit isn't
## standing in an armed stance anymore the instant something launches.
func _on_ability_use_started(_attacker: Unit, _target, _ability: Ability) -> void:
	_stop_hold_loop()


func _play_one_shot(stream: AudioStream) -> void:
	if not stream:
		return
	var player := AudioStreamPlayer3D.new()
	get_tree().current_scene.add_child(player)
	player.stream = stream
	player.global_position = unit.global_position
	player.play()
	player.finished.connect(player.queue_free)


func _start_hold_loop(stream: AudioStream) -> void:
	if not stream:
		return
	_hold_player = AudioStreamPlayer3D.new()
	unit.add_child(_hold_player)
	_hold_player.stream = stream
	_hold_player.play()


func _stop_hold_loop() -> void:
	if _hold_player and is_instance_valid(_hold_player):
		_hold_player.queue_free()
	_hold_player = null
