class_name Ability
extends Resource
## Data for one combat ability — melee or ranged, with its own targeting
## rule and damage dice. Create instances as .tres files (editor: right-
## click in FileSystem > New Resource > Ability), not in code, so
## designers can add/tune abilities without touching scripts.
##
## Deliberately scoped to what's actually needed right now (a melee
## basic attack, a ranged basic attack with line of sight) rather than a
## speculative general framework for ability types with no concrete
## design yet (AoE, buffs, cooldowns, resource costs). Extend this when
## there's a second real requirement to generalize from, not before.
##
## Damage dice are embedded directly here (damage_dice_count/sides/bonus)
## rather than referencing Unit's existing thrust/swing/damage Die nodes.
## Two reasons: Die is a Node (extends Node), and a Resource shouldn't
## hold a reference to a specific scene-tree node instance — Resources
## are meant to be data that can be shared/reused, not tied to one
## unit's scene. And conceptually, an ability's damage shouldn't have to
## come from "whichever fixed die the wielder happens to have" — a Power
## Attack ability and a Quick Jab ability should be able to specify
## completely different dice, independent of any weapon. Wiring an
## ability's damage to derive from an equipped WEAPON specifically is the
## natural next step once weapon choice (already on the project's to-do
## list) is actually built — that's a separate, later integration, not
## something this resource tries to solve now.

enum TargetType { MELEE_ENEMY, RANGED_ENEMY }

@export var ability_name: String = "Basic Attack"
@export var icon: Texture2D

@export_group("Targeting")
@export var target_type: TargetType = TargetType.MELEE_ENEMY
## Only used when target_type is MELEE_ENEMY. Compared against
## Unit.edge_distance_to (edge-to-edge, not center-to-center) — this
## ability's own range, not a shared per-unit stat. Different melee
## abilities on the same unit can have different reach (a dagger stab
## and a spear thrust shouldn't have to agree on one number) — this is
## exactly the thing that broke when melee range used to defer to a
## Unit.reach stat: changing that ONE number for any reason (including
## by mistake) silently changed the range of EVERY melee ability that
## unit had, with no way for a specific ability to override it.
@export var melee_range: float = 1.0
## Only used when target_type is RANGED_ENEMY. Same edge-to-edge
## convention as melee_range above.
@export var max_range: float = 8.0
## Only used when target_type is RANGED_ENEMY. See LineOfSight.
@export var requires_line_of_sight: bool = true
## Physics layer LoS raycasts treat as blocking (walls/terrain — not
## units; see LineOfSight's doc comment for why units don't block shots).
@export var los_obstruction_mask: int = 1

@export_group("Damage")
@export var damage_dice_count: int = 1
@export var damage_dice_sides: int = 6
@export var damage_dice_bonus: int = 0

@export_group("Cost")
## Whether this counts against the once-per-turn attack action
## (Unit.has_attacked). Every current ability does; kept as an explicit
## flag rather than assumed so a future free-action ability doesn't need
## special-casing anywhere else.
@export var uses_attack_action: bool = true


func roll_damage() -> int:
	var total: int = 0
	for _i in damage_dice_count:
		total += randi_range(1, damage_dice_sides)
	return total + damage_dice_bonus


## Whether target is a legal target for THIS ability from attacker's
## current position — range/LoS only, not turn state (has_attacked
## etc.), which stays Unit.use_ability()'s job.
func is_in_range(attacker: Unit, target: Unit) -> bool:
	match target_type:
		TargetType.MELEE_ENEMY:
			return attacker.edge_distance_to(target) <= melee_range
		TargetType.RANGED_ENEMY:
			if attacker.edge_distance_to(target) > max_range:
				return false
			if requires_line_of_sight and not LineOfSight.has_clear_shot(attacker, target, los_obstruction_mask):
				return false
			return true
	return false
