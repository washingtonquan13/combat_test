extends Node
## Autoload singleton. Register as "CinematicDirector" under
## Project > Project Settings > AutoLoad — and BEFORE GameMode, which asks
## this one whether a cutscene is running.
##
## THE SPINE, not a service dialogue owns. Anything can ask for a staged
## moment: a dialogue node, a menu confirming a fusion, a first entry to an
## area, a combat start. Dialogue is one caller among those and holds no
## special standing — BG3 makes dialogue the trunk because BG3 is a
## conversation game, and this one is not. Most of the fusion cutscene has
## nobody talking.
##
## It follows that this file must never reference DialogueManager.
##
## A CUTSCENE IS A .tscn. There is no resource wrapping it: the stage scene
## (root CinematicStage) is the whole authored thing, and play() takes the
## PackedScene directly. A wrapper that only named a scene and an
## animation was a second file per cutscene that could disagree with the
## first, so the animation name became an argument instead.
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
## for emitting — not animation_finished (a stopped player never emits it),
## and not the player pressing a key. Input is read in _input into two
## flags and the loop POLLS them, which is how a scene can wait on the
## player without the director waiting on anyone.
##
## SKIP IS NOT ABORT. A skipped scene still happened: whatever it would
## have spawned is spawned, whoever it would have removed is gone, and the
## camera lands on the authored last frame. Only the time is skipped — see
## CinematicStage.skip_to_end(). An abort is the other thing: the world is
## going away, or a caller cancelled, and play() returns false.

## Emitted for observers — a debug overlay, a test sampling the mode. NOT
## a control-flow channel: nothing awaits these, and play() does not care
## whether anything is connected.
signal scene_started(stage: PackedScene)
signal scene_finished(stage: PackedScene, completed: bool)

## The scene on screen, or null. The single answer to "is a cutscene
## running" — GameMode reads it and nothing mirrors it.
var _running: PackedScene = null
## The mounted stage while one is on screen. Also what _input asks before
## eating a key: with no stage there is nothing to skip or advance.
var _stage: CinematicStage = null
## Bumped by a cancel. A play() whose generation no longer matches knows it
## has been cancelled without needing a flag of its own to clear.
var _generation: int = 0
## Whether a cancelled scene is settled to its end state before it is
## freed — see abort() and _on_world_loading().
var _settle_on_cancel: bool = true
## Set by _input, consumed by the play loop. Flags rather than signals so
## the loop's only await stays process_frame.
var _skip_requested: bool = false
var _advance_requested: bool = false
## The scene-layer camera and the letterbox/subtitle overlay, both handed
## over at boot — knowing MainRoot's own layout is MainRoot's job. Null in
## a headless harness, and every caller checks.
var _camera: CinematicCamera = null
var _overlay: CinematicOverlay = null


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


func register_overlay(overlay: CinematicOverlay) -> void:
	_overlay = overlay


func overlay() -> CinematicOverlay:
	return _overlay if is_instance_valid(_overlay) else null


func is_active() -> bool:
	return _running != null


func current_scene() -> PackedScene:
	return _running


## The mounted stage, or null. What a beat or a test reaches for when it
## needs the running performance rather than the file it came from.
func current_stage() -> CinematicStage:
	return _stage if is_instance_valid(_stage) else null


## Runs `stage` (a .tscn whose root is a CinematicStage) and returns whether
## it finished — false if it was aborted, refused, or had nothing to play.
## A skipped scene FINISHED: skip is a way of finishing.
##
## ALWAYS RETURNS. That is the contract the caller depends on, and it is
## why there is no signal to await and no path that can leave a caller
## suspended forever.
##
## `props` is merged into the mounted stage's own props, and is how a
## caller hands the scene a runtime value it computed — fusion's result
## demon. Merged rather than assigned, so a stage's authored props survive
## a caller that only means to add one; the caller wins on a collision.
##
## `animation` names which animation on the stage's Timeline is the
## performance, so one stage can hold variants of a moment.
func play(stage: PackedScene, cast: SceneCast = null, props: Dictionary = {},
		animation: StringName = &"scene") -> bool:
	if stage == null:
		return false
	if _running != null:
		push_warning("CinematicDirector.play refused: '%s' is already running."
			% _running.resource_path)
		return false

	_running = stage
	_generation += 1
	var mine: int = _generation
	_settle_on_cancel = true
	_skip_requested = false
	_advance_requested = false
	var players: SceneCast = cast if cast != null else SceneCast.new()
	players.tree = get_tree()
	scene_started.emit(stage)

	var mounted: CinematicStage = _mount(stage, players, props)
	_stage = mounted
	if mounted and overlay():
		overlay().enter()
	await _run_timeline(mounted, animation, mine)

	var completed: bool = mine == _generation
	# Before anything else, and on EVERY exit including an abort: an actor
	# left claimed is a unit that no longer reacts to being hit, forever.
	# The stage has already unbound by here, so nothing is still writing to
	# an actor that is about to be handed back.
	players.release_claims()
	if is_instance_valid(mounted):
		mounted.queue_free()
	_stage = null
	if mounted and overlay():
		overlay().leave()
	_running = null
	scene_finished.emit(stage, completed)
	return completed


## Cancels whatever is playing, and SETTLES it: bodies the scene would have
## spawned or removed end up as its end state says, so a caller cancelling
## a fusion does not leave two parents standing in the world with nobody
## holding them. Safe to call when nothing is playing.
##
## Does not clear _running itself — the play() call that owns it unwinds on
## its next frame and clears it there, so there is exactly one writer.
func abort() -> void:
	_cancel(true)


func _cancel(settle: bool) -> void:
	if _running == null:
		return
	_settle_on_cancel = settle
	_generation += 1


## Reads the two cutscene keys while a stage is on screen, and swallows
## them so Escape does not also open the esc menu and a click does not also
## order a unit across the room. _input rather than _unhandled_input for
## exactly that reason: it runs before the GUI and before UIStack's own
## Escape handling.
func _input(event: InputEvent) -> void:
	if current_stage() == null:
		return
	if event.is_action_pressed(&"cinematic_skip"):
		_skip_requested = true
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"cinematic_advance"):
		_advance_requested = true
		get_viewport().set_input_as_handled()


## Puts an authored stage into the world and points it at the cast.
##
## Under WorldManager.spawn_parent(), the same place every runtime spawn
## goes — a Node3D only renders in the World3D of the viewport above it, so
## a stage parented anywhere else would be staging a scene nobody can see.
func _mount(scene: PackedScene, cast: SceneCast, props: Dictionary) -> CinematicStage:
	var parent: Node = WorldManager.spawn_parent()
	if parent == null:
		push_warning("CinematicDirector: nowhere to put '%s' — no world." % scene.resource_path)
		return null
	var built: Node = scene.instantiate()
	var stage := built as CinematicStage
	if stage == null:
		push_warning("CinematicDirector: '%s' root is %s, not a CinematicStage."
			% [scene.resource_path, built.get_class()])
		built.free()
		return null
	# BEFORE add_child, and before bind: _ready and bind() are both entitled
	# to read props, and a stage that is handed them afterwards is a stage
	# that was briefly wrong about what it holds.
	#
	# A COPY, never a merge in place. A Dictionary exported on a .tscn is
	# not duplicated per instantiate() at runtime, so merging into it writes
	# through to the PackedScene itself — every later play of the same stage
	# would inherit the last caller's props.
	var stocked: Dictionary = stage.props.duplicate()
	stocked.merge(props, true)
	stage.props = stocked
	parent.add_child(stage)
	stage.bind(cast)
	return stage


## Runs the stage's timeline to its end, or until this play is cancelled.
##
## POLLED, NEVER AWAITED ON animation_finished — see the header. The loop
## asks the STAGE whether it is still running rather than the player, so a
## timeline paused for input (CinematicStage.wait_for_advance) counts as
## running, not finished.
##
## A missing animation is a finished one. There is nothing to hold the
## screen for, and refusing to return would be worse than playing nothing.
func _run_timeline(stage: CinematicStage, animation: StringName, mine: int) -> void:
	if stage == null:
		return
	var timeline: AnimationPlayer = stage.timeline()
	if timeline == null or not timeline.has_animation(animation):
		push_warning("CinematicDirector: '%s' has no animation '%s' on a 'Timeline' player."
			% [stage.scene_file_path, animation])
		stage.unbind()
		return

	timeline.play(animation)
	while mine == _generation:
		# The stage lives in the world, and a world is freed a frame after
		# it announces it is going (or, on a path that never announces,
		# with no warning at all). A call on a freed stage is a script
		# error, and a script error here strands the caller forever — the
		# one thing play() promises cannot happen. So a stage that vanished
		# is an abort, with nothing left to settle.
		if not is_instance_valid(stage):
			_cancel(false)
			break
		if _skip_requested:
			_skip_requested = false
			stage.skip_to_end()
			break
		# Consumed every frame whether or not anything is waiting, so a
		# click made mid-shot is not banked and spent on the next pause.
		var advance: bool = _advance_requested
		_advance_requested = false
		if stage.is_waiting():
			if advance:
				stage.advance()
		elif not stage.is_running():
			break
		_show_prompt(stage.is_waiting())
		await get_tree().process_frame

	_show_prompt(false)
	var standing: bool = is_instance_valid(stage)
	if mine != _generation:
		# Settled first, so a cancelled scene leaves the world in its end
		# state — unless the world itself is what is going away, in which
		# case everything the scene touched goes with it and there is
		# nothing to settle.
		if standing and _settle_on_cancel and stage.is_inside_tree():
			stage.skip_to_end()
		if is_instance_valid(timeline):
			timeline.stop()
		# The screen goes back ONLY on a cancel. A scene that finished (or
		# was skipped to its end) left the camera on an authored final
		# framing, and holding that is what lets a caller start a greeting
		# over the last shot — see the fusion scene.
		var showing: CinematicCamera = camera()
		if showing:
			showing.release()
	if standing:
		stage.unbind()


func _show_prompt(waiting: bool) -> void:
	var screen: CinematicOverlay = overlay()
	if screen:
		screen.show_prompt(waiting)


func _on_world_loading(_scene: PackedScene) -> void:
	_cancel(false)
