extends AiTestCase
## A second New Game starts a new game. Today it resumes the first one.
##
## The 4-step repro, made headless: play a bit, Esc back out to the title
## screen, press START again, build a different character, confirm. What
## arrives is the FIRST character's party, standing in an arena that still
## remembers the enemy you killed, carrying the gold you earned, with the
## flags you set and the demons you recruited — and the chargen screen you
## just filled in was still holding the previous build's name and points.
##
## THE ROOT OF IT is that nothing in the front end ever said "forget
## everything". WorldManager.unload() -> _disembody() -> PartyManager
## .capture() deliberately folds the live party down to records, because
## that is exactly right for walking out of a world. Nothing then throws
## those records away, and world/test_arena.gd:39-40 guards its starting-
## party bootstrap on `PartyManager.members.is_empty() or roster
## .is_empty()` — so on the second run the bootstrap returns early,
## pending_leader is never consumed, and the old party respawns. Every
## other global (FlagManager, and therefore AreaState; DemonRoster;
## CurrencyManager; FactionRelations) is simply never reset at all, and
## the chargen screen is instanced once and never re-initialised.
##
## WHAT IS BEING BUILT, and what this asserts against: SaveManager
## .new_game(), which refuses unless WorldManager.can_rebuild() and a
## `party_overview` node exists, then discards the worlds FIRST and calls
## load_state({}) on every registered persistable in _load_order() —
## "become what a save that says nothing says" — before clearing
## pending_leader and emitting new_game_started.
##
## VERIFIED FACTS THESE ASSERTIONS REST ON (from the investigation, so a
## reader knows which checks can never have been the bug):
##   - unload() clears WorldManager._residents, and the second load builds
##     a genuinely FRESH test_arena, reported with Entry.TRAVEL. So
##     "different world instance" and "the reason was TRAVEL" are GREEN
##     TODAY. They are CONTROLS: they say the harness really did tear the
##     world down and build another, which is what makes every red check
##     below mean "the STATE came back", not "the world was reused".
##   - a fresh test_arena bootstrap produces 4 members: the leader from
##     pending_leader plus 3 companions from data/companions.
##
## EXPECTED RED ON THE CURRENT CODE (9):
##   the party is the new character's; pending_leader was consumed; the
##   flag is gone; the enemy is back; gold is STARTING_GOLD; the demon
##   roster is empty; the summon cap is back to its default; the faction
##   pair is back to its authored tier; the chargen form is blank.
##   Plus "new_game() with nothing loaded returns true" (the fresh-boot
##   path), and the SETUP check that new_game() exists at all.
## GREEN TODAY (controls, 4):
##   the world instance changed; the reason was TRAVEL; unload() leaves
##   the old party in roster (a SETUP fact, not the bug); and the NEGATIVE
##   CONTROL, which is green today only vacuously — a method that does not
##   exist cannot return true. Its detail says so.
##
## Every global is snapshotted through the same save_state()/load_state()
## pair the save file itself uses and put back in _restore() whatever
## happens — AreaState lives inside FlagManager, so a suite that mangles
## an area and walks away resurrects or deletes entities for every suite
## after it.

const HOME := &"test_arena"
## An authored enemy in HOME with a persistent_id, so AreaState can be
## made to remember it as dead. Same one test_the_starting_party_has_bodies
## uses as its own control.
const ENEMY_ID := &"test_arena_hobgoblin"
const MARKER_FLAG := "test.new_game.marker"
const FIRST_NAME := "First"
const SECOND_NAME := "Second"
## Deliberately not STARTING_GOLD and not a multiple of it — a purse that
## happened to equal the starting value would make the gold check pass
## without discriminating anything.
const GOLD_NUDGE := 137
## Not DEFAULT_MAX_ACTIVE_SUMMONS, for the same reason.
const CAP_NUDGE := 9
const DEMON_SPECIES := "res://data/units/demons/avian.tres"
const LEADER_DEFINITION := "res://data/units/companions/player_character.tres"
## A real pair: Unit.PLAYER_FACTION is what a party member carries and
## &"enemy" is what every spawned hostile in this harness carries.
const FACTION_A := Unit.PLAYER_FACTION
const FACTION_B := &"enemy"

var _host: Control
var _saved_host: Control = null
var _saved_attention: Array[Node] = []
var _overview: Node = null
var _chargen: Control = null
var _snapshot: Dictionary = {}
## Every world_loaded reason, in build order.
var _reasons: Array = []
## Named parts of the API that have not landed, so one SETUP check can
## report the whole gap instead of the suite dying on an unknown method.
var _missing: PackedStringArray = []


func run() -> void:
	if not _install_synthetic_host():
		check("SETUP: synthetic world host installed", false)
		_restore()
		return

	_snapshot_globals()
	_install_party_overview()
	WorldManager.world_loaded.connect(_note_reason)

	# --- step 1: play a bit -------------------------------------------
	# An empty slate first, or test_arena's bootstrap sees a previous
	# suite's roster and leaves the party alone — this suite would then be
	# measuring somebody else's party instead of the one a new game makes.
	PartyManager.clear_members()
	PartyManager.load_state({})
	PartyManager.pending_leader = null
	# AreaState is flags, and flags outlive suites. Anything a previous
	# suite recorded about HOME would show up here as "the enemy was
	# already dead before this test killed it".
	AreaState.clear_area(HOME)
	FlagManager.clear_flag(MARKER_FLAG)

	# The chargen screen is opened BEFORE anything is dirtied, so its
	# pristine attribute header can be read and compared against later —
	# and before _audit_api(), which asks it whether reset() has landed.
	if not _open_character_creation():
		check("SETUP: a character-creation screen to fill in", false,
			"could not instantiate %s" % "res://systems/character_creation_system/character_creation.tscn")
		_restore()
		return
	var pristine_attributes: String = _attributes_header()

	_audit_api()
	check("SETUP: the new-game API has landed",
		_missing.is_empty(),
		"missing: %s — every assertion below still runs, so the check " % ", ".join(_missing) +
		"count is the same before and after the fix; they simply all fail")

	PartyManager.pending_leader = _leader_record(FIRST_NAME)
	WorldManager.load_area(HOME)
	await get_tree().process_frame
	await get_tree().process_frame

	var first_world: Node = WorldManager.current_world()
	var first_world_id: int = first_world.get_instance_id() if is_instance_valid(first_world) else 0
	var area: AreaDefinition = WorldManager.current_area()
	if area == null or area.id != HOME or first_world_id == 0:
		check("SETUP: the first game is standing in the starting area", false,
			"focused on %s" % ("nothing" if area == null else String(area.id)))
		_restore()
		return

	check("SETUP: the first game's party is the first character's",
		_leader_name() == FIRST_NAME and _live_members().size() == 4,
		"leader '%s', %d member(s) — %s" % [
			_leader_name(), _live_members().size(), _describe_party()])

	var enemy: Node = _find_persistent(first_world, ENEMY_ID)
	check("SETUP: the enemy that is about to die is really in the arena",
		enemy != null, "no node with persistent_id '%s'" % ENEMY_ID)

	# Now dirty every kind of state a session accumulates, each through
	# the same call the game itself makes.
	FlagManager.set_flag(MARKER_FLAG)
	CurrencyManager.add_gold(GOLD_NUDGE)
	var recruited: bool = _recruit_a_demon()
	DemonRoster.max_active_summons = CAP_NUDGE
	var authored_relation: int = FactionRelations.get_relation(FACTION_A, FACTION_B)
	FactionRelations.set_relation(FACTION_A, FACTION_B, FactionRelations.Tier.ALLIED)
	# What a death records: the entity should not exist here any more. Set
	# through AreaState rather than by killing the unit, because the
	# question under test is whether a new game FORGETS this record, not
	# whether the damage system writes it.
	AreaState.mark_removed(HOME, ENEMY_ID)

	check("SETUP: the session really is dirty",
		FlagManager.has_flag(MARKER_FLAG)
			and CurrencyManager.gold != CurrencyManager.STARTING_GOLD
			and recruited
			and DemonRoster.max_active_summons != DemonRoster.DEFAULT_MAX_ACTIVE_SUMMONS
			and FactionRelations.get_relation(FACTION_A, FACTION_B) != authored_relation
			and AreaState.is_removed(HOME, ENEMY_ID),
		"flag=%s gold=%d demons=%d cap=%d relation=%d->%d enemy_removed=%s" % [
			FlagManager.has_flag(MARKER_FLAG), CurrencyManager.gold,
			DemonRoster.all_owned().size(), DemonRoster.max_active_summons,
			authored_relation, FactionRelations.get_relation(FACTION_A, FACTION_B),
			AreaState.is_removed(HOME, ENEMY_ID)])

	_dirty_character_creation()
	check("SETUP: the character-creation form is filled in",
		_typed_name() != "" and _attributes_header() != pristine_attributes,
		"name '%s', attributes header '%s' (was '%s')" % [
			_typed_name(), _attributes_header(), pristine_attributes])

	# --- step 2: Esc back out to the title screen ---------------------
	# The real EscMenu is inline in MainRoot, which does not exist here, so
	# its one world-facing call is made directly.
	var unloaded: bool = WorldManager.unload()
	await get_tree().process_frame
	check("SETUP: backing out to the title screen unloads the world",
		unloaded and WorldManager.current_world() == null,
		"unload() returned %s, current world %s" % [
			unloaded, "null" if WorldManager.current_world() == null else "still standing"])

	# GREEN TODAY, and deliberately so. capture() folding the party down to
	# records on the way out is correct behaviour for leaving a world; the
	# bug is that nothing afterwards throws those records away. Asserted so
	# a future reader can tell this suite's red from a broken capture.
	check("CONTROL: leaving a world leaves the old party behind as records",
		_roster_has(FIRST_NAME),
		"roster after unload: %s" % _describe_roster())

	# --- step 3: press START again ------------------------------------
	# The screen is put away and brought back, which is what a player
	# stepping through title -> START actually does to it.
	if is_instance_valid(_chargen):
		_chargen.visible = false

	var started: bool = _call_new_game()
	check("SETUP: new_game() exists and reports that it started one",
		started,
		"returned %s%s" % [started,
			"" if SaveManager.has_method("new_game") else " — SaveManager has no new_game()"])

	if is_instance_valid(_chargen):
		_chargen.visible = true
	await get_tree().process_frame

	# Asserted BEFORE the second load, so no part of building a world can
	# be credited with clearing them.
	check("a new game forgets the flags the last one set",
		not FlagManager.has_flag(MARKER_FLAG),
		"'%s' is still set — FlagManager was never reset, and AreaState " % MARKER_FLAG +
		"lives inside it, so the arena remembers the last game too")

	check("a new game starts on the starting purse",
		CurrencyManager.gold == CurrencyManager.STARTING_GOLD,
		"%d gold, expected %d — the last game's earnings carried over" % [
			CurrencyManager.gold, CurrencyManager.STARTING_GOLD])

	check("a new game starts with no demons",
		DemonRoster.all_owned().is_empty(),
		"%d demon(s) still on the roster" % DemonRoster.all_owned().size())

	check("and with the default cap on how many can be fielded",
		DemonRoster.max_active_summons == DemonRoster.DEFAULT_MAX_ACTIVE_SUMMONS,
		"cap is %d, expected %d" % [
			DemonRoster.max_active_summons, DemonRoster.DEFAULT_MAX_ACTIVE_SUMMONS])

	check("and with the authored faction table, not the last game's diplomacy",
		FactionRelations.get_relation(FACTION_A, FACTION_B) == authored_relation,
		"'%s' vs '%s' is tier %d, authored default is tier %d" % [
			FACTION_A, FACTION_B,
			FactionRelations.get_relation(FACTION_A, FACTION_B), authored_relation])

	check("and the character-creation screen is blank again",
		_typed_name() == "" and _attributes_header() == pristine_attributes,
		"still shows name '%s' and '%s' (a fresh screen shows '%s') — the " % [
			_typed_name(), _attributes_header(), pristine_attributes] +
		"screen is instanced once and its dictionaries are built in _ready()")

	PartyManager.pending_leader = _leader_record(SECOND_NAME)
	WorldManager.load_area(HOME)
	await get_tree().process_frame
	await get_tree().process_frame

	var second_world: Node = WorldManager.current_world()
	var second_world_id: int = second_world.get_instance_id() if is_instance_valid(second_world) else 0

	# --- the controls: the harness really did rebuild -------------------
	check("CONTROL: the second game stands in a different world object",
		second_world_id != 0 and second_world_id != first_world_id,
		"first world #%d, second world #%d — if these match, unload() did " % [
			first_world_id, second_world_id] +
		"not tear the arena down and every failure below is the harness")

	check("CONTROL: and got there by travelling, not by a save rebuild",
		not _reasons.is_empty() and _reasons[-1] == WorldManager.Entry.TRAVEL,
		"reasons in build order: %s (TRAVEL=%d, REBUILD=%d)" % [
			str(_reasons), WorldManager.Entry.TRAVEL, WorldManager.Entry.REBUILD])

	# --- the bug, as the player meets it -------------------------------
	check("the second game's party is the second character's",
		_leader_name() == SECOND_NAME and _live_members().size() == 4,
		"leader is '%s' with %d member(s) — %s. test_arena only bootstraps " % [
			_leader_name(), _live_members().size(), _describe_party()] +
		"when the roster is empty, so a surviving roster respawns the old party")

	check("and the character it was given was actually used up",
		PartyManager.pending_leader == null,
		"pending_leader still holds '%s' — nothing consumed it, which is " % (
			"nothing" if PartyManager.pending_leader == null
			else PartyManager.pending_leader.display_name) +
		"the same early return")

	check("and the arena has its dead back",
		_find_persistent(second_world, ENEMY_ID) != null,
		"'%s' is still missing — AreaState is FlagManager's dictionary, " % ENEMY_ID +
		"and a new game that does not clear the flags does not clear the arena")

	_and_it_refuses_without_a_party_overview()
	await _and_a_new_game_works_from_a_cold_boot()
	_restore()


## NEGATIVE CONTROL. new_game() must refuse rather than half-run when the
## shell it needs is not there — the same bargain _why_load_would_fail()
## already makes for a load, and for the same reason: the party's shared
## Inventory is the one persistable owned by a scene, so with no
## PartyOverview in the tree the registry has no [inventory] entry and a
## reset would silently skip it AFTER wiping everything else.
##
## Green today for an uninteresting reason — a method that does not exist
## returns false too — so its detail says which of the two it was.
func _and_it_refuses_without_a_party_overview() -> void:
	if not is_instance_valid(_overview):
		check("SETUP: a party overview to take away", false)
		return
	_overview.remove_from_group("party_overview")
	var others: Node = get_tree().get_first_node_in_group("party_overview")
	if others != null:
		check("SETUP: taking ours away really empties the group", false,
			"a %s is still in it, probably a previous suite's" % others.get_class())
		_overview.add_to_group("party_overview")
		return

	var refused: bool = _call_new_game()
	check("NEGATIVE CONTROL: new_game() refuses with no party overview in the tree",
		not refused,
		"it returned true and wiped the game anyway%s" % (
			"" if SaveManager.has_method("new_game")
			else " (vacuous today: SaveManager has no new_game())"))

	_overview.add_to_group("party_overview")


## The fresh-boot path: START pressed on a title screen that has never
## loaded anything. discard_worlds() is a no-op there and load_state({})
## is being called on systems that are already empty, and neither of those
## is a reason to refuse.
func _and_a_new_game_works_from_a_cold_boot() -> void:
	WorldManager.discard_worlds()
	await get_tree().process_frame
	check("and a new game from a cold boot, with no world loaded, still starts",
		_call_new_game(),
		"refused with nothing loaded%s" % (
			"" if SaveManager.has_method("new_game")
			else " — SaveManager has no new_game()"))


# --- the API under construction ------------------------------------

## Records what has not landed instead of calling into it. A suite that
## dies on an unknown method reports one script error and no checks at
## all, which tells a reader nothing about which half of the fix is
## missing.
func _audit_api() -> void:
	if not SaveManager.has_method("new_game"):
		_missing.append("SaveManager.new_game()")
	if not SaveManager.has_signal("new_game_started"):
		_missing.append("SaveManager.new_game_started")
	if not SaveManager.is_registered(&"factions"):
		_missing.append("SaveManager registration for 'factions'")
	if is_instance_valid(_chargen) and not _chargen.has_method("reset"):
		_missing.append("CharacterCreation.reset()")


func _call_new_game() -> bool:
	if not SaveManager.has_method("new_game"):
		return false
	return SaveManager.new_game()


func _note_reason(_world: Node, reason: WorldManager.Entry) -> void:
	_reasons.append(reason)


# --- the character-creation screen ----------------------------------

## The real screen, instantiated here rather than stubbed — the thing
## under test is that ITS dictionaries get re-initialised, and a stand-in
## would have different ones. Parented to _root rather than pushed through
## UIStack: this suite is asking what the screen HOLDS, not who is
## allowed to see it.
func _open_character_creation() -> bool:
	var scene: PackedScene = load("res://systems/character_creation_system/character_creation.tscn")
	if scene == null:
		return false
	_chargen = scene.instantiate() as Control
	if _chargen == null:
		return false
	_root.add_child(_chargen)
	return true


## Types a name and spends a point, through the widgets themselves rather
## than through the screen's private dictionaries — the same two things a
## player does before pressing Confirm.
func _dirty_character_creation() -> void:
	var edit: LineEdit = _chargen.get_node_or_null("%NameEdit") as LineEdit
	if edit:
		edit.text = "Half-built Character"
	var list: Node = _chargen.get_node_or_null("%AttributesList")
	if list == null:
		return
	for row in list.get_children():
		for widget in row.get_children():
			var button := widget as Button
			if button and button.text == "+" and not button.disabled:
				button.pressed.emit()
				return


func _typed_name() -> String:
	if not is_instance_valid(_chargen):
		return "<no screen>"
	var edit := _chargen.get_node_or_null("%NameEdit") as LineEdit
	if edit == null:
		return "<no name field>"
	return edit.text.strip_edges()


## The attributes header carries "Points remaining: N", so comparing it
## against the header a freshly built screen showed asserts the point-buy
## state without reaching into _attribute_values.
func _attributes_header() -> String:
	if not is_instance_valid(_chargen):
		return "<no screen>"
	var label := _chargen.get_node_or_null("%AttributesHeader") as Label
	if label == null:
		return "<no attributes header>"
	return label.text


# --- fixtures and readers -------------------------------------------

## Built the way character_creation.gd's Confirm builds one — a definition
## (which is what supplies the body), leader flag, name and faction. The
## point-buy values are left at their defaults; this suite is asking WHO
## arrives, not what their strength is.
func _leader_record(display: String) -> PartyMemberData:
	var record := PartyMemberData.new()
	record.definition = load(LEADER_DEFINITION)
	record.is_leader = true
	record.display_name = display
	record.faction = Unit.PLAYER_FACTION
	return record


func _recruit_a_demon() -> bool:
	var species: UnitDefinition = load(DEMON_SPECIES)
	if species == null:
		return false
	DemonRoster.recruit(species)
	return not DemonRoster.all_owned().is_empty()


func _live_members() -> Array[Unit]:
	var live: Array[Unit] = []
	for member in PartyManager.members:
		if is_instance_valid(member):
			live.append(member)
	return live


## The leader by name, read off PartyManager.leader and falling back to
## whoever the party itself flags as leading — so a party that came back
## without leader_changed ever firing still answers honestly.
func _leader_name() -> String:
	if is_instance_valid(PartyManager.leader):
		return PartyManager.leader.get_display_name()
	for member in _live_members():
		if PartyManager.is_leader(member):
			return member.get_display_name()
	return "<nobody>"


func _describe_party() -> String:
	var who: Array[String] = []
	for member in _live_members():
		who.append(member.get_display_name())
	return "party: [%s]" % ", ".join(who)


func _roster_has(display: String) -> bool:
	for record in PartyManager.roster:
		if record.display_name == display:
			return true
	return false


func _describe_roster() -> String:
	var who: Array[String] = []
	for record in PartyManager.roster:
		who.append(record.display_name)
	return "[%s]" % ", ".join(who)


## Any node carrying this persistent_id anywhere under a world. Walks the
## world rather than the "units" group on purpose: queue_free() is
## deferred, so the group can still hold a previous suite's ghost, and a
## ghost answering to this id would make "the dead are back" pass over a
## corpse.
func _find_persistent(root: Node, id: StringName) -> Node:
	if not is_instance_valid(root):
		return null
	if "persistent_id" in root and root.persistent_id == id:
		return root
	for child in root.get_children():
		var found: Node = _find_persistent(child, id)
		if found:
			return found
	return null


# --- harness ---------------------------------------------------------

func _install_synthetic_host() -> bool:
	_saved_host = WorldManager._world_host
	_saved_attention = WorldManager._attention_nodes.duplicate()
	_host = Control.new()
	_root.add_child(_host)
	WorldManager.register_world_host(_host)
	var none: Array[Node] = []
	WorldManager.register_attention_nodes(none)
	return WorldManager.can_travel()


## new_game() refuses without one, exactly as a load already does — the
## party's shared Inventory is registered by PartyOverview and is the one
## persistable that belongs to a scene. The real scene, not a stand-in:
## hand-assembling an Inventory only reproduces it badly, since a bare
## Inventory.new() has none of the child nodes its @onready paths name.
func _install_party_overview() -> void:
	_overview = preload("res://ui/party_overview.tscn").instantiate()
	_root.add_child(_overview)


func _snapshot_globals() -> void:
	_snapshot = {
		"flags": FlagManager.save_state(),
		"party": PartyManager.save_state(),
		"demons": DemonRoster.save_state(),
		"currency": CurrencyManager.save_state(),
		"factions": FactionRelations.save_state(),
	}


func _restore() -> void:
	if WorldManager.world_loaded.is_connected(_note_reason):
		WorldManager.world_loaded.disconnect(_note_reason)
	WorldManager.discard_worlds()
	if not _snapshot.is_empty():
		# Flags LAST of the four would be just as correct; what matters is
		# that flags go back at all — AreaState is inside them, and this
		# suite deliberately marked an authored enemy dead.
		FlagManager.load_state(_snapshot["flags"])
		PartyManager.load_state(_snapshot["party"])
		DemonRoster.load_state(_snapshot["demons"])
		CurrencyManager.load_state(_snapshot["currency"])
		FactionRelations.load_state(_snapshot["factions"])
	PartyManager.pending_leader = null
	while PartyManager.groups.size() > 1:
		PartyManager.groups[0].absorb(PartyManager.groups[1])
		PartyManager.groups.remove_at(1)
	if not PartyManager.groups.is_empty():
		PartyManager.active_group = PartyManager.groups[0]
	WorldManager._world_host = _saved_host
	WorldManager._attention_nodes = _saved_attention
	if is_instance_valid(_chargen):
		_chargen.queue_free()
	if is_instance_valid(_overview):
		_overview.queue_free()
	if is_instance_valid(_host):
		_host.queue_free()
