extends AiTestCase
## Perception: can that NPC tell you are there?
##
## Every case drives DetectionManager.scan() directly rather than waiting
## on its timer. A suite that sleeps is a suite nobody runs, and the timer
## is DetectionManager's own concern, not detection's.
##
## Detection is ROLLED, so a single scan proves nothing either way. These
## sweep repeatedly and assert on the outcome across many chances — which
## is also exactly how the mechanic reads in play.


const SWEEPS: int = 40


func run() -> void:
	_sees_what_is_in_front()
	_ignores_what_is_behind()
	# AWAITED, unlike its siblings: this one builds a wall and waits for
	# physics to register it. Calling it bare returns a coroutine and lets
	# the cases below run first, so it resumes into a world where their
	# teardown has already freed its units.
	await _blocked_by_geometry()
	_starts_combat_on_sight()
	_neutral_observer_does_not_attack()
	_obscurity_is_a_real_input()


## An NPC facing an approaching party member, in the open, must notice.
func _sees_what_is_in_front() -> void:
	var watcher: Unit = spawn_unit(&"enemy", 10, 12, 20, [melee()], Vector3.ZERO)
	var intruder: Unit = spawn_unit(&"player", 10, 12, 20, [melee()], Vector3(0.0, 0.0, -6.0))
	watcher.snap_face_point(intruder.global_position)

	check("starts out unaware",
		watcher.awareness().state == UnitAwareness.State.UNAWARE)

	var noticed: bool = _sweep_until_aware(watcher, intruder)
	check("notices someone approaching in plain sight", noticed,
		"still %s after %d sweeps" % [watcher.awareness().state, SWEEPS])
	check("and knows who it noticed", watcher.awareness().subject == intruder)
	free_spawned()


## The reason approaching from behind is worth doing. Same distance, same
## light, same everything — only the facing differs.
func _ignores_what_is_behind() -> void:
	var watcher: Unit = spawn_unit(&"enemy", 10, 12, 20, [melee()], Vector3.ZERO)
	var sneak: Unit = spawn_unit(&"player", 10, 12, 20, [melee()], Vector3(0.0, 0.0, -8.0))
	# Deliberately pointed the opposite way, well outside the cone and well
	# outside proximity_radius.
	watcher.snap_face_point(Vector3(0.0, 0.0, 40.0))

	var noticed: bool = _sweep_until_aware(watcher, sneak)
	check("does NOT notice someone well behind it", not noticed,
		"noticed anyway")
	free_spawned()


## Cover, not just distance, is what breaks a sightline.
func _blocked_by_geometry() -> void:
	var watcher: Unit = spawn_unit(&"enemy", 10, 12, 20, [melee()], Vector3.ZERO)
	var hidden: Unit = spawn_unit(&"player", 10, 12, 20, [melee()], Vector3(0.0, 0.0, -6.0))
	watcher.snap_face_point(hidden.global_position)

	# A wall between them, on the same physics layer the ability system
	# treats as obstruction.
	var wall := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(8.0, 4.0, 0.5)
	shape.shape = box
	wall.add_child(shape)
	_root.add_child(wall)
	wall.global_position = Vector3(0.0, 2.0, -3.0)
	await get_tree().physics_frame
	await get_tree().physics_frame

	var noticed: bool = _sweep_until_aware(watcher, hidden)
	check("does NOT notice through a wall", not noticed, "noticed anyway")

	# Out of the tree NOW, not next frame. queue_free is deferred, so a
	# wall left this way is still solid for the cases that follow — which
	# place their units straight through where it stands and then fail to
	# see each other for reasons that look nothing like the actual cause.
	_root.remove_child(wall)
	wall.queue_free()
	await get_tree().physics_frame
	free_spawned()


## The payoff: being seen starts a fight, through the same entry point
## being attacked uses, with faction escalation intact.
func _starts_combat_on_sight() -> void:
	_ensure_out_of_combat()
	var guard: Unit = spawn_unit(&"enemy", 10, 12, 20, [melee()], Vector3.ZERO)
	var intruder: Unit = spawn_unit(&"player", 10, 12, 20, [melee()], Vector3(0.0, 0.0, -5.0))
	guard.snap_face_point(intruder.global_position)

	check("no combat before anyone is spotted", not CombatManager.in_combat)
	var noticed: bool = _sweep_until_aware(guard, intruder)
	check("spotting a hostile starts combat without a blow being struck",
		noticed and CombatManager.in_combat)
	check("and both are in the turn order",
		CombatManager.turn_order.has(guard) and CombatManager.turn_order.has(intruder))

	CombatManager.end_combat(&"")
	free_spawned()


## A guard looking at you is not a reason for a town to erupt.
func _neutral_observer_does_not_attack() -> void:
	_ensure_out_of_combat()
	var bystander: Unit = spawn_unit(&"neutral", 10, 12, 20, [melee()], Vector3.ZERO)
	var passerby: Unit = spawn_unit(&"player", 10, 12, 20, [melee()], Vector3(0.0, 0.0, -5.0))
	bystander.snap_face_point(passerby.global_position)

	var noticed: bool = _sweep_until_aware(bystander, passerby)
	check("a neutral still notices you", noticed)
	check("but noticing a neutral does not start a fight", not CombatManager.in_combat)

	if CombatManager.in_combat:
		CombatManager.end_combat(&"")
	free_spawned()


## Obscurity is threaded through the arithmetic even though every area
## reports CLEAR — the hook has to be real, not a stub returning a magic
## number, or a light model can't drop into it later.
func _obscurity_is_a_real_input() -> void:
	check("obscurity_at returns a usable modifier, currently CLEAR",
		DetectionManager.obscurity_at(Vector3.ZERO) == UnitAwareness.Obscurity.CLEAR)
	check("and the darker tiers are penalties, not bonuses",
		UnitAwareness.Obscurity.LIGHT < UnitAwareness.Obscurity.CLEAR
			and UnitAwareness.Obscurity.HEAVY < UnitAwareness.Obscurity.LIGHT)


## Detection genuinely starts fights, so a case that asserts on combat
## state has to know it begins from a clean one — otherwise it inherits
## whatever the previous case left running and fails for the wrong reason.
func _ensure_out_of_combat() -> void:
	if CombatManager.in_combat:
		CombatManager.end_combat(&"")


## Sweeps until the observer identifies the subject, or gives up. Returns
## whether it got there.
func _sweep_until_aware(observer: Unit, subject: Unit) -> bool:
	for i in SWEEPS:
		DetectionManager.scan()
		if observer.awareness().is_aware_of(subject):
			return true
	return false
