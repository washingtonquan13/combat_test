class_name TalkInteraction
extends InteractionOption
## Right-click "Talk" — available on any non-hostile unit (mirrors
## AttackInteraction's own hostile-only gate, just the opposite side of
## it). Starts a real conversation (see start() below) when the target
## has a dialogue_options entry that currently resolves (see
## Unit.resolve_dialogue_root); falls back to a placeholder
## SystemLog line otherwise, same honest-stub treatment ExamineInteraction
## already got, for any unit nobody's written dialogue for yet.

## Starts an ordinary dialogue: the one place that decides what a talk is
## allowed to be, so the conversation engine does not have to. Returns the
## live conversation, or null when it was refused.
##
## Refused when any participant is fighting — THE SPEAKER, not the world.
## Asked as a global "is combat running," a battle anywhere silenced
## everyone everywhere, so a group standing in a quiet area could not talk
## to anybody while another group was fighting two areas away. The reason
## to refuse is that a full-screen conversation has no defined interaction
## with a turn/initiative state machine, and that reason is about the
## people in the conversation. Everything else that could stop it (another
## conversation, an open stash) is Conversations.begin's one question to
## GameMode.
static func start(root: DialogueNode, participants: Dictionary) -> Conversation:
	for participant in participants.values():
		if participant is Unit and (participant as Unit).in_combat():
			return null
	var c := Conversation.new(root, participants)
	return c if Conversations.begin(c) else null


func is_available(actor: Unit, target) -> bool:
	if not target is Unit:
		return false
	var unit_target: Unit = target
	return not actor.is_hostile_to(unit_target)


func execute(actor: Unit, target) -> void:
	var unit_target: Unit = target
	# The root is chosen against the cast the conversation will actually
	# have, so a root gated on who is present sees the same party that
	# will be standing there once it begins.
	var participants: Dictionary = _build_participants(actor, unit_target)
	var root: DialogueNode = unit_target.resolve_dialogue_root(Conversation.new(null, participants))
	if root:
		start(root, participants)
	else:
		SystemLog.print("%s has nothing to say yet." % unit_target.name)


## "player"/"npc" stay reserved exactly as before — every existing
## dialogue tree already keys on those two tokens, and actor is always
## the one initiating, unit_target always who they clicked. Beyond that,
## every OTHER present party member gets added under their own unit
## name (party_panel.gd's own is_player_controlled()+summoned_by==null
## filter for "core roster", so a summoned creature never gets treated
## as a conversation participant) — this is the entire fix for the
## two-token-only gap named in dialogue_system_bg3_gap_analysis.md.
## Conversation.cast is just a generic String->Unit dict; nothing about
## it enforces exactly two entries. So a dialogue author can write
## DialogueNode.speaker (or a future companion-reaction choice) as an
## exact unit name, e.g. "ElfRanger", and DialogueStaging/
## dialogue_overlay.gd resolve it for free — both look tokens up via
## cast.get(token) generically, keyed
## by actual node name rather than a synthetic index so it stays legible
## to whoever's authoring the .tres and stable across roster changes.
func _build_participants(actor: Unit, unit_target: Unit) -> Dictionary:
	var participants: Dictionary = {"player": actor, "npc": unit_target}
	if PartyManager.leader:
		participants["leader"] = PartyManager.leader
	for unit in UnitQuery.core_party_units(actor.get_tree()):
		if unit != actor:
			participants[unit.name] = unit
	return participants
