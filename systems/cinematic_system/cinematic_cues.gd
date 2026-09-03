class_name CinematicCues
extends Node
## Notices the moments an area wants staged, and asks the director for
## them: arriving somewhere for the first time, and a fight beginning.
##
## PHASE 3, AND ITS OWN ACCEPTANCE TEST. The question this phase exists to
## answer is whether a NEW caller costs anything — whether the vocabulary
## was quietly fitted to fusion, the one scene it was built against. Both
## callers here are a few lines and neither needed anything new: an
## establishing shot and a fight's opening are camera work, and the arrival
## scene is now an authored timeline that keys a FramingRig, which is what
## every scene with a shape is. If a third caller had needed its own
## machinery, that would have been the finding.
##
## A presentation listener, in the same family as DialogueStaging and
## DialogueGaze: it reads signals and never gets called back into. One node
## for both cues rather than one each, because they are the same job —
## look at what the area declared, and play it.
##
## WHO RELEASES THE CAMERA. These callers do, once their scene finishes:
## an establishing shot ends and hands control back. Fusion deliberately
## does NOT, because its reveal has to hold while the demon introduces
## itself. That difference is the reason releasing is a caller's decision
## rather than something baked into play() — and if a third caller ever
## wants to release PART WAY through a scene, that is when a step for it
## earns its place. Nothing does yet.

## Flags are namespaced so a save's flag list stays readable, and so
## clearing every intro is one prefix query away.
const ENTRY_FLAG_PREFIX: String = "cinematic.entered."

const LEADER_ROLE: StringName = &"leader"
const ENEMY_ROLE: StringName = &"enemy"


func _ready() -> void:
	WorldManager.world_loaded.connect(_on_world_loaded)
	WorldManager.world_focused.connect(_on_world_focused)
	CombatManager.combat_started.connect(_on_combat_started)


## Arriving somewhere. Hooked to BOTH signals on purpose: world_loaded
## fires only when a world is newly built, and a world kept resident is
## re-entered through world_focused instead — a first visit can be either,
## depending on whether the player has been somewhere else since.
##
## The flag is what makes that safe. Whichever signal gets there first, the
## second finds the flag already set and does nothing.
func _on_world_loaded(world: Node, _reason: WorldManager.Entry) -> void:
	_maybe_introduce(world)


func _on_world_focused(world: Node) -> void:
	_maybe_introduce(world)


func _maybe_introduce(world: Node) -> void:
	if not (world is GameArea):
		return
	var area: AreaDefinition = WorldManager.area_of(world)
	if area == null:
		return
	var scene: CinematicScene = (world as GameArea).entry_scene
	if scene == null:
		return

	var flag: String = ENTRY_FLAG_PREFIX + String(area.id)
	if FlagManager.has_flag(flag):
		return
	# Set BEFORE playing, not after. A scene aborted half way through — a
	# load from the menu, a world torn down — must not leave the area
	# looking unvisited, or the establishing shot replays every time the
	# player passes through.
	FlagManager.set_flag(flag)
	await _play(scene, _cast_for_arrival())


## A fight beginning. Nothing by default: most fights should simply start,
## and an area that wants otherwise says so.
func _on_combat_started(turn_order: Array[Unit]) -> void:
	var world: Node = WorldManager.current_world()
	if not (world is GameArea):
		return
	var scene: CinematicScene = (world as GameArea).combat_intro_scene
	if scene == null:
		return
	await _play(scene, _cast_for_combat(turn_order))


## Plays, then hands the camera back — see the header on why that is here
## rather than in the director.
func _play(scene: CinematicScene, cast: SceneCast) -> void:
	if not await CinematicDirector.play(scene, cast):
		# REFUSED, OR CUT SHORT — release nothing. Something else owns the
		# screen, and the obvious case is fusion, whose reveal deliberately
		# holds after its scene ends so the demon can introduce itself.
		# Releasing on a refusal would yank that shot away, and the caller
		# doing the yanking would be one that never got to play at all.
		return
	var camera: CinematicCamera = CinematicDirector.camera()
	if camera:
		camera.release()


func _cast_for_arrival() -> SceneCast:
	return SceneCast.new().track(LEADER_ROLE, _leader)


func _cast_for_combat(turn_order: Array[Unit]) -> SceneCast:
	var opponent: Unit = null
	for unit in turn_order:
		if is_instance_valid(unit) and not unit.is_player_controlled():
			opponent = unit
			break
	var cast := SceneCast.new().track(LEADER_ROLE, _leader)
	# Tracked through a captured local rather than held: the fight owns
	# these units and the scene is only looking at them, so if one dies
	# mid-shot the role should go quiet rather than keep a corpse on camera.
	cast.track(ENEMY_ROLE, func() -> Unit:
		return opponent if is_instance_valid(opponent) else null)
	return cast


func _leader() -> Unit:
	var leader: Unit = PartyManager.leader
	return leader if is_instance_valid(leader) else null
