class_name ParticipantPresentPrerequisite
extends PrerequisiteRule
## Requires a specific participant to be present in the CURRENT
## conversation — see DialogueManager.participants, which
## talk_interaction.gd populates with every present party member keyed
## by their own unit name (see _build_participants). Gates a
## companion-specific line/reaction on "is so-and-so actually here to
## react to this," e.g. banter that only makes sense with a given party
## composition.
##
## Lives in dialogue_system rather than alongside its PrerequisiteRule
## siblings in skill_system (see flag_prerequisite.gd/
## alignment_prerequisite.gd) — unlike those two, this one is genuinely
## dialogue-specific: it names DialogueManager directly, not just
## generic Unit/global state. Still just another PrerequisiteRule leaf,
## composable with the others through the same CountPrerequisite
## AND/OR/N-of-M tree ("only if Wyll's here AND distrusts_player is
## set").
##
## Ignores the unit parameter, same as FlagPrerequisite — presence in
## THIS conversation is a property of the conversation itself, not of
## whichever unit happens to be asking.

@export var participant_token: String = ""


func is_satisfied(_unit: Unit) -> bool:
	return DialogueManager.participants.has(participant_token)
