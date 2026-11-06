class_name ParticipantPresentPrerequisite
extends PrerequisiteRule
## Requires a specific participant to be present in the CURRENT
## conversation — see Conversation.cast, which talk_interaction.gd
## populates with every present party member keyed by their own unit
## name (see _build_participants). Gates a
## companion-specific line/reaction on "is so-and-so actually here to
## react to this," e.g. banter that only makes sense with a given party
## composition.
##
## Lives in dialogue_system rather than alongside its PrerequisiteRule
## siblings in skill_system (see flag_prerequisite.gd/
## alignment_prerequisite.gd) — unlike those two, this one is genuinely
## dialogue-specific: it reads the conversation it is asked in, not
## generic Unit/global state. Still just another PrerequisiteRule leaf,
## composable with the others through the same CountPrerequisite
## AND/OR/N-of-M tree ("only if Wyll's here AND distrusts_player is
## set").
##
## Only meaningful inside a conversation, so is_satisfied_in carries the
## real answer; asked outside one (a skill's prerequisite tree, say) there
## is no cast to be present in, and the answer is no. Every conversation
## caller asks is_satisfied_in, including root selection (see
## Unit.resolve_dialogue_root). Any kind of conversation has a cast, so a
## negotiation's "npc" (the demon) and "player" are present in it too.

@export var participant_token: String = ""


func is_satisfied(_unit: Unit) -> bool:
	return false


func is_satisfied_in(c: Conversation) -> bool:
	return c.cast.has(participant_token)
