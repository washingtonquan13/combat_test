extends "res://tools/dragon_sizes_demo.gd"
## Recorded showcase of the SM 6 dragon's own clips - NOT a test: Bite and
## Claw through its MotionSet, Fire Breath, a hit, Downed and back up, death.


func _run() -> void:
	SIZES = [6]
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	for member: Unit in PartyManager.members:
		if member != _hero:
			member.visible = false
	var camera: CRPGCamera = _camera()
	camera.min_distance = 3.0
	camera.max_distance = 80.0
	camera.min_pitch = 6.0
	camera.max_pitch = 12.0
	_length = _row_length()
	if not _find_row():
		print("DEMO RESULT: no clear ground for a %.0f m row" % _length)
		get_tree().quit()
		return
	# The hero well out of the way: the dummy stands at the dragon's nose.
	_hero.global_position = _origin - _across() * 14.0
	_spawn_row()
	_dragon = _dragons[0]
	SelectionManager.select(_dragon)
	await _wait(0.5)
	_frame(_dragon.global_position + Vector3(0, 4.0, 0), 34.0)
	_look_side()
	await _wait(1.5)
	_say("Dragon, SM 6, on its own body: its own Idle")
	_check("plays Idle", _clip() == &"Idle")
	await _wait(2.5)
	await _attacks()

	var total := _passed + _failed.size()
	_say("Done: %d/%d checks passed" % [_passed, total])
	print("DEMO RESULT: %d/%d passed" % [_passed, total])
	for f in _failed:
		print("  FAILED: ", f)
	await _wait(2.5)
	get_tree().quit()
