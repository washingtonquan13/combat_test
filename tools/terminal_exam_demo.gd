extends "res://tools/terminal_demo.gd"
## Recorded walkthrough of the exam terminal — NOT a test. Sets the
## shelter exam terminal down in test_arena, sits at it, and takes the exam
## with real key presses: one wrong answer (Q4, 30 points), so 70 / 100,
## a pass. Then steps away and back to see the result on file. Also checks
## that stepping away mid-exam records nothing.
##
## Set TERMINAL_SNAPS=<dir> to also save stills of each page there.

const ExamTerminalScene: PackedScene = preload("res://systems/terminal_system/exam_terminal.tscn")
## Q1-Q5: C, B, C, then A (wrong) for Q4, B.
const KEYS: Array[Key] = [KEY_C, KEY_B, KEY_C, KEY_A, KEY_2]


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	var hero: Unit = PartyManager.leader
	SelectionManager.select(hero)
	var terminal: Terminal = ExamTerminalScene.instantiate()
	WorldManager.spawn_parent().add_child(terminal)
	terminal.global_position = hero.global_position + Vector3(-2.5, 0.0, 0.0)
	terminal.look_at(hero.global_position, Vector3.UP, true)
	var exam := terminal.exam
	FlagManager.clear_flag(exam.score_flag())
	FlagManager.clear_flag(exam.passed_flag())
	var page: TerminalScreen = terminal.get_node("ScreenViewport/TerminalScreen")
	await _wait(1.0)

	_say("Sit down: the intro")
	await _sit(terminal)
	_check("the intro is up", page.page_text().contains("PRESS [ENTER] TO BEGIN"))
	await _snap("exam_1_intro")

	_say("Enter begins; a key while the page types only finishes it")
	await _key(KEY_ENTER, 0.0)
	await _key(KEY_A)
	_check("Enter begins: question 1, still unanswered", page.page_text().contains("QUESTION 1 OF 5"))
	_check("question 1 shows its part heading", page.page_text().contains("PART 1: COMBAT"))
	await _snap("exam_2_q1")

	_say("Step away mid-exam")
	await _key(KEY_C)
	await _press_and_settle_escape()
	_check("a voided attempt records nothing", not FlagManager.has_flag(exam.score_flag()))

	_say("Back again: the exam starts over")
	await _sit(terminal)
	_check("the intro is up again", page.page_text().contains("PRESS [ENTER] TO BEGIN"))
	await _key(KEY_ENTER)
	for i in KEYS.size():
		_check("question %d is up" % (i + 1), page.page_text().contains("QUESTION %d OF 5" % (i + 1)))
		if i == 3:
			await _snap("exam_3_q4")
		await _key(KEYS[i])
	_check("the result page is up", page.page_text().contains("SCORE  70 / 100"))
	_check("one mark is wrong", page.page_text().count("×") == 1 and page.page_text().contains("0 / 30"))
	_check("70 passes", page.page_text().contains("PASSED"))
	_check("score flag is 70", FlagManager.get_flag(exam.score_flag()) == 70)
	_check("passed flag is set", FlagManager.get_flag(exam.passed_flag()) == true)
	await _snap("exam_4_result")

	_say("Back once more: result on file")
	await _press_and_settle_escape()
	await _sit(terminal)
	_check("the result is on file", page.page_text().contains("RESULT ON FILE"))
	_check("with the same score", page.page_text().contains("SCORE  70 / 100"))
	await _key(KEY_A)
	_check("letters do nothing on the result", FlagManager.get_flag(exam.score_flag()) == 70)
	await _snap("exam_5_on_file")
	await _press_and_settle_escape()
	_check("back from the terminal", Terminal.active == null)

	FlagManager.clear_flag(exam.score_flag())
	FlagManager.clear_flag(exam.passed_flag())
	print("DEMO RESULT: %d/%d passed" % [_passed, _passed + _failed.size()])
	for what in _failed:
		print("  failed: ", what)
	get_tree().quit()


func _sit(terminal: Terminal) -> void:
	terminal.use()
	await _wait(terminal.glide_time + 0.3)
	_check("at the terminal", Terminal.active == terminal)


func _press_and_settle_escape() -> void:
	_press_escape()
	await _wait(1.2)


## A real key press, through WorldView's SubViewport like a player's, then
## (by default) long enough for the next page to type out.
func _key(code: Key, settle := 0.8) -> void:
	for pressed in [true, false]:
		var key := InputEventKey.new()
		key.keycode = code
		key.physical_keycode = code
		key.pressed = pressed
		Input.parse_input_event(key)
	await get_tree().process_frame
	await _wait(settle)
