extends AiTestCase
## Pins the negotiation CONTENT that ships today, not the engine: the ten
## personality trees under data/negotiation/conversations and the demon
## definitions that open them. The rewrite will likely migrate these
## files to a new format; this suite is how that migration proves it
## carried every tree across with the same shape, the same numbers and
## the same wiring, and that one of them still plays end to end.
##
## The shape, as authored for all ten: greeting -> second question ->
## request -> pressed. Both questions offer liked, neutral, disliked
## (pardonable) and hated (ATTACK). Request offers pay-{gold} (a gold-
## gated RECRUIT) or refuse (a mood drop) to pressed. Pressed offers
## RECRUIT or the personality's own exit. The numbers are pinned exactly,
## per personality, because they ARE the balance.
##
## wants_world(): the playthrough is a real fight. Everything goes
## through conversation_driver.gd.

const Driver := preload("res://tests/conversation/conversation_driver.gd")

## personality -> [second question, liked, neutral, refuse, exit].
## A number is a flat mood shift; a pair is a volatile [min, max].
const TREES: Dictionary = {
	"calm": ["calm_faith", 3, 1, -2, "flee"],
	"cryptic": ["cryptic_riddle", 3, 1, -1, "flee"],
	"dumb": ["dumb_strong", 3, 1, -2, "flee"],
	"foolish": ["foolish_purple", 3, 1, -1, "flee"],
	"girly": ["girly_bearing", 3, 1, -2, "flee"],
	"kind": ["kind_sacrifice", 3, 1, -1, "heal"],
	"moody": ["moody_again", [1, 4], [-2, 3], [-4, 1], "flee"],
	"scary": ["scary_command", 3, 1, -3, "attack"],
	"sly": ["sly_deal", 3, 1, -2, "flee"],
	"wild": ["wild_pressure", 3, 1, -2, "attack"],
}

var d: Driver
var ada: Unit


func wants_world() -> bool:
	return true


func run() -> void:
	d = Driver.new()
	add_child(d)
	d.begin()
	ada = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3(0, 0, 0))
	ada.display_name = "Ada"

	for personality in TREES:
		_tree_shape(personality)
	_roots_wired()
	await _a_calm_demon_plays_through()

	d.finish()


func _mood_of(c: Dictionary):
	return c.mood_range if not c.mood_range.is_empty() else c.mood


func _dump(n: Dictionary) -> String:
	var parts: Array[String] = []
	for c in n.get("choices", []):
		parts.append("%s>%s%s m=%s gold=%s/%s" % [c.kind, c.next, c.outcome, str(_mood_of(c)),
			c.pays_negotiated_gold, c.gated_by_negotiated_gold])
	return "%s: %s" % [n.get("id", "?"), " | ".join(parts)]


func _question(id: String, to: String, liked, neutral) -> String:
	var n: Dictionary = d.negotiation_node(id)
	if n.is_empty():
		return "missing"
	var c: Array = n.choices
	if c.size() != 4:
		return "count"
	var kinds: Array = c.map(func(x): return x.kind)
	# The hated answer was its own choice class before the rewrite; it is
	# now an ordinary choice ending in ATTACK, so the driver reports it as
	# the outcome it is.
	if str(kinds) != str(["line", "line", "disliked", "outcome"]) or c[3].outcome != "attack":
		return "kinds"
	if c[0].next != to or c[1].next != to or c[2].next != to:
		return "routing"
	if str(_mood_of(c[0])) != str(liked) or str(_mood_of(c[1])) != str(neutral):
		return "mood"
	if _mood_of(c[2]) is int and _mood_of(c[2]) != 0 or not c[2].mood_range.is_empty():
		return "disliked mood"
	return ""


## authored_tree_shape.
func _tree_shape(p: String) -> void:
	var t: Array = TREES[p]
	var greeting: String = p + "_greeting"
	var request: String = p + "_request"
	var pressed: String = p + "_pressed"

	var why: String = _question(greeting, t[0], t[1], t[2])
	check("%s: the greeting asks liked/neutral/disliked/hated, all three answers to %s" % [p, t[0]],
		why == "", why + " " + _dump(d.negotiation_node(greeting)))
	why = _question(t[0], request, t[1], t[2])
	check("%s: %s asks the same four, on to the request" % [p, t[0]],
		why == "", why + " " + _dump(d.negotiation_node(t[0])))

	var r: Dictionary = d.negotiation_node(request)
	var ok: bool = not r.is_empty() and r.choices.size() == 2 \
		and r.text.contains("{gold}") \
		and r.choices[0].kind == "outcome" and r.choices[0].outcome == "recruit" \
		and r.choices[0].pays_negotiated_gold and r.choices[0].gated_by_negotiated_gold \
		and r.choices[1].kind == "line" and r.choices[1].next == pressed \
		and str(_mood_of(r.choices[1])) == str(t[3])
	check("%s: the request asks {gold}: pay it (gated, recruits) or refuse (%s) to pressed" % [p, str(t[3])],
		ok, _dump(r))

	var pr: Dictionary = d.negotiation_node(pressed)
	ok = not pr.is_empty() and pr.choices.size() == 2 \
		and pr.choices.all(func(c): return c.kind == "outcome") \
		and pr.choices[0].outcome == "recruit" and pr.choices[1].outcome == t[4]
	check("%s: pressed offers recruit or %s" % [p, t[4]], ok, _dump(pr))

	var extras: bool = false
	for id in [greeting, t[0], request, pressed]:
		for c in d.negotiation_node(id).get("choices", []):
			extras = extras or c.extras
	check("%s: no choice authors a flag, alignment, spoken line or repeat" % p, not extras)


## demon_roots_wired.
func _roots_wired() -> void:
	var negotiable: int = 0
	var bad: Array[String] = []
	var greetings: Array = TREES.keys().map(func(p): return p + "_greeting")
	var used: Dictionary = {}
	for id in d.all_species_ids():
		var def: UnitDefinition = d.species(id)
		if not def.negotiable:
			continue
		negotiable += 1
		var roots: Array[Dictionary] = d.species_root_options(def)
		var opens: String = d.species_root_id(def, ada)
		if roots.size() != 1 or roots[0].conditioned or not greetings.has(opens):
			bad.append("%s %s %s" % [id, str(roots), opens])
		used[opens] = true
	check("28 species are negotiable", negotiable == 28, str(negotiable))
	check("each opens on one unconditioned root, a personality's greeting", bad.is_empty(), str(bad))
	check("and all ten personalities are in use", used.size() == 10, str(used.keys()))
	check("test_pixie is not negotiable, though it has a tree",
		not d.species("test_pixie").negotiable and d.species_root_id(d.species("test_pixie"), ada) != "")
	check("the goblin opens on sly", d.species_root_id(d.species("goblin_rogue"), ada) == "sly_greeting")


## A shipped tree, played: calm, the long way round to a recruit.
func _a_calm_demon_plays_through() -> void:
	var calm_id: String = ""
	for id in d.all_species_ids():
		if d.species(id).negotiable and d.species_root_id(d.species(id), ada) == "calm_greeting":
			calm_id = id
			break
	var demon: Unit = d.spawn_species(self, d.species(calm_id), Vector3(3, 0, 0))
	var fight: Encounter = d.start_fight([ada, demon])
	await get_tree().process_frame
	ada.alignment = 0
	ada.tendency = 0
	demon.alignment = 0
	demon.tendency = 0
	d.start_negotiation(ada, demon)
	check("setup: %s opens on the calm greeting" % calm_id, d.current_node_id() == "calm_greeting")
	var g: Dictionary = d.negotiation_node("calm_greeting")
	var faith: Dictionary = d.negotiation_node("calm_faith")
	await d.choose(g.choices[2].text)
	check("a disliked answer is pardoned and moves on", d.current_node_id() == "calm_faith" and not d.pardon_available())
	await d.choose(faith.choices[0].text)
	check("the liked answer raises the mood by 3", d.current_node_id() == "calm_request" and d.mood() == 3, str(d.mood()))
	var owned_before: int = DemonRoster.all_owned().size()
	var req: Dictionary = d.negotiation_node("calm_request")
	await d.choose(req.choices[1].text)
	check("refusing to pay presses, and costs calm 2 mood", d.current_node_id() == "calm_pressed" and d.mood() == 1, str(d.mood()))
	var pressed: Dictionary = d.negotiation_node("calm_pressed")
	d.clear_events()
	d.pin_outcome_roll(true)
	await d.choose(pressed.choices[0].text)
	check("and the pressed recruit, on a good roll, adds it to the roster",
		d.events.back() == "negotiation_ended:RECRUIT" and DemonRoster.all_owned().size() == owned_before + 1, str(d.events))
	await get_tree().process_frame
	if is_instance_valid(demon):
		remove_spawned(demon)
	d.stop_fights()
	await get_tree().process_frame
