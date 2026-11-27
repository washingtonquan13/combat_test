class_name TerminalExamQuestion
extends Resource
## One multiple-choice question of a TerminalExam.

## The part heading shown above the question, e.g. "PART 1: COMBAT".
@export var part: String = ""
@export var points: int = 20
## The question, in BBCode.
@export_multiline var prompt: String = ""
## The answers, shown as A, B, C... in this order.
@export var options: PackedStringArray = PackedStringArray()
## Index into options of the right answer.
@export var correct: int = 0
