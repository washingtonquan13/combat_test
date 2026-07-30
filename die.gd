class_name Die
extends Node

@export var count: int = 3
@export var sides: int = 6
@export var bonus: int = 0

func roll() -> int:
	assert(count > 0, "Die.count must be > 0")
	assert(sides > 0, "Die.sides must be > 0")

	var total := 0
	for i in count:
		total += randi_range(1, sides)

	return total + bonus
