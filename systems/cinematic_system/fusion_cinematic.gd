class_name FusionCinematic
extends RefCounted
## Builds the fusion cutscene from the two demons going into it and the one
## coming out.
##
## ASSEMBLED, NOT AUTHORED — and the reason is not the obvious one.
##
## The obvious reason, which this file used to give, is that hundreds of
## demon pairs and a computed result mean there is no single .tres to
## write. THAT IS WRONG, and it was tested: the participants vary, the
## SHAPE does not, so an authored file with a varying cast works fine.
## The migration was built, it passed, and it was reverted.
##
## The real reasons it stays here:
##
##   - A .tres cannot carry comments AT ALL — a `##` in one silently breaks
##     loading. The beat notes below (which beats are real, which are held
##     time waiting on shader work) have nowhere to live in that format,
##     and they are the most valuable thing about this file.
##   - It got BIGGER: 166 lines became 200 across two files.
##   - The .tres reads as SubResource ids cross-referencing each other. In
##     the inspector it is navigable; as text it is unreadable.
##
## Authoring suits SIMPLE, STATIC scenes — see test_arena_arrival.tres,
## four steps and perfectly legible as a file. Forcing an intricate,
## parameterised sequence into the same format was false consistency.
##
## WHAT WOULD CHANGE THE ANSWER: a real scene editor, or an actual need to
## re-stage fusion without touching code. Neither exists, and fusion is not
## reached through SceneBinding — it holds its scene directly — so the
## content/presentation split that justifies binding does not apply here.
##
## Fusion is still what broke drafts 1 and 2 of the plan, for a different
## reason: a design fitted to conversation assumes a cast fixed at
## authoring time, and this one creates and destroys actors mid-scene.
##
## The beats follow the reference (see the 2026-08-25 brainstorm), and two
## of them are structure without spectacle yet:
##
##   1  camera tilts up to the device            built
##   2  cut to the top, the pair stand apart     built
##   3  lightning surrounds them                 NEW SHADER WORK
##   4  they dissolve into particles             NEW SHADER WORK (despawn built)
##   5  particles coalesce into a sphere         reusable pack assets
##   6  lightning down, white flash              reusable pack assets
##   7  cut back, the fused demon revealed       built
##   8  it introduces itself                     the CALLER's job, see below
##
## The 2026-08-26 asset audit found beats 3 and 4 need techniques nothing in
## the imported VFX pack provides, so they are line items rather than
## unknowns. The scene holds time for them; the spectacle slots in later
## without the shape changing.
##
## BEAT 8 IS DELIBERATELY NOT HERE. The greeting is a personality-templated
## line, which is a dialogue — and this file must never touch
## DialogueManager, because "the whole sequence plays without DialogueManager
## being touched once" is the acceptance criterion that proves cinematics
## are the spine rather than something dialogue owns. play() returns, the
## camera holds its last framing, and the CALLER starts the greeting.

const LEFT_MARK: StringName = &"FusionLeft"
const RIGHT_MARK: StringName = &"FusionRight"
const RESULT_MARK: StringName = &"FusionResult"
const DEVICE_MARK: StringName = &"FusionDevice"

const PARENT_A: StringName = &"parent_a"
const PARENT_B: StringName = &"parent_b"
const RESULT: StringName = &"result"

## Beat lengths. Fixed for now — a phase whose length comes from its VFX is
## the right answer and is unbuildable until the VFX exists, since two of
## the four effect beats are new shader work. Timing them by hand against
## effects that do not exist would be the same brittleness that makes
## hard-coded timestamps wrong, so these are placeholders and say so.
const ESTABLISH := 1.2
const CHARGE := 1.0
const DISSOLVE := 0.8
const COALESCE := 1.2


## Returns {"scene": CinematicScene, "cast": SceneCast}.
##
## The parents are HELD, not tracked, and that is the whole reason held
## roles exist: DemonRoster.release() consumes them as roster entries when
## the fusion is confirmed, several beats before they leave the screen.
## Asking the roster for them after that returns nothing, so a tracked role
## would blank out mid-cutscene.
static func build(parent_a: Unit, parent_b: Unit, result: UnitDefinition) -> Dictionary:
	var cast := SceneCast.new()
	cast.hold(PARENT_A, parent_a)
	cast.hold(PARENT_B, parent_b)

	var scene := CinematicScene.new()
	scene.id = &"fusion"
	scene.phases = [
		_establishing(),
		_the_pair(),
		_the_charge(),
		_the_dissolve(),
		_the_reveal(result),
	]
	return {"scene": scene, "cast": cast}


## Beat 1. A tilt: the camera holds its position and moves only what it
## looks at, from the platform up to the energies above the device. Only
## expressible because a framing's position source and look target are
## independent — one that could only orbit a subject would have to move the
## camera to change what it sees.
static func _establishing() -> ScenePhase:
	var low := CameraFraming.new()
	low.subject_mark = DEVICE_MARK
	low.distance = 6.0
	low.elevation_degrees = 4.0
	low.look_offset = Vector3.ZERO

	var high := CameraFraming.new()
	high.subject_mark = DEVICE_MARK
	high.distance = 6.0
	high.elevation_degrees = 4.0
	high.look_offset = Vector3(0.0, 4.0, 0.0)

	var open := CameraShotStep.new()
	open.framing = low
	var tilt := CameraShotStep.new()
	tilt.framing = high
	tilt.transit_seconds = ESTABLISH * 0.8
	tilt.offset = ESTABLISH * 0.1

	return _phase(ESTABLISH, [open, tilt])


## Beat 2. Cut to the top of the device, the two of them standing apart.
static func _the_pair() -> ScenePhase:
	var left := PlaceOnMarkStep.new()
	left.role = PARENT_A
	left.mark = LEFT_MARK
	var right := PlaceOnMarkStep.new()
	right.role = PARENT_B
	right.mark = RIGHT_MARK

	var wide := CameraFraming.new()
	wide.subject_mark = DEVICE_MARK
	wide.distance = 4.0
	wide.elevation_degrees = 12.0
	var shot := CameraShotStep.new()
	shot.framing = wide

	return _phase(CHARGE, [left, right, shot])


## Beat 3. Lightning. Nothing but held time until the shader exists.
static func _the_charge() -> ScenePhase:
	return _phase(CHARGE, [])


## Beat 4. They dissolve. The despawn is real; the dissolve is not yet.
static func _the_dissolve() -> ScenePhase:
	var a := DespawnActorStep.new()
	a.role = PARENT_A
	var b := DespawnActorStep.new()
	b.role = PARENT_B
	return _phase(DISSOLVE, [a, b])


## Beats 5-7. The result does not exist until this runs, which is why the
## step both creates it AND holds it — there is no authority to ask for a
## thing that has not been made.
static func _the_reveal(result: UnitDefinition) -> ScenePhase:
	var born := SpawnActorStep.new()
	born.role = RESULT
	born.mark = RESULT_MARK
	born.definition = result
	born.offset = COALESCE * 0.75

	var on_it := CameraFraming.new()
	on_it.subject_role = RESULT
	on_it.distance = 2.2
	on_it.elevation_degrees = 6.0
	var reveal := CameraShotStep.new()
	reveal.framing = on_it
	reveal.offset = COALESCE * 0.75

	return _phase(COALESCE, [born, reveal])


static func _phase(seconds: float, steps: Array[SceneStep]) -> ScenePhase:
	var beat := ScenePhase.new()
	beat.duration_seconds = seconds
	beat.steps = steps
	return beat
