class_name TerminalExam
extends Resource
## A multiple-choice exam a Terminal runs instead of showing a page of
## text (Terminal.exam). The questions are data; TerminalExamRun is one
## sitting of it.
##
## The result is story state: finishing it sets the flags "<flag>/score"
## (points) and "<flag>/passed" (bool) through FlagManager, so dialogue and
## quests read it like any other flag. It is taken once: a terminal whose
## exam already has a score shows that score instead of the questions.
## With no flag, nothing is recorded and it can be taken again (practice).

@export var title: String = "EXAMINATION"
## The first page, in BBCode: what the exam is and how to answer.
@export_multiline var intro: String = ""
@export var flag: String = ""
## Points needed to pass, out of total_points().
@export var pass_mark: int = 60
@export var questions: Array[TerminalExamQuestion] = []


func total_points() -> int:
	var total := 0
	for question in questions:
		total += question.points
	return total


func score_flag() -> String:
	return flag + "/score"


func passed_flag() -> String:
	return flag + "/passed"


func has_result() -> bool:
	return not flag.is_empty() and FlagManager.has_flag(score_flag())


func recorded_score() -> int:
	return int(FlagManager.get_flag(score_flag(), 0))


## Whether the score on file passed, as recorded: a later change to
## pass_mark doesn't rewrite an old result.
func recorded_pass() -> bool:
	return bool(FlagManager.get_flag(passed_flag(), false))


func passes(score: int) -> bool:
	return score >= pass_mark


func record(score: int) -> void:
	if flag.is_empty():
		return
	FlagManager.set_flag(score_flag(), score)
	FlagManager.set_flag(passed_flag(), passes(score))
