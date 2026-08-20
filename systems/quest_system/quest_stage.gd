class_name QuestStage
extends Resource
## One milestone in a Quest's progression — pairs the FlagManager flag
## that marks this milestone reached with the journal text to show while
## it's the CURRENT one. Deliberately dumb data, no logic of its own
## (unlike PrerequisiteRule/DialogueEffect's subclasses) — there's only
## ever one way to check "has this stage been reached"
## (FlagManager.has_flag), so there's nothing here for a subclass to
## vary. See Quest.current_stage() for how a stage list resolves to
## "where is the player right now."
##
## No is_completed/is_final field — completion is positional (this is
## the LAST entry in Quest.stages) and derived at read time by
## Quest.is_complete(), not stored here, so a stage can never disagree
## with its own position in the array.

@export var flag_name: String = ""
@export_multiline var journal_text: String = ""
