class_name CharacterModel
extends Node3D
## A creature's whole physical presence, authored as one scene.
##
## The Unit is the ACTOR — stats, skills, abilities, AI, turn state. This
## is the BODY: the mesh it wears, the skeleton under it, the library it
## animates from, the silhouette it outlines with, the ring at its feet,
## and the points on it other systems need to aim at.
##
## The test for whether something belongs here is simple: **would it be
## wrong for a different creature?** The outline mesh is skinned to one
## specific skeleton, so it belongs here. Clip names are facts about one
## animation library, so they belong here. UnitAnimator's sequencing —
## phases, interruption, advance — is identical for every creature, so it
## stays on the Unit and merely reads what it is given.
##
## Nothing gameplay-facing goes in here. No stats, no abilities, no AI, no
## state a rule would read. If a field would ever be consulted by a rule
## rather than by a renderer, it belongs on UnitDefinition or Unit. "All
## the visuals" is exactly the kind of scope that grows into a god-scene,
## and the line has to be held deliberately.
##
## WHY A SCENE AND NOT COMPUTED. An earlier design built the body from
## numbers at spawn — a capsule sized from radius and height. That cannot
## express a creature that is not capsule-shaped, and it cannot be checked
## by eye. Authoring it means opening the scene and looking at it, which
## is the only way to know a body is right.
##
## This is also how the reference games do it. A BG3 character carries a
## single CharacterVisualResourceID pointing at a bundle that owns the
## meshes and the skeleton, with animation bound through that skeleton
## rather than through the character — and its BOUNDS live with the visual
## too, which is the argument for size ending up here in a later pass.
##
## Adopted by Unit._enter_tree() when a UnitDefinition names one. Units
## whose definition names nothing keep whatever body their scene was
## authored with, so nothing changes until a definition opts in.

## The library this body animates from. May legitimately hold no clips at
## all — a whitebox body is exactly that — which UnitAnimator now handles
## rather than stalling on (see its _advance_to_next_phase).
@export var animation_player: AnimationPlayer

@export_group("Clip Names")
## Empty means "this body has no such clip", which is a supported answer
## and not a mistake: it plays nothing and the sequence moves on. Only a
## name that is given and cannot be found is worth a warning.
@export var idle_animation: String = ""
@export var walk_animation: String = ""
@export var hit_animation: String = ""
@export var death_animation: String = ""

@export_group("Armed Animation")
@export var armed_enter_animation: String = ""
@export var armed_hold_animation: String = ""

@export_group("Presentation")
## The silhouette drawn behind the body when hovered or selected. Skinned
## to THIS body's skeleton, which is the whole reason it cannot live on
## the Unit: an outline is a second copy of one specific mesh on one
## specific rig.
@export var outline_mesh: MeshInstance3D
## The flat ring at the feet. Belongs to the body because it has to match
## the body's footprint.
@export var highlight_mesh: MeshInstance3D

@export_group("Extent")
## What the NAVIGATION grid is told this body is. The C++ reads radius and
## avoidance_margin off the Unit by duck-typing and sweeps clearance across
## every Y-layer `height` spans, so these three numbers are the whole of
## what makes a dragon path like a dragon:
##
##     clearance      = radius + avoidance_margin
##     vertical_cells = ceil(height / CELL_SIZE)
##
## They live on the BODY, beside the shape they approximate, so they can be
## checked by eye against it rather than guessed in a resource file. That
## is also where BG3 keeps them — Bounds Min/Max sit in the VisualBank, not
## in the character's stats.
##
## DEFAULTS REPRODUCE THE PROJECT'S EXISTING NUMBERS, and avoidance_margin
## is the one to be careful with: unit.gd declares 0.15, but unit.tscn has
## always overridden it to 0.25, so 0.25 is what every unit has actually
## been navigating with. A body declaring the script default would quietly
## re-tune the movement of all 32 demons.
@export var radius: float = 0.25
@export var avoidance_margin: float = 0.25
@export var height: float = 2.0

## The body's PHYSICAL shape, authored here and copied onto the Unit's own
## direct-child CollisionShape3D at spawn.
##
## It cannot do the collision from in here, and that is not a workaround —
## Godot ignores nested shapes outright: "Indirect child nodes will be
## ignored and won't be used as collision shapes." Silently, with no error.
## So this node is a TEMPLATE. It exists in the model scene because that is
## the only place it can be positioned against the mesh by eye, which is
## the entire argument for authoring a body instead of computing one.
##
## The editor will show a configuration warning on it for not being under a
## CollisionObject3D. That warning is correct and expected; the node is
## deliberately inert here.
##
## Null is allowed: a body that declares no shape leaves the Unit's own
## authored one alone.
@export var collision_shape: CollisionShape3D

## Named points on this body that other systems aim at.
##
## Before this there was one, found by string search from a single caller,
## with everything else guessing from a constant. Eye height in particular
## was declared in FIVE places — LineOfSight's default parameter,
## AreaTargeting's own export, DetectionManager's constant, and two
## indicator offsets, one of which carries a comment explaining that it has
## to match the first. All of them said 1.5, for every creature.
##
## A dragon does not see from 1.5 m, and no formula gets a dragon and a
## pixie right at once. Naming the points and letting the body place them
## is the only thing that does.
enum Anchor { HEAD, EYE, CHEST, GROUND }

@export_group("Anchors")
## Where a camera frames the face, and where floating UI belongs.
@export var head_anchor: Node3D
## Where this body SEES from, and where its shots originate.
@export var eye_anchor: Node3D
## Centre of mass — targeting, impacts, body-centred effects.
@export var chest_anchor: Node3D
## The feet. Selection rings, decals, anything that sits on the floor.
@export var ground_anchor: Node3D


## The AnimationPlayer to drive, falling back to a search when the export
## is unset.
##
## The fallback exists because the common case is a model built around an
## imported .glb, which brings its own AnimationPlayer at a path the
## author did not choose. Requiring the reference to be wired by hand
## would make every new body a two-step job for no benefit.
func resolve_animation_player() -> AnimationPlayer:
	if is_instance_valid(animation_player):
		return animation_player
	return _find_animation_player(self)


func _find_animation_player(node: Node) -> AnimationPlayer:
	for child in node.get_children():
		if child is AnimationPlayer:
			return child
		var deeper: AnimationPlayer = _find_animation_player(child)
		if deeper:
			return deeper
	return null


## A named point on this body, in world space.
##
## Falls back to a proportion of `height` when the body has not declared
## one, and THOSE PROPORTIONS ARE NOT ARBITRARY: at the project's standing
## height of 2.0 they reproduce the exact constants the game already used —
## 1.7 for the face (the old FaceAnchor, and the old `height * 0.85`), and
## 1.5 for the eye (LineOfSight's long-standing default). A body that
## declares nothing therefore behaves precisely as it did.
##
## The fallback is a floor, not the plan. It is right for a humanoid and
## wrong for anything else, which is the whole reason a body gets to
## overrule it by placing a node where the point actually is.
func anchor_position(kind: Anchor) -> Vector3:
	var declared: Node3D = _declared(kind)
	if is_instance_valid(declared):
		return declared.global_position
	return global_position + Vector3(0.0, height * _fallback_ratio(kind), 0.0)


func _declared(kind: Anchor) -> Node3D:
	match kind:
		Anchor.HEAD: return head_anchor
		Anchor.EYE: return eye_anchor
		Anchor.CHEST: return chest_anchor
		Anchor.GROUND: return ground_anchor
	return null


func _fallback_ratio(kind: Anchor) -> float:
	match kind:
		Anchor.HEAD: return 0.85   # 1.70 at height 2.0 — the old FaceAnchor
		Anchor.EYE: return 0.75    # 1.50 at height 2.0 — the old eye_height
		Anchor.CHEST: return 0.55
		Anchor.GROUND: return 0.0
	return 0.0
