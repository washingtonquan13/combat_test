extends Node
## Party progression: one shared XP total and level, WotR-style, and the
## points each level hands every party member to spend.
##
## There are no classes. A level is a bundle of GURPS points (see
## ProgressionTable): attribute points, skill points and ability picks,
## spent in character creation's level-up mode, which reopens the same
## point-buy with the character's current values as the floor. What is
## not spent carries over, per member.
##
## XP is party-wide; the points are per member, keyed by persistent_id,
## so they survive a world swap (when the Unit is freed and only its
## PartyMemberData remains) and a save. A member who joins later starts
## with none: there is no back-pay yet.
##
## Encounter XP: when a fight the party took part in ends in its favour,
## every foe that died in it is worth xp_per_foe_level times its level
## (see Encounter.defeated_foe_levels).

signal xp_changed(xp: int, level: int)
signal leveled_up(level: int)
## A member's unspent points changed — they gained a level, or spent.
signal points_changed(member_id: StringName)

const TABLE: ProgressionTable = preload("res://data/progression/progression.tres")
const TOAST: PackedScene = preload("res://systems/progression_system/level_up_toast.tscn")

const ATTRIBUTES := &"attributes"
const SKILLS := &"skills"
const ABILITIES := &"abilities"

var xp: int = 0
var level: int = 1

## StringName (persistent_id) -> {"attributes": int, "skills": int, "abilities": int}
var _unspent: Dictionary = {}
var _toast: Node = null


## SaveManager is created after this autoload, so registering waits a
## frame — the same reason as PartyManager._register_persistence.
func _ready() -> void:
	CombatManager.encounter_finished.connect(_on_encounter_finished)
	_connect_save_manager.call_deferred()


func _connect_save_manager() -> void:
	SaveManager.register(&"progression", self)
	SaveManager.new_game_started.connect(_on_new_game_started)


func _exit_tree() -> void:
	if CombatManager.encounter_finished.is_connected(_on_encounter_finished):
		CombatManager.encounter_finished.disconnect(_on_encounter_finished)
	if SaveManager.new_game_started.is_connected(_on_new_game_started):
		SaveManager.new_game_started.disconnect(_on_new_game_started)


# --- XP ---------------------------------------------------------------

func award_xp(amount: int, reason: String = "") -> void:
	if amount <= 0:
		return
	xp += amount
	SystemLog.print("[b]+%d XP[/b]%s" % [amount, (" — " + reason) if not reason.is_empty() else ""])
	var reached: int = TABLE.level_for(xp)
	while level < reached:
		level += 1
		_grant_level_to_party()
		SystemLog.print("[b]Level %d reached.[/b]" % level)
		leveled_up.emit(level)
		_show_toast()
	xp_changed.emit(xp, level)


## XP still needed for the next level, from this level's start: the two
## numbers an XP bar draws. Both 0 at the cap.
func progress() -> Vector2i:
	var start: int = TABLE.xp_for(level)
	var next: int = TABLE.xp_for_next(level)
	if next < 0:
		return Vector2i.ZERO
	return Vector2i(xp - start, next - start)


func _on_encounter_finished(encounter: Encounter, winning_faction: StringName) -> void:
	if not encounter.player_took_part or encounter.defeated_foe_levels.is_empty():
		return
	if winning_faction == &"" or FactionRelations.is_hostile(winning_faction, Unit.PLAYER_FACTION):
		return
	var total: int = 0
	for foe_level in encounter.defeated_foe_levels:
		total += TABLE.xp_per_foe_level * maxi(foe_level, 1)
	award_xp(total, "%d foe%s defeated" % [encounter.defeated_foe_levels.size(),
		"" if encounter.defeated_foe_levels.size() == 1 else "s"])


# --- Points -------------------------------------------------------------

## The party as it stands, live or captured, and the fallen too: a dead
## member still levels with the party, as in WotR, so reviving one does
## not bring back someone left behind.
func _grant_level_to_party() -> void:
	var everyone: Array = PartyManager.everyone()
	everyone.append_array(PartyManager.fallen)
	for member in everyone:
		var id: StringName = member_id(member)
		if id == &"":
			continue
		var points: Dictionary = _points_of(id)
		points[ATTRIBUTES] += TABLE.attribute_points
		points[SKILLS] += TABLE.skill_points
		points[ABILITIES] += TABLE.ability_picks
		points_changed.emit(id)


## A Unit's persistent_id (minted if it has none yet, as PartyManager
## does on capture) or a PartyMemberData's id.
func member_id(member: Object) -> StringName:
	if member is Unit:
		var unit := member as Unit
		if unit.persistent_id == &"":
			unit.persistent_id = Unit.generate_persistent_id()
		return unit.persistent_id
	if member is PartyMemberData:
		return (member as PartyMemberData).id
	return &""


## A copy: spend() is the only writer.
func unspent(member: Object) -> Dictionary:
	return _points_of(member_id(member)).duplicate()


func has_unspent(member: Object) -> bool:
	var points: Dictionary = _points_of(member_id(member))
	return points[ATTRIBUTES] > 0 or points[SKILLS] > 0 or points[ABILITIES] > 0


## Takes points the level-up screen spent. Refuses (and changes nothing)
## if any amount is more than the member has.
func spend(member: Object, attributes: int, skills: int, abilities: int) -> bool:
	var id: StringName = member_id(member)
	var points: Dictionary = _points_of(id)
	if attributes > points[ATTRIBUTES] or skills > points[SKILLS] or abilities > points[ABILITIES]:
		return false
	if attributes < 0 or skills < 0 or abilities < 0:
		return false
	points[ATTRIBUTES] -= attributes
	points[SKILLS] -= skills
	points[ABILITIES] -= abilities
	points_changed.emit(id)
	return true


func _points_of(id: StringName) -> Dictionary:
	if not _unspent.has(id):
		_unspent[id] = {ATTRIBUTES: 0, SKILLS: 0, ABILITIES: 0}
	return _unspent[id]


# --- Level-up screen ------------------------------------------------------

## Opens character creation in level-up mode for `unit`. Returns why not,
## or "" when it opened.
func open_level_up(unit: Unit) -> String:
	var screen: Node = get_tree().get_first_node_in_group(&"character_creation")
	if screen == null or not screen.has_method("open_level_up"):
		return "No character screen."
	return screen.open_level_up(unit)


func _show_toast() -> void:
	if not is_instance_valid(_toast):
		_toast = TOAST.instantiate()
		add_child(_toast)
	_toast.show_level(level)


# --- Save ---------------------------------------------------------------

func save_state() -> Dictionary:
	var points: Dictionary = {}
	for id in _unspent:
		var entry: Dictionary = _unspent[id]
		if entry[ATTRIBUTES] == 0 and entry[SKILLS] == 0 and entry[ABILITIES] == 0:
			continue
		points[String(id)] = {
			"attributes": entry[ATTRIBUTES], "skills": entry[SKILLS], "abilities": entry[ABILITIES]}
	return {"xp": xp, "level": level, "unspent": points}


func load_state(state: Dictionary) -> void:
	_reset()
	xp = int(state.get("xp", 0))
	level = maxi(int(state.get("level", 1)), 1)
	var points: Dictionary = state.get("unspent", {})
	for id in points:
		var entry: Dictionary = points[id]
		_unspent[StringName(id)] = {
			ATTRIBUTES: int(entry.get("attributes", 0)),
			SKILLS: int(entry.get("skills", 0)),
			ABILITIES: int(entry.get("abilities", 0)),
		}
	xp_changed.emit(xp, level)


func _on_new_game_started() -> void:
	_reset()
	xp_changed.emit(xp, level)


func _reset() -> void:
	xp = 0
	level = 1
	_unspent.clear()
	if is_instance_valid(_toast):
		_toast.hide_now()
