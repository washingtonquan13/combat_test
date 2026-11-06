extends AiTestCase
## Pins where talking and fighting meet today: who can be talked to, who
## a Talk pulls into the conversation, what a fight refuses, and what a
## dialogue choice that starts a fight does. The two old engines only
## kept out of each other's way by accident (dialogue never asked whether
## a negotiation was open). After the rewrite neither asks about the other
## either: there is one conversation slot, so a dialogue is refused while
## a negotiation holds it, with no check that names either kind.
##
## One pin is surprising and deliberate: Talk brings every party member
## into the conversation, and a party member in a fight anywhere refuses
## it, so a split party with one half fighting cannot Talk at all.
##
## wants_world(): a real world, because fights are per-encounter and
## "in combat" means "in a running encounter", which the bare
## battlefield does not have. Everything conversational goes through
## conversation_driver.gd.

const Driver := preload("res://tests/conversation/conversation_driver.gd")

var d: Driver
var ada: Unit
var brom: Unit
var dex: Unit


func wants_world() -> bool:
	return true


func run() -> void:
	d = Driver.new()
	add_child(d)
	d.begin()
	ada = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3(0, 0, 0))
	ada.display_name = "Ada"
	brom = spawn_unit(&"neutral", 10, 10, 10, [melee()], Vector3(2, 0, 0))
	brom.display_name = "Brom"
	d.give_dialogue(brom, d.node("t_hello", "Hello.", [d.line("Bye.")]))
	await get_tree().physics_frame

	_who_can_be_talked_to()
	_nothing_to_say()
	_talk_brings_the_party()
	await _a_fight_refuses_only_its_own()
	await _dialogue_ignores_negotiation()
	await _a_choice_can_start_a_fight()

	d.finish()


## talk_availability.
func _who_can_be_talked_to() -> void:
	var goblin: Unit = spawn_unit(&"enemy", 10, 10, 10, [melee()], Vector3(-4, 0, 0))
	check("Talk is on every unit", d.offers_talk(brom) and d.offers_talk(goblin))
	check("a unit the actor is not hostile to can be talked to", d.can_talk(ada, brom))
	check("a hostile one cannot", not d.can_talk(ada, goblin))
	var rock := Node3D.new()
	check("something that is not a unit cannot", not d.can_talk(ada, rock))
	rock.free()
	remove_spawned(goblin)


## talk_no_root_log.
func _nothing_to_say() -> void:
	var mute: Unit = spawn_unit(&"neutral", 10, 10, 10, [melee()], Vector3(0, 0, 3))
	mute.name = "MuteNode"
	mute.display_name = "The Mute"
	d.clear_events()
	d.talk(ada, mute)
	check("talking to a unit with no dialogue starts nothing", not d.dialogue_active())
	check("and logs that it has nothing to say, by NODE name",
		d.log_has("MuteNode has nothing to say yet."), str(d.log_lines()))
	remove_spawned(mute)


## talk_participants.
func _talk_brings_the_party() -> void:
	var cato: Unit = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3(-2, 0, 0))
	cato.name = "CatoNode"
	d.talk(ada, brom)
	var who: Dictionary = d.participants()
	check("Talk opens the NPC's dialogue", d.dialogue_active() and d.current_node_id() == "t_hello")
	check("the actor is the player and the target the npc", who.get("player") == ada and who.get("npc") == brom)
	check("every other player unit comes along, keyed by node name",
		who.get("CatoNode") == cato, str(who.keys()))
	check("the actor is not in twice under its own name", not who.has(String(ada.name)), str(who.keys()))
	check("the party leader is there as 'leader' when there is one",
		who.get("leader") == PartyManager.leader if PartyManager.leader else not who.has("leader"),
		str(who.keys()))
	d.end_dialogue()
	remove_spawned(cato)


## dlg_start_refuse_participant_in_combat.
func _a_fight_refuses_only_its_own() -> void:
	dex = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3(10, 0, 0))
	dex.display_name = "Dex"
	var wolf: Unit = spawn_unit(&"enemy", 10, 10, 10, [melee()], Vector3(12, 0, 0))
	d.start_fight([dex, wolf])
	await get_tree().process_frame
	check("setup: Dex is fighting", dex.in_combat() and not ada.in_combat())

	d.start_dialogue(d.node("t_else", "A fight elsewhere.", [d.line("Bye.")]), {"player": ada, "npc": brom})
	check("a fight elsewhere does not stop two others talking", d.dialogue_active())
	d.end_dialogue()

	d.clear_events()
	d.start_dialogue(d.node("t_dex", "You are busy.", [d.line("Bye.")]), {"player": dex, "npc": brom})
	check("a participant who is fighting refuses the dialogue",
		not d.dialogue_active() and d.event_count("dialogue_started") == 0, str(d.events))

	d.talk(ada, brom)
	check("and because Talk brings the whole party, a party member fighting elsewhere refuses Talk",
		not d.dialogue_active())
	d.stop_fights()
	await get_tree().process_frame
	remove_spawned(wolf)
	remove_spawned(dex)


## dlg_start_negotiation_blocked_indirectly, mode_dialogue_derived.
## Changed by the rewrite: a dialogue and a negotiation used to run side
## by side; now the second to begin is refused because one is running.
func _dialogue_ignores_negotiation() -> void:
	var eve: Unit = spawn_unit(&"player", 10, 20, 20, [melee()], Vector3(20, 0, 0))
	var goblin: Unit = spawn_demon("goblin_rogue", Vector3(22, 0, 0))
	d.start_fight([eve, goblin])
	await get_tree().process_frame
	d.start_negotiation(eve, goblin)
	check("setup: a negotiation is open", d.negotiation_active())

	d.start_dialogue(d.node("t_side", "Meanwhile.", [d.line("Bye.")]), {"player": ada, "npc": brom})
	check("a dialogue is refused while a negotiation is running: one conversation at a time",
		not d.dialogue_active() and d.negotiation_active())
	check("and the game's mode stays NEGOTIATION", d.mode() == "NEGOTIATION", d.mode())
	d.end_negotiation("continue")
	check("setup: ending with CONTINUE leaves it open", d.negotiation_active())
	d.end_negotiation("attack")
	check("with no conversation left, the fight's mode returns", d.mode() == "COMBAT", d.mode())
	d.stop_fights()
	await get_tree().process_frame
	remove_spawned(goblin)
	remove_spawned(eve)


## dlg_trigger_combat_effect.
func _a_choice_can_start_a_fight() -> void:
	var root: DialogueNode = d.node("t_insult", "Well?", [d.line("Draw steel.", "t_after", {"effects": [d.starts_fight()]})])
	var after: DialogueNode = d.node("t_after", "So be it.", [d.line("Bye.")])
	d.register_dialogue([root, after])
	check("setup: not hostile before", not ada.is_hostile_to(brom))
	d.start_dialogue(root, {"player": ada, "npc": brom})
	await d.choose("Draw steel.")
	check("the choice starts a fight with the NPC", brom.in_combat() and ada.in_combat())
	check("and makes their sides hostile", ada.is_hostile_to(brom) and brom.is_hostile_to(ada))
	check("the dialogue does not end itself: it goes on to its next node",
		d.dialogue_active() and d.current_node_id() == "t_after", d.current_node_id())
	d.end_dialogue()
	d.stop_fights()
	await get_tree().process_frame
