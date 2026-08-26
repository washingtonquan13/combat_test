extends Node
## Autoload singleton. Register as "SceneManager" under
## Project > Project Settings > AutoLoad.
##
## Owns a stack of scene roots layered under MainRoot's SceneRoot
## container. Index 0 is always the base arena and is never popped.
## push_scene() suspends the current top of stack — hides it, disables
## its processing, but never frees it — and adds a new scene on top;
## pop_scene() frees the top and restores what's under it. Nothing
## pushed DOWN is ever destroyed, only the thing being popped OFF is.
##
## This is deliberately NOT real destroy-and-reload area travel. The
## project has no data-only representation of the player's party today
## (DemonRoster/OwnedDemon is demon-specific) — hiding instead of
## freeing sidesteps that entirely, since nothing ever needs to be
## reconstructed from data. Real area-to-area travel is future work,
## blocked on solving that first.
##
## Does NOT reassign SceneTree.current_scene on push/pop — tried this
## first, and Godot hard-errors ("p_scene->get_parent() != root") the
## instant you assign anything that isn't a DIRECT child of the true
## tree root. TestArena sits under MainRoot/SceneRoot, two levels deep,
## so it can never legally become current_scene while MainRoot is
## run/main_scene. Consequence worth knowing: several existing systems
## (SurfaceManager, unit_vfx.gd, projectile/particle/sound steps,
## ground_click_target.gd) parent transient nodes under
## get_tree().current_scene, which now always means MainRoot — they no
## longer specifically track "whichever arena is active." In practice
## this only matters if something transient is still mid-flight at the
## exact moment of a push (gated to out-of-combat via can_push(), so
## narrow), and the failure mode is cosmetic (an effect keeps playing
## over the pushed scene instead of pausing with its arena), not a
## data/correctness bug. Rewiring those ~8 call sites onto
## current_root() instead is a real, separate follow-up if that gap
## ever actually bites — not done here, out of scope for this pass.

signal scene_pushed(scene_root: Node)
signal scene_popped(scene_root: Node)

var _scene_root: Node3D = null
var _stack: Array[Node] = []


## Called once by MainRoot's own script, after the base arena instanced
## inside MainRoot.tscn has already run its own _ready() chain (children
## finish _ready() before their parent — see camera_director.gd's own
## registration path, which relies on this same ordering). Adopts
## whatever's already parented under root as the floor of the stack.
func register_scene_root(root: Node3D) -> void:
	_scene_root = root
	_stack.clear()
	for child in root.get_children():
		_stack.append(child)


## Whether a push is currently allowed. Reuses CameraDirector's own
## blocker aggregation (combat, dialogue, negotiation, an open context
## menu) rather than re-deriving "is anything else mid-flow" here — see
## that file's own header, which already invites exactly this kind of
## reuse ("adding a future blocker is a one-line addition to this
## function, not a change to every caller").
func can_push() -> bool:
	return not CombatManager.in_combat and CameraDirector.has_control()


## Hides+pauses the current top-of-stack scene and instantiates `scene`
## on top of it. Returns the new node, or null if the push was refused.
func push_scene(scene: PackedScene) -> Node:
	if not can_push():
		push_warning("SceneManager.push_scene refused (in_combat=%s, has_control=%s)" % [CombatManager.in_combat, CameraDirector.has_control()])
		return null

	_suspend(_stack.back())

	var incoming: Node = scene.instantiate()
	_scene_root.add_child(incoming)
	_stack.push_back(incoming)

	scene_pushed.emit(incoming)
	return incoming


## Frees the current top-of-stack scene and restores the one beneath it.
## Refuses to pop the base arena (stack size 1).
func pop_scene() -> void:
	if _stack.size() <= 1:
		push_warning("SceneManager.pop_scene refused: nothing pushed.")
		return

	var outgoing: Node = _stack.pop_back()
	var restored: Node = _stack.back()

	_resume(restored)
	scene_popped.emit(restored)

	outgoing.queue_free()


func current_root() -> Node:
	return _stack.back()


## Order matters: SelectionManager's cleanup calls methods ON the live
## unit nodes (set_selected(false)), so it has to run before anything is
## hidden/disabled, not after.
func _suspend(scene_root: Node) -> void:
	SelectionManager.deselect_all()
	InteractionMenu.close()

	if scene_root.has_method("get_tactical_camera"):
		var cam: Camera3D = scene_root.get_tactical_camera()
		if is_instance_valid(cam):
			CameraDirector.unregister_tactical_camera(cam)

	if scene_root.has_method("_on_scene_suspended"):
		scene_root._on_scene_suspended()

	scene_root.visible = false
	scene_root.process_mode = Node.PROCESS_MODE_DISABLED


func _resume(scene_root: Node) -> void:
	scene_root.visible = true
	scene_root.process_mode = Node.PROCESS_MODE_INHERIT

	# Explicit re-registration, not just relying on _ready() — this node
	# never left the tree (it was only hidden), so _ready() does not
	# refire the way it does for the base arena on first boot. See
	# camera_director.gd's own doc comment on register_tactical_camera().
	if scene_root.has_method("get_tactical_camera"):
		var cam: Camera3D = scene_root.get_tactical_camera()
		if is_instance_valid(cam):
			CameraDirector.register_tactical_camera(cam)
			cam.make_current()

	if scene_root.has_method("_on_scene_resumed"):
		scene_root._on_scene_resumed()
