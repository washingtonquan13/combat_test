class_name TerminalExamRun
extends RefCounted
## One sitting of a TerminalExam: which page is up, the answers so far, and
## the result. Terminal makes one when the player sits down at an exam
## terminal and drops it when they step away, so leaving before the last
## answer voids the attempt: nothing is recorded until the end.
##
## Pages are BBCode for TerminalScreen, with the things the player can pick
## (choices()) listed under them as menu lines; this knows nothing about
## the 3D prop or input. Terminal maps Enter, clicks and letter keys onto
## choose() and answer().

enum Stage { INTRO, QUESTION, RESULT }

const LETTERS := "ABCDEFGHI"
## TerminalScreen.DIM as BBCode.
const DIM := "#339e4d"

var exam: TerminalExam
var stage := Stage.INTRO
var answers: Array[int] = []
## True when the result page shows a score taken earlier, not this sitting.
var on_file := false


func _init(for_exam: TerminalExam) -> void:
	exam = for_exam
	if exam.has_result():
		stage = Stage.RESULT
		on_file = true


func question() -> TerminalExamQuestion:
	return exam.questions[answers.size()] if stage == Stage.QUESTION else null


## From the intro to the first question. False if not on the intro.
func begin() -> bool:
	if stage != Stage.INTRO:
		return false
	# An exam with no questions is unfinished data, not a sitting: show
	# the empty result but record nothing, or the save would hold a fail.
	stage = Stage.RESULT if exam.questions.is_empty() else Stage.QUESTION
	return true


## Picks answer choice (0 is A) to the current question and moves on. False
## if there is no question up or no such answer.
func answer(choice: int) -> bool:
	var current := question()
	if current == null or choice < 0 or choice >= _option_count(current):
		return false
	answers.append(choice)
	if answers.size() == exam.questions.size():
		stage = Stage.RESULT
		exam.record(score())
	return true


## The lines the player can pick on this page: Begin on the intro, the
## answers on a question, none on the result.
func choices() -> PackedStringArray:
	match stage:
		Stage.INTRO:
			return PackedStringArray(["BEGIN EXAMINATION"])
		Stage.QUESTION:
			var q := question()
			var lines := PackedStringArray()
			for i in _option_count(q):
				lines.append("%s. %s" % [LETTERS[i], q.options[i]])
			return lines
	return PackedStringArray()


## Picks choices()[index]. False if there is no such choice.
func choose(index: int) -> bool:
	return begin() if stage == Stage.INTRO and index == 0 else answer(index)


func score() -> int:
	if on_file:
		return exam.recorded_score()
	var total := 0
	for i in answers.size():
		var q := exam.questions[i]
		if answers[i] == q.correct:
			total += q.points
	return total


func page_text() -> String:
	match stage:
		Stage.INTRO:
			return exam.intro
		Stage.QUESTION:
			return _question_text()
	return _result_text()


func footer() -> String:
	match stage:
		Stage.INTRO:
			return "[ENTER] BEGIN    [TAB] BACK    [ESC] LOG OFF"
		Stage.QUESTION:
			return "[UP/DOWN] SELECT  [ENTER / %s] ANSWER    [ESC] LOG OFF" % _letter_range(_option_count(question()))
	return "[ENTER / TAB] BACK    [ESC] LOG OFF"


func _question_text() -> String:
	var q := question()
	var n := answers.size()
	var lines: Array[String] = []
	if n == 0 or exam.questions[n - 1].part != q.part:
		lines.append("[color=%s]%s[/color]" % [DIM, q.part])
	lines.append("[b]QUESTION %d OF %d[/b]  [color=%s](%d POINTS)[/color]" % [n + 1, exam.questions.size(), DIM, q.points])
	lines.append("")
	lines.append(q.prompt)
	return "\n".join(lines)


func _result_text() -> String:
	var got := score()
	var total := exam.total_points()
	var lines: Array[String] = []
	if on_file:
		lines.append("[color=%s]RESULT ON FILE. THE EXAMINATION IS TAKEN ONCE.[/color]" % DIM)
		lines.append("")
	else:
		# Giten-style marks: ○ right, × wrong. A table, so the columns line
		# up: the face is proportional and ○ is wider than ×.
		var table := "[table=3]"
		for i in answers.size():
			var q := exam.questions[i]
			var right := answers[i] == q.correct
			table += "[cell]Q%d   [/cell][cell]%s   [/cell][cell]%d / %d[/cell]" % [
					i + 1, "○" if right else "×", q.points if right else 0, q.points]
		lines.append(table + "[/table]")
		lines.append("")
	lines.append("[b]SCORE  %d / %d[/b]" % [got, total])
	lines.append("")
	if exam.recorded_pass() if on_file else exam.passes(got):
		lines.append("[b]PASSED[/b]")
	else:
		lines.append("[b]FAILED[/b]")
	return "\n".join(lines)


## The options a key can pick: A-I / 1-9, so nine at most. Extra ones are
## an authoring error and are left off the page.
func _option_count(q: TerminalExamQuestion) -> int:
	if q.options.size() > LETTERS.length():
		push_error("TerminalExamQuestion has %d options; only %d can be answered" % [q.options.size(), LETTERS.length()])
	return mini(q.options.size(), LETTERS.length())


func _letter_range(count: int) -> String:
	return "A" if count <= 1 else "A-%s" % LETTERS[count - 1]
