extends Node
## Autoload singleton. Register as "CinematicDirector" under
## Project > Project Settings > AutoLoad — and BEFORE GameMode, which asks
## this one whether a cutscene is running.
##
## THE SPINE, not a service dialogue owns. Anything can ask for a staged
## moment: a dialogue node, a menu confirming a fusion, a first entry to an
## area, a combat start. Dialogue is one caller among those and holds no
## special standing, which is the whole correction that produced draft 3 of
## the plan — BG3 makes dialogue the trunk because BG3 is a conversation
## game, and this one is not. Seven of the fusion cutscene's eight beats
## have nobody talking.
##
## It follows that this file must never reference DialogueManager, and the
## acceptance test for phase 0 is deliberately "a caller with NO dialogue
## involvement requests a scene."
##
## AN AWAITED CALL, NOT A SIGNAL PAIR. The obvious shape here is
## scene_requested/scene_finished, mirroring DialogueManager's dice-roll
## pair — and that pair can hang: skill_check_choice.gd awaits
## dice_roll_finished, exactly one thing anywhere emits it, and there is no
## timeout. A cutscene is far more interruptible than a dice roll (a world
## unload, a load from the menu, an actor dying), so the same shape here
## would be a hang waiting to happen. play() is a call that RETURNS, so an
## abort is a return value rather than a signal that never arrives.
##
## THE INVARIANT THAT MAKES THAT TRUE: every await inside play() is on
## get_tree().process_frame, which always fires while the tree is alive.
## Nothing in here ever awaits a signal that another object is responsible
## for emitting. Phase 1 adds steps, and each of them inherits that rule.

## Emitted for observers — a debug overlay, a test sampling the mode. NOT
## a control-flow channel: nothing awaits these, and play() does not care
## whether anything is connected.
signal scene_started(scene: CinematicScene)
signal scene_finished(scene: CinematicScene, completed: bool)

## The scene on screen, or null. The single answer to "is a cutscene
## running" — GameMode reads it and nothing mirrors it.
var _running: CinematicScene = null
## Bumped by abort(). A play() whose generation no longer matches knows it
## has been cancelled without needing a flag of its own to clear.
var _generation: int = 0
## The scene-layer camera, handed over by main_root.gd — the same
## registration pattern WorldManager uses for its scene root and world
## host, and for the same reason: knowing MainRoot's own layout is
## MainRoot's job. Null until boot finishes, and every caller checks.
var _camera: CinematicCamera = null


func _ready() -> void:
	# A cutscene cannot survive the world it was staged in. Travel is
	# already refused while one runs (GameMode.can_transition is false),
	# but a save being loaded rebuilds areas without asking the mode, so
	# this is the path that actually needs covering.
	WorldManager.world_loading.connect(_on_world_loading)


func register_camera(camera: CinematicCamera) -> void:
	_camera = camera


func camera() -> CinematicCamera:
	return _camera if is_instance_valid(_camera) else null


func is_active() -> bool:
	return _running != null


func current_scene() -> CinematicScene:
	return _running


## Runs `scene` to completion and returns whether it finished — false if it
## was aborted, refused, or there was nothing to play.
##
## ALWAYS RETURNS. That is the contract the caller depends on, and it is
## why there is no signal to await and no path that can leave a caller
## suspended forever.
func play(scene: CinematicScene, cast: SceneCast = null) -> bool:
	if scene == null:
		return false
	if _running != null:
		push_warning("CinematicDirector.play refused: '%s' is already running." % _running.id)
		return false

	_running = scene
	_generation += 1
	var mine: int = _generation
	var players: SceneCast = cast if cast != null else SceneCast.new()
	players.tree = get_tree()
	scene_started.emit(scene)

	for phase in scene.phases:
		if mine != _generation:
			break
		if phase != null:
			await _run_phase(phase, players, mine)

	var completed: bool = mine == _generation
	# Before anything else, and on EVERY exit including an abort: an actor
	# left claimed is a unit that no longer reacts to being hit, forever.
	players.release_claims()
	_running = null
	scene_finished.emit(scene, completed)
	return completed


## Cancels whatever is playing. Safe to call when nothing is.
##
## Does not clear _running itself — the play() call that owns it unwinds on
## its next frame and clears it there, so there is exactly one writer.
func abort() -> void:
	if _running == null:
		return
	_generation += 1


## Fires a phase's steps at their offsets, then holds for the rest of its
## duration.
##
## A ZERO-DURATION PHASE NEVER AWAITS. It fires its offset-zero steps and
## returns in the same call, so a caller staging a single cut — which is
## what every line of dialogue does — completes synchronously and the mode
## never reports CUTSCENE for it. That is what lets a conversation use this
## path rather than a bypass around it.
##
## Awaits process_frame rather than a SceneTreeTimer so a cancelled phase
## ends on the next frame instead of running to its full length, and so the
## only thing awaited is something the tree always emits.
func _run_phase(phase: ScenePhase, cast: SceneCast, mine: int) -> void:
	var fired: Array[bool] = []
	fired.resize(phase.steps.size())
	var elapsed: float = 0.0
	while true:
		for i in phase.steps.size():
			var step: SceneStep = phase.steps[i]
			if step != null and not fired[i] and elapsed >= step.offset:
				fired[i] = true
				step.apply(cast)
		if elapsed >= phase.duration_seconds or mine != _generation:
			return
		await get_tree().process_frame
		elapsed += get_process_delta_time()


func _on_world_loading(_scene: PackedScene) -> void:
	abort()
