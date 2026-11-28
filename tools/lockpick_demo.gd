extends "res://tools/item_layer_demo.gd"
## Recorded walkthrough of the lockpicking screen — NOT a test. Boots into
## the game, sets a locked chest by the hero, right-clicks it, picks "Pick lock", forces the
## pick in the wrong place until it snaps, turns it part way near the
## spot, then finds the spot and turns the plug. Then a save/load round
## trip of the chest, a fight closing the screen, Force Lock, and a lock
## too hard for the hero.
##
## The pick and the turn are driven through LockpickScreen.drive(), not
## the mouse: where the sweet spot is is random, and the demo needs to
## know it. Set LOCKPICK_SNAPS=<dir> to save stills.

const LockedChestScene: PackedScene = preload("res://systems/lock_system/locked_chest.tscn")



func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	var hero: Unit = PartyManager.leader
	SelectionManager.select(hero)
	# A new game starts in goblin_quarry, so the chest is set down in front
	# of the hero rather than walked to in test_arena.
	var chest: Node3D = LockedChestScene.instantiate()
	WorldManager.spawn_parent().add_child(chest)
	chest.global_position = hero.global_position + Vector3(-2.0, 0.5, 0.0)
	var lock: Lock = Lock.find_on(chest)
	_check("the chest has a lock, locked", lock != null and lock.locked)
	_check("the party starts with lock picks", _count(PartyManager.inventory, Lock.LOCK_PICK) > 0)
	while _count(PartyManager.inventory, Lock.LOCK_PICK) < 3:
		PartyManager.inventory.add(ItemInstance.new(Lock.LOCK_PICK))
	await _wait(1.5)

	_say("Open without the key: it's locked")
	var stash := StashComponent.find_on(chest)
	LootInteraction.new().execute(hero, chest)
	await _wait(0.3)
	_check("Open refuses a locked chest", not StashManager.is_active())

	_say("Right-click the chest: Pick lock")
	var camera: Camera3D = hero.get_viewport().get_camera_3d()
	var aim: Vector2 = camera.unproject_position(chest.global_position)
	await _glide(aim, 0)
	await _click(aim, MOUSE_BUTTON_RIGHT)
	await _wait(1.0)
	_check("the chest's menu offers Pick lock", _pick_menu("Pick lock"))
	var waited := 0.0
	while LockpickScreen.active == null and waited < 8.0:
		await get_tree().process_frame
		waited += get_process_delta_time()
	var screen: LockpickScreen = LockpickScreen.active
	_check("the lockpicking screen is up", screen != null)
	if screen == null:
		_finish()
		return
	_check("GameMode reports LOCKPICKING", GameMode.current_mode() == GameMode.Mode.LOCKPICKING)
	_check("the tactical camera has no control", not CameraDirector.has_control())
	_check("the game camera did not move", hero.get_viewport().get_camera_3d() == camera)
	print("sweet spot %.0f, half width %.0f, pick life %.2f" % [screen.sweet_spot, screen.sweet_half, screen.pick_life])
	_check("the sweet spot is the tier's width (an easy lock: 200 of the 1000)", is_equal_approx(screen.sweet_half * 2.0, LockpickScreen.SWEET_LENGTH[screen.lock.tier]) and screen.lock.tier == Lock.Tier.EASY)
	_check("the spot lies wholly on the arc", screen.sweet_spot - screen.sweet_half >= 0.0
		and screen.sweet_spot + screen.sweet_half <= LockpickScreen.PICK_RANGE)
	await _wait(0.5)
	await _snap("1_open")

	_say("Force it in the wrong place")
	var wrong := fmod(screen.sweet_spot + LockpickScreen.PICK_RANGE * 0.5, LockpickScreen.PICK_RANGE)
	var picks_before := _count(PartyManager.inventory, Lock.LOCK_PICK)
	screen.drive(wrong, false)
	await _wait(0.2)
	screen.drive(wrong, true)
	await _wait(0.3)
	_check("the plug barely turns away from the sweet spot", screen.plug < 5.0)
	_check("it strains the pick", screen.forcing)
	await _snap("2_forcing")
	waited = 0.0
	while _count(PartyManager.inventory, Lock.LOCK_PICK) == picks_before and waited < 5.0:
		await get_tree().process_frame
		waited += get_process_delta_time()
	_check("the pick snaps and one is used up", _count(PartyManager.inventory, Lock.LOCK_PICK) == picks_before - 1)
	_check("the screen stays up while picks remain", LockpickScreen.active == screen)
	screen.drive(wrong, false)
	await _wait(0.8)

	_say("Partway: the plug turns some")
	# Half way through the partial zone past the spot's edge: half a turn.
	var side := 1.0 if screen.sweet_spot < LockpickScreen.PICK_RANGE * 0.5 else -1.0
	var near := screen.sweet_spot + (screen.sweet_half + LockpickScreen.CONCENTRIC * 0.5) * side
	_check("the rule gives half a turn there", is_equal_approx(screen.allowed_turn(near), LockpickScreen.OPEN_ANGLE * 0.5))
	screen.drive(near, false)
	await _wait(0.2)
	screen.drive(near, true)
	await _wait(0.6)
	_check("near the spot the plug turns part way (%.0f deg)" % screen.plug, screen.plug > 10.0 and screen.plug < 80.0)
	await _snap("3_partway")
	screen.drive(near, false)
	await _wait(0.6)
	_check("let go, the plug springs back", screen.plug == 0.0)

	_say("On the spot: it opens")
	screen.drive(screen.sweet_spot, false)
	await _wait(0.2)
	screen.drive(screen.sweet_spot, true)
	await _wait(0.6)
	await _snap("4_opened")
	_check("the lock is open", not lock.locked)
	await _wait(0.8)
	_check("the screen has closed", LockpickScreen.active == null)
	_check("the chest's stash opened on the same press", StashManager.is_active())
	StashManager.close_stash()
	await _wait(0.5)
	_check("GameMode back to EXPLORATION", GameMode.current_mode() == GameMode.Mode.EXPLORATION)

	_say("Save and load: the chest stays unlocked")
	var state: Variant = WorldManager._entity_state(chest)
	print("chest state: ", state)
	_check("both components are saved", state is Dictionary and state.has(WorldManager.COMPONENTS_KEY)
		and state[WorldManager.COMPONENTS_KEY].has("Lock") and state[WorldManager.COMPONENTS_KEY].has("StashComponent"))
	lock.locked = true
	WorldManager._apply_entity_state(chest, state)
	_check("loading puts the lock back open", not lock.locked)
	# A save from before the lock existed: the stash's own state, bare.
	var legacy: Variant = stash.save_state()
	lock.locked = true
	WorldManager._apply_entity_state(chest, legacy)
	_check("an old save still loads into the stash, the lock untouched", lock.locked)
	# A plain chest still saves in the old shape.
	lock.free()
	var plain_state: Variant = WorldManager._entity_state(chest)
	_check("a one-component chest still saves the old shape",
		plain_state is Dictionary and not plain_state.has(WorldManager.COMPONENTS_KEY))

	_say("A fight starts mid-pick: the screen closes")
	var second: Node3D = LockedChestScene.instantiate()
	WorldManager.spawn_parent().add_child(second)
	second.global_position = hero.global_position + Vector3(2.0, 0.5, 0.0)
	_check("the screen opens on a second chest", LockpickScreen.begin(Lock.find_on(second), hero))
	await _wait(0.5)
	var foe: Unit = load("res://systems/unit_system/unit.tscn").instantiate()
	var definition := UnitDefinition.new()
	definition.model_scene = load("res://scenes/character_models/placeholder_model.tscn")
	foe.definition = definition
	WorldManager.spawn_parent().add_child(foe)
	foe.faction = &"enemy"
	foe.global_position = hero.global_position + Vector3(6.0, 0.0, 0.0)
	var fight: Encounter = CombatManager.start_combat([hero, foe] as Array[Unit])
	await _wait(0.5)
	_check("the fight closes the lockpicking screen", LockpickScreen.active == null)
	_check("GameMode reports COMBAT", GameMode.current_mode() == GameMode.Mode.COMBAT)
	if fight:
		CombatManager.end_combat(&"", fight)
	await _wait(0.5)
	foe.queue_free()
	await _wait(0.5)

	_say("Force Lock: one roll, open or jammed")
	var third: Node3D = LockedChestScene.instantiate()
	WorldManager.spawn_parent().add_child(third)
	third.global_position = hero.global_position + Vector3(0.0, 0.5, 2.0)
	var third_lock := Lock.find_on(third)
	_check("the screen opens on a third chest", LockpickScreen.begin(third_lock, hero))
	await _wait(0.5)
	await _snap("5_force_button")
	LockpickScreen.active.force()
	await _wait(0.2)
	print("forced: locked=%s jammed=%s" % [third_lock.locked, third_lock.jammed])
	_check("the force either opened it or jammed it", third_lock.locked == third_lock.jammed)
	await _wait(1.5)
	if StashManager.is_active():
		StashManager.close_stash()
	_check("the screen has closed after the force", LockpickScreen.active == null)
	if third_lock.jammed:
		_check("a jammed lock won't open the screen again", not LockpickScreen.begin(third_lock, hero))
		_check("a jammed lock saves jammed", third_lock.save_state().get("jammed") == true)
	await _wait(0.5)

	_say("A very hard lock: the hero hasn't the skill")
	var fourth: Node3D = LockedChestScene.instantiate()
	WorldManager.spawn_parent().add_child(fourth)
	fourth.global_position = hero.global_position + Vector3(0.0, 0.5, -2.0)
	var hard := Lock.find_on(fourth)
	hard.tier = Lock.Tier.VERY_HARD
	print("hero Lockpicking %d, needs %d" % [Lock.skill_of(hero), hard.required_skill()])
	_check("the hero may not try it", not hard.can_pick(hero))
	PickLockInteraction.new().execute(hero, fourth)
	await _wait(0.3)
	_check("Pick lock refuses it without opening the screen", LockpickScreen.active == null)
	_finish()


func _finish() -> void:
	print("DEMO RESULT: %d/%d passed" % [_passed, _passed + _failed.size()])
	for what in _failed:
		print("  failed: ", what)
	get_tree().quit()


func _pick_menu(label: String) -> bool:
	var popup: PopupMenu = InteractionMenu._popup
	if not popup.visible:
		return false
	for i in popup.item_count:
		if popup.get_item_text(i) == label:
			popup.hide()
			InteractionMenu._on_id_pressed(popup.get_item_id(i))
			return true
	return false


func _snap(tag: String) -> void:
	var out := OS.get_environment("LOCKPICK_SNAPS")
	if out.is_empty():
		return
	_caption.visible = false
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var path := out.path_join("lockpick_%s.png" % tag)
	get_viewport().get_texture().get_image().save_png(path)
	print("saved ", path)
	_caption.visible = true
