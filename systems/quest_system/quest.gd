class_name Quest
extends Resource
## One quest's full definition — id, display title, and its stages in
## order. Deliberately NOT a state machine and NOT persisted anywhere of
## its own: "where is this quest right now" is derived at read time from
## FlagManager, the same world-state store dialogue already writes to
## via DialogueChoice.sets_flag/DialogueEffect. This Resource only
## exists to give that already-real progress a name and journal text —
## current_stage() below is the one method that actually does anything.
##
## No separate write-side ("QuestEffect", a manager that advances a
## quest) — a quest's progress already advances the instant something
## sets the right flag, exactly as it does today for the Scared
## Townsperson raid quest (see
## data/quests/scared_townsperson_raids.tres), with zero changes to how
## dialogue authors that. A parallel way to write quest state would just
## be a second, competing mechanism for a fact FlagManager already owns.

@export var id: String = ""
@export var title: String = ""
## Authored in progression order — current_stage() depends on that
## ordering, not on anything else marking which stage is "later."
@export var stages: Array[QuestStage] = []


## The LAST stage in order whose flag is set, or null if none are (the
## quest hasn't been picked up yet). Last-in-order rather than
## first-unset because FlagManager flags are never cleared once true —
## a quest three stages in still has stage one's flag sitting there
## true too; this wants the FURTHEST one reached, not the first one
## found.
func current_stage() -> QuestStage:
	var reached: QuestStage = null
	for stage in stages:
		if FlagManager.has_flag(stage.flag_name):
			reached = stage
	return reached


func is_started() -> bool:
	return current_stage() != null


## True once the player has reached the LAST authored stage —
## positional, not a stored flag of its own (see QuestStage's header
## for why).
func is_complete() -> bool:
	return not stages.is_empty() and current_stage() == stages[-1]
