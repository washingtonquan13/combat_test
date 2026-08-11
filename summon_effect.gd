class_name SummonEffect
extends AbilityEffect
## Instantiates summon_scene as a new Unit, places it at the target
## ground point, gives it the caster's faction, and injects it into the
## CURRENTLY RUNNING combat via CombatManager.add_unit_to_combat() — right
## after the caster, so it acts almost immediately (see that method's own
## doc comment for why that's the chosen rule over rolling fresh
## initiative). Pairs with GroundPointTargeting the same way
## MoveCasterEffect (Jump) does — there's no unit to summon ONTO, only a
## spot to summon AT, and that targeting already rejects a spot that's
## out of range, off the navmesh, or already occupied.
##
## Outside combat, add_unit_to_combat() is a no-op (nothing to inject
## into) — the summoned unit still gets created and placed, it just won't
## have a turn of its own until combat actually starts.
##
## summon_scene is expected to be a Unit-derived PackedScene — unit.tscn
## itself is a valid choice, exactly like every existing combatant in
## this project already IS a plain unit.tscn instance with per-node
## property overrides (see main.tscn) rather than its own separate
## scene file. Stats/abilities/portrait are whatever that scene's own
## defaults are; hp_override/move_override below only touch the two
## things a summon most commonly wants to differ on without needing a
## whole separate .tscn per summon.

@export var summon_scene: PackedScene
## Left at 0, the summoned unit keeps summon_scene's own maximum_hp as
## authored. Set to give this specific summon a distinct HP pool (a
## squishier or tougher companion) without forking the base scene.
@export var hp_override: int = 0
## Left at 0, keeps summon_scene's own move stat.
@export var move_override: int = 0
## Left unset, the summon lasts indefinitely (until it dies normally).
## Set to a StatusEffect with a DespawnOnExpireBehavior (see that file)
## to give the summon a limited lifespan — applied directly to the
## SUMMON, not the caster, so its default_duration ticks down via the
## existing StatusManager machinery on the summon's own turns, no new
## timer system needed.
@export var duration_status: StatusEffect


func apply(attacker: Unit, target, _ability: Ability) -> Dictionary:
	if not summon_scene or not (target is Vector3):
		return {}

	var summon: Unit = summon_scene.instantiate()
	summon.faction = attacker.faction
	# Ties this summon's lifetime to attacker's — see Unit._handle_death,
	# which expires everything it summoned the moment it dies.
	summon.summoned_by = attacker
	# Reads as "your" summon, not a random third color scheme — only the
	# plain Color values, not highlight_mesh/outline_mesh themselves
	# (those stay as whatever mesh nodes summon_scene's own instance
	# already wires up internally; copying a NODE reference from the
	# attacker would point the summon's selection visuals at the
	# attacker's own meshes instead of its own).
	summon.hover_color = attacker.hover_color
	summon.selected_color = attacker.selected_color

	if hp_override > 0:
		summon.maximum_hp = hp_override
		summon.current_hp = hp_override
	if move_override > 0:
		summon.move = move_override

	attacker.get_parent().add_child(summon)
	summon.global_position = target

	if duration_status:
		summon.apply_status(duration_status)

	CombatManager.add_unit_to_combat(summon, attacker)

	SystemLog.print("%s summons %s." % [LogFormat.unit_name(attacker), LogFormat.unit_name(summon)])
	return {"summoned": summon}


func describe() -> String:
	return "Summons a creature to fight alongside you"
