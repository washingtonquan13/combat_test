class_name TalkInteraction
extends InteractionOption
## Right-click "Talk" — available on any non-hostile unit (mirrors
## AttackInteraction's own hostile-only gate, just the opposite side of
## it). Starts a real conversation via DialogueManager when the target
## has a dialogue_options entry that currently resolves (see
## Unit.resolve_dialogue_root); falls back to a placeholder
## SystemLog line otherwise, same honest-stub treatment ExamineInteraction
## already got, for any unit nobody's written dialogue for yet.

func is_available(actor: Unit, target) -> bool:
	if not target is Unit:
		return false
	var unit_target: Unit = target
	return not actor.is_hostile_to(unit_target)


func execute(actor: Unit, target) -> void:
	var unit_target: Unit = target
	var root: DialogueNode = unit_target.resolve_dialogue_root(actor)
	if root:
		DialogueManager.start_dialogue(root, _build_participants(actor, unit_target))
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
## DialogueManager.participants was ALWAYS just a generic String->Unit
## dict; nothing about it enforced exactly two entries. Only this one
## caller ever populated it, so this is the whole change: a dialogue
## author can now write DialogueNode.speaker (or a future companion-
## reaction choice) as an exact unit name, e.g. "ElfRanger", and
## DialogueCameraRig/dialogue_overlay.gd resolve it for free — both
## already look tokens up via participants.get(token) generically, keyed
## by actual node name rather than a synthetic index so it stays legible
## to whoever's authoring the .tres and stable across roster changes.
func _build_participants(actor: Unit, unit_target: Unit) -> Dictionary:
	var participants: Dictionary = {"player": actor, "npc": unit_target}
	for unit in UnitQuery.core_party_units(actor.get_tree()):
		if unit != actor:
			participants[unit.name] = unit
	return participants
