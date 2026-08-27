extends Node
## Combat test harness — merge this into your main scene's root script.
##
## SETUP:
##  1. Project Settings > Input Map: add three actions —
##       "test_start_combat" mapped to a key (e.g. K)
##       "test_end_turn"      mapped to a key (e.g. N)
##       "test_delay_turn"    mapped to a key (e.g. M)
##  2. Make sure your Unit instances are already in the scene tree, each
##     with `faction` set appropriately (player units default to "player";
##     give enemies something else, e.g. "enemy").
##  3. Run the scene, press the start-combat key. There's no combat UI yet,
##     so everything prints to the Output panel: turn order, whose turn it
##     is, every attack/move/death.
##  4. On your turn: right-click the ground to move (respects move budget),
##     left-click an enemy to attack (see unit.gd _on_input_event). Press
##     the end-turn key when you're done acting, or the delay-turn key to
##     give up this turn for now and go later in this same round instead
##     (see CombatManager.delay_turn — defaults to delaying by 1).

## Debug-only trigger for SceneManager.push_scene()/pop_scene() (L key —
## see project.godot's test_toggle_scene_push) so the push/pop cycle has
## something to actually exercise in a running game before the real
## fusion-room scene exists. Not itself part of the scene-swapping
## feature — delete once something real calls push_scene/pop_scene.
const _SCENE_MANAGER_TEST_ROOM := preload("res://scenes/scene_manager_test_room.tscn")

var _signals_connected: bool = false
## The raid quest's two goblinoids — see _watch_goblinoid_raid_quest().
## Emptied out as each one dies; townsperson_raids_resolved sets once
## both are gone, regardless of how the fight that killed them started.
var _goblinoids_remaining: Array[Unit] = []


## Bootstrap content, not a permanent architectural constraint — the 3
## non-leader companions are hand-placed today because that's how every
## unit in this project has been authored so far, not because
## PartyManager.members requires it. A future debug add/remove menu can
## add to (or remove from) this same roster at runtime without needing a
## party member to have ever been placed in this scene at all — see
## _build_leader() below, which already proves that shape for real.
func _ready() -> void:
	print(SkillCalculator.get_skill_level($ElfRanger, "Acrobatics").skill_level)
	_watch_goblinoid_raid_quest()
	var leader: Unit = _build_leader()
	PartyManager.add_member(leader)
	PartyManager.add_member($HumanBarbarian)
	PartyManager.add_member($DwarfFighter)
	PartyManager.add_member($ElfRanger)
	PartyManager.set_leader(leader)


## Returns the real leader Unit for this session — deliberately NOT the
## same thing as "reuse whatever's already hand-placed in the scene."
## If a character was actually created (see PendingCharacter, written by
## character_creation.gd on Confirm), this instantiates a genuinely
## FRESH unit.tscn and frees the hand-placed TieflingWizard node outright
## — she was only ever a bootstrap placeholder standing in for "the
## leader," never a specific story character, so keeping her around
## unused once a real one exists would just be a second, silent unit
## nobody asked for. This is the actual proof that a party member
## doesn't have to be hardcoded in this scene at all: the same
## instantiate-and-PartyManager.add_member() shape a future debug
## add/remove menu needs is exactly what's used here, not a one-off
## reuse of an existing node.
##
## Falls back to the hand-placed TieflingWizard, completely untouched,
## if chargen was never run (loading straight into this scene for a
## headless test, e.g.) — that fallback has to keep working exactly as
## it did before this existed.
##
## Only the 3 abilities named as "standard for every unit" get assigned
## — a freshly-created blank character hasn't earned a spellbook, by
## design (see the user's own stated intent: richer abilities are meant
## to come from a future debug menu, not be assumed at creation).
func _build_leader() -> Unit:
	var placeholder: Unit = $TieflingWizard

	if not PendingCharacter.is_ready:
		return placeholder

	var leader: Unit = preload("res://unit.tscn").instantiate()
	add_child(leader)
	leader.global_transform = placeholder.global_transform
	leader.faction = Unit.PLAYER_FACTION
	leader.display_name = PendingCharacter.display_name
	leader.strength = PendingCharacter.strength
	leader.dexterity = PendingCharacter.dexterity
	leader.intelligence = PendingCharacter.intelligence
	leader.health = PendingCharacter.health
	leader.abilities = [
		load("res://data/abilities/basic_attack_melee.tres"),
		load("res://data/abilities/jump.tres"),
		load("res://data/abilities/shove.tres"),
	]
	# Matches the other 3 party members' own shared color, authored
	# directly on each of them in this scene — visual party consistency,
	# not a Unit-script default.
	leader.selected_color = Color(0.156863, 1, 1, 0.627451)

	for skill_name in PendingCharacter.skill_levels:
		var relative_level: int = PendingCharacter.skill_levels[skill_name]
		if relative_level == 0:
			continue  # no investment -- nothing to record, matches how an
			# untrained skill just defaults off the controlling attribute
		var skill: Skill = SkillDatabase.find(skill_name)
		if not skill:
			continue
		var instance := SkillInstance.new()
		instance.skill_data = skill
		# SkillInstance's own baseline is levels_purchased=1 ("just the
		# base attribute+difficulty roll"); Bucket C's own notation calls
		# that same baseline "+0" — the +1 is reconciling those two
		# conventions, not an arbitrary offset.
		instance.levels_purchased = relative_level + 1
		add_child(instance)  # needs a parent before add_skill's reparent() call below
		leader.add_skill(instance)

	placeholder.queue_free()
	PendingCharacter.clear()
	return leader


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("test_start_combat"):
		_start_test_combat()
	elif event.is_action_pressed("test_end_turn"):
		if CombatManager.in_combat:
			CombatManager.end_turn()
	elif event.is_action_pressed("test_delay_turn"):
		if CombatManager.in_combat:
			var unit: Unit = CombatManager.current_unit
			if unit and not CombatManager.delay_turn(unit):
				print("Couldn't delay ", unit.get_display_name(), "'s turn.")
	elif event.is_action_pressed("test_toggle_scene_push"):
		_toggle_scene_push()


func _toggle_scene_push() -> void:
	if SceneManager.current_root() == self:
		SceneManager.push_scene(_SCENE_MANAGER_TEST_ROOM)
	else:
		SceneManager.pop_scene()


func _start_test_combat() -> void:
	if CombatManager.in_combat:
		print("Combat already in progress.")
		return

	var units: Array[Unit] = UnitQuery.living_units(get_tree())

	if units.is_empty():
		print("No units found in the 'units' group — nothing to fight with.")
		return

	_connect_debug_signals(units)
	CombatManager.start_combat(units)


func _connect_debug_signals(units: Array[Unit]) -> void:
	if not _signals_connected:
		CombatManager.combat_started.connect(_on_combat_started)
		CombatManager.turn_started.connect(_on_turn_started)
		CombatManager.combat_ended.connect(_on_combat_ended)
		_signals_connected = true

	for unit in units:
		if not unit.ability_used.is_connected(_on_unit_ability_used):
			unit.ability_used.connect(_on_unit_ability_used)
		if not unit.died.is_connected(_on_unit_died):
			unit.died.connect(_on_unit_died)


func _on_combat_started(turn_order: Array[Unit]) -> void:
	print("--- Combat started ---")
	for unit in turn_order:
		print("  ", unit.get_display_name(), " (", unit.faction, ") DX ", unit.get_stat("DX"), " HP ", unit.current_hp)


func _on_turn_started(unit: Unit) -> void:
	var status_note: String = " — CANNOT ACT (status effect)" if unit.status_prevents_turn() else ""
	print("-> ", unit.get_display_name(), "'s turn (move budget ", unit.move_remaining, ")", status_note)
	# Auto-select the acting unit so a right-click moves it and a left-click
	# on an enemy attacks it, without manually clicking it first each turn.
	SelectionManager.select(unit)


func _on_unit_ability_used(attacker: Unit, target, result: Dictionary) -> void:
	var target_desc: String = target.get_display_name() if target is Unit else str(target)

	if result.already_acted:
		print("   ", attacker.get_display_name(), " has already acted this turn.")
	elif not result.in_range:
		print("   ", attacker.get_display_name(), " is out of range of ", target_desc, " with ", result.ability.ability_name)
	elif result.ability.requires_to_hit and not result.to_hit.success:
		print("   ", attacker.get_display_name(), " misses ", target_desc, " with ", result.ability.ability_name,
				" (rolled ", result.to_hit.roll, " vs ", result.to_hit.target, ")")
	elif target is Unit:
		print("   ", attacker.get_display_name(), " hits ", target_desc, " with ", result.ability.ability_name,
				" for ", result.damage, " damage (", target.current_hp, " HP left)")
	else:
		print("   ", attacker.get_display_name(), " uses ", result.ability.ability_name, " at ", target_desc)


func _on_unit_died(unit: Unit) -> void:
	print("   ", unit.get_display_name(), " has died.")


## Connected unconditionally at scene start, NOT through
## _connect_debug_signals above — that only wires up when combat starts
## via the K-key test harness, so it'd silently never fire for combat
## triggered the real way (clicking the hostile unit directly). The
## Scared Townperson's second dialogue phase (see her dialogue_options /
## resolved_hub.tres) depends on this flag actually getting set in a
## normal playthrough, not just the debug path.
func _watch_goblinoid_raid_quest() -> void:
	_goblinoids_remaining = [$GoblinRogue as Unit, $Hobgoblin as Unit]
	for goblinoid in _goblinoids_remaining:
		goblinoid.died.connect(_on_goblinoid_died)


func _on_goblinoid_died(unit: Unit) -> void:
	_goblinoids_remaining.erase(unit)
	if _goblinoids_remaining.is_empty():
		FlagManager.set_flag("townsperson_raids_resolved")


func _on_combat_ended(winning_faction: StringName) -> void:
	if winning_faction == &"":
		print("--- Combat ended: mutual wipe, no survivors ---")
	else:
		print("--- Combat ended: ", winning_faction, " wins ---")


## Satisfies SceneManager's duck-typed push/pop contract (see
## systems/scene_system/scene_manager.gd) — called on suspend/resume to
## unregister/re-register this arena's own tactical camera with
## CameraDirector, since a merely-hidden node's _ready() never refires.
func get_tactical_camera() -> Camera3D:
	return $Camera3D
