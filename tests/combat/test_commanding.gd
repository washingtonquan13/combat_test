extends AiTestCase
## Who the player is commanding, and what that unit is allowed to do.
##
## There used to be two answers to that question — SelectionManager out of
## combat, CombatManager.current_unit in it, switched on a global
## in_combat flag. A global flag cannot mean anything sensible once several
## fights can run in several worlds, and the visible cost was that
## selecting a party member standing outside a battle did nothing at all:
## their abilities, their indicators and their targeting silently belonged
## to whoever was taking a turn somewhere else.
##
## The other half is that "something in flight" and "cannot be given an
## order" were the same predicate, so a walking unit refused every click
## until it arrived.

var _fighter: Unit
var _bystander: Unit
var _enemy: Unit
var _fight: Encounter = null
var _saved_factions: Array = []


func run() -> void:
	# Turns advance only when this suite says so.
	_saved_factions = CombatAi.ai_factions.duplicate()
	CombatAi.ai_factions = []

	await _build_a_fight_and_a_bystander()
	if _fight == null:
		check("SETUP: a fight with a bystander outside it", false)
		_restore()
		return

	_a_bystander_is_commandable_during_a_battle()
	_the_commanded_unit_is_the_selected_one()
	await _acting_out_of_turn_is_refused()
	await _a_move_order_replaces_the_one_in_flight()

	_restore()


## A fight between one party member and an enemy, plus a second party
## member deliberately left out of it.
func _build_a_fight_and_a_bystander() -> void:
	_fighter = spawn_brute(0.0)
	_bystander = spawn_brute(8.0)
	_enemy = spawn_unit(&"enemy", 12, 12, 20, [melee()], Vector3(2.0, 0.0, 0.0))
	PartyManager.add_member(_fighter)
	PartyManager.add_member(_bystander)
	await get_tree().physics_frame

	var combatants: Array[Unit] = [_fighter, _enemy]
	_fight = CombatManager.start_combat(combatants)
	await get_tree().process_frame

	# Walk the order round to the party member, so "their turn" is the
	# state under test rather than an accident of initiative.
	var guard: int = 0
	while _fight.is_running and _fight.current_unit != _fighter and guard < 6:
		CombatManager.end_turn(_fight.current_unit)
		await get_tree().process_frame
		guard += 1

	check("SETUP: the fight is on the party member's turn",
		_fight.is_running and _fight.current_unit == _fighter)
	check("SETUP: the bystander is outside the fight",
		not _bystander.in_combat())


## THE complaint. A member standing outside a battle was unreachable while
## it ran — not because anything refused them, but because nothing was
## asking about them.
func _a_bystander_is_commandable_during_a_battle() -> void:
	check("a party member outside the fight can be commanded while it rages",
		_bystander.is_commandable(),
		"still frozen by a battle they are not in")
	check("and the one whose turn it is can be commanded too",
		_fighter.is_commandable())
	check("but the enemy never can, whatever is happening",
		not _enemy.is_commandable())


## Selecting somebody has to mean something.
func _the_commanded_unit_is_the_selected_one() -> void:
	SelectionManager.select(_bystander)
	check("selecting the bystander makes THEM the commanded unit",
		PlayerInteractionState.get_active_unit() == _bystander,
		"the fight kept the controls")

	SelectionManager.select(_fighter)
	check("and selecting the combatant hands the controls back",
		PlayerInteractionState.get_active_unit() == _fighter)


## Following the selection is only safe because this exists: before, being
## out of turn was enforced by the hotbar simply never showing anyone
## else's abilities, and use_ability itself never checked whose turn it
## was at all.
func _acting_out_of_turn_is_refused() -> void:
	var ability: Ability = _fighter.default_ability()
	if ability == null:
		check("SETUP: an ability to try", false)
		return

	# Hand the turn to the enemy so the party member is in a fight and off
	# their turn — the exact state the gate exists for.
	CombatManager.end_turn(_fighter)
	# Turn advance is deferred, so it is not done until a frame passes.
	await get_tree().process_frame
	check("SETUP: it is no longer the party member's turn",
		not _fighter.is_my_turn())

	var result: Dictionary = await _fighter.use_ability(ability, _enemy)
	check("a unit in a fight cannot act off its own turn",
		result.busy and not result.hit,
		"acted out of turn")

	check("and it is not commandable while it is not their turn either",
		not _fighter.is_commandable())

	# The bystander is in no fight, so no turn binds them.
	var bystander_ability: Ability = _bystander.default_ability()
	if bystander_ability:
		var free_result: Dictionary = await _bystander.use_ability(bystander_ability, _enemy)
		check("while a unit outside the fight is bound by no turn at all",
			not free_result.busy,
			"a battle they are not in refused their action")


## The other complaint: a walking unit refused every click until it
## arrived, because "in flight" and "cannot be ordered" were one predicate.
func _a_move_order_replaces_the_one_in_flight() -> void:
	var walker: Unit = _bystander
	var start: Vector3 = walker.global_position

	var first: bool = walker.move_to(start + Vector3(12.0, 0.0, 0.0))
	check("SETUP: the first order is accepted", first)
	await get_tree().physics_frame
	await get_tree().physics_frame
	check("SETUP: they are actually walking", walker.is_moving())

	# The whole point: say something else, mid-stride.
	var second: bool = walker.move_to(start + Vector3(0.0, 0.0, 12.0))
	check("a second order mid-walk is accepted, not dropped",
		second, "the click was refused and silently discarded")

	check("and a walking unit is still commandable",
		walker.can_be_commanded())
	check("while an ability mid-walk is still refused",
		not walker.can_act(),
		"can_act stopped counting movement, which ability use relies on")


func _restore() -> void:
	if is_instance_valid(_fight) and _fight.is_running:
		_fight.finish(&"")
	for unit in [_fighter, _bystander]:
		if is_instance_valid(unit) and PartyManager.is_member(unit):
			PartyManager.remove_member(unit)
	SelectionManager.deselect_all()
	CombatAi.ai_factions = _saved_factions
