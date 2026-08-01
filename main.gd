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

var _signals_connected: bool = false


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
				print("Couldn't delay ", unit.name, "'s turn.")


func _start_test_combat() -> void:
	if CombatManager.in_combat:
		print("Combat already in progress.")
		return

	var units: Array[Unit] = []
	for node in get_tree().get_nodes_in_group("units"):
		if node is Unit and node.is_alive():
			units.append(node)

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
		if not unit.attacked.is_connected(_on_unit_attacked):
			unit.attacked.connect(_on_unit_attacked)
		if not unit.died.is_connected(_on_unit_died):
			unit.died.connect(_on_unit_died)


func _on_combat_started(turn_order: Array[Unit]) -> void:
	print("--- Combat started ---")
	for unit in turn_order:
		print("  ", unit.name, " (", unit.faction, ") DX ", unit.dexterity, " HP ", unit.current_hp)


func _on_turn_started(unit: Unit) -> void:
	print("-> ", unit.name, "'s turn (move budget ", unit.move_remaining, ")")
	# Auto-select the acting unit so a right-click moves it and a left-click
	# on an enemy attacks it, without manually clicking it first each turn.
	SelectionManager.select(unit)


func _on_unit_attacked(attacker: Unit, target: Unit, result: Dictionary) -> void:
	if result.already_attacked:
		print("   ", attacker.name, " has already attacked this turn.")
	elif not result.in_reach:
		print("   ", attacker.name, " is out of reach of ", target.name)
	elif not result.to_hit.success:
		print("   ", attacker.name, " misses ", target.name,
				" (rolled ", result.to_hit.roll, " vs ", result.to_hit.target, ")")
	else:
		print("   ", attacker.name, " hits ", target.name, " for ", result.damage,
				" damage (", target.current_hp, " HP left)")


func _on_unit_died(unit: Unit) -> void:
	print("   ", unit.name, " has died.")


func _on_combat_ended(winning_faction: StringName) -> void:
	if winning_faction == &"":
		print("--- Combat ended: mutual wipe, no survivors ---")
	else:
		print("--- Combat ended: ", winning_faction, " wins ---")
