extends Node
## Debug-only combat test harness, lives on the persistent MainRoot shell
## (a sibling of GroundClickTarget/Indicators — see MainRoot.tscn) rather
## than any one area's own script. Moved out of test_arena.gd during the
## GameArea interface pass: this was never test_arena content — it
## operates globally on UnitQuery.living_units(get_tree()), and every
## area script that existed simply had it copy-pasted in, which is
## exactly the kind of unrelated content that made copying test_arena.gd
## look like the only way to get a new area its real ~25 lines of world
## contract.
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
##
## Connects to CombatManager once here, persistently — safe in this
## direction even though this node outlives every world: CombatManager
## itself is an autoload (also persistent), and the PER-UNIT signals
## (ability_used/died) are connected fresh each time combat starts,
## against whichever Units are alive THEN. A transient Unit taking its
## own connections with it when freed is the normal, safe case; this is
## the mirror image of the UnitSelection/DialogueManager leak (a
## persistent listener holding a strong ref INTO a transient object),
## not a repeat of it.

var _signals_connected: bool = false


func _ready() -> void:
	if not OS.is_debug_build():
		return
	CombatManager.combat_started.connect(_on_combat_started)
	CombatManager.turn_started.connect(_on_turn_started)
	CombatManager.combat_ended.connect(_on_combat_ended)
	_signals_connected = true


func _unhandled_input(event: InputEvent) -> void:
	if not OS.is_debug_build():
		return
	if event.is_action_pressed("test_start_combat"):
		_start_test_combat()
	elif event.is_action_pressed("test_end_turn"):
		if CombatManager.in_combat:
			CombatManager.end_turn()
	elif event.is_action_pressed("toggle_area_residency"):
		_toggle_area_residency()
	elif event.is_action_pressed("test_delay_turn"):
		if CombatManager.in_combat:
			var unit: Unit = CombatManager.current_unit
			if unit and not CombatManager.delay_turn(unit):
				print("Couldn't delay ", unit.get_display_name(), "'s turn.")


func _start_test_combat() -> void:
	# The world on screen, not the game. Unscoped, this built one fight
	# out of every unit in every loaded area — which is not a test of
	# anything, and leaves units enrolled in a battle they are nowhere
	# near.
	var context: WorldContext = WorldManager.context()

	var units: Array[Unit] = []
	for unit in UnitQuery.living_units(get_tree()):
		if context and not context.contains(unit):
			continue
		if unit.in_combat():
			print("Combat already in progress here.")
			return
		units.append(unit)

	if units.is_empty():
		print("No units found in the 'units' group — nothing to fight with.")
		return

	_connect_unit_signals(units)
	CombatManager.start_combat(units)


func _connect_unit_signals(units: Array[Unit]) -> void:
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


func _on_combat_ended(winning_faction: StringName) -> void:
	if winning_faction == &"":
		print("--- Combat ended: mutual wipe, no survivors ---")
	else:
		print("--- Combat ended: ", winning_faction, " wins ---")


## Keeps the current area loaded when the player walks out of it, so
## leaving and coming back RE-ENTERS the world they left rather than
## building a fresh one — the same world node, with its dead still lying
## where they fell and anything mid-flight still mid-flight.
##
## Debug-only because residency is normally EARNED: a world stays loaded
## while something is still running in it (see ResidentWorld.is_earned),
## and an idle arena is deliberately not worth keeping — AreaState already
## carries what has to outlive a reload. This is how to see the difference
## without first arranging to leave a fight behind.
func _toggle_area_residency() -> void:
	var area: AreaDefinition = WorldManager.current_area()
	if area == null:
		print("[residency] nothing loaded")
		return

	var pinned: bool = not WorldManager.is_area_pinned(area.id)
	WorldManager.set_area_pinned(area.id, pinned)
	print("[residency] %s is now %s. loaded: %s" % [
		area.id,
		"KEPT when you leave" if pinned else "freed when you leave (unless it earns it)",
		str(WorldManager.resident_area_ids()),
	])
