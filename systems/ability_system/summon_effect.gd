class_name SummonEffect
extends AbilityEffect
## Instantiates definition.unit_scene as a new Unit, places it at the
## target ground point, gives it the caster's faction, and injects it
## into the CURRENTLY RUNNING combat via CombatManager.add_unit_to_combat()
## — right after the caster, so it acts almost immediately (see that
## method's own doc comment for why that's the chosen rule over rolling
## fresh initiative). Pairs with GroundPointTargeting the same way
## MoveCasterEffect (Jump) does — there's no unit to summon ONTO, only a
## spot to summon AT, and that targeting already rejects a spot that's
## out of range, off the navmesh, or already occupied.
##
## Outside combat, add_unit_to_combat() is a no-op (nothing to inject
## into) — the summoned unit still gets created and placed, it just won't
## have a turn of its own until combat actually starts.
##
## A fully separate class from SummonDemonEffect (which stays untouched)
## since a generic summon has no reason to carry that effect's
## roster-aware behavior (reading/writing OwnedDemon state, enforcing the
## party-wide active-summon cap) — but both effects configure the
## summoned Unit the same way, via Unit.definition's cascading setter
## (see unit.gd), rather than each effect hand-copying its own subset of
## fields the way this one used to (hp_override/move_override).

@export var definition: UnitDefinition
## Left unset, the summon lasts indefinitely (until it dies normally).
## Set to a StatusEffect with a DespawnOnExpireBehavior (see that file)
## to give the summon a limited lifespan — applied directly to the
## SUMMON, not the caster, so its default_duration ticks down via the
## existing StatusManager machinery on the summon's own turns, no new
## timer system needed.
@export var duration_status: StatusEffect


func apply(attacker: Unit, target, _ability: Ability, _is_critical: bool) -> Dictionary:
	if not definition or not definition.unit_scene or not (target is Vector3):
		return {}

	var summon: Unit = definition.unit_scene.instantiate()
	summon.definition = definition
	summon.faction = attacker.faction
	# Ties this summon's lifetime to attacker's — see UnitDeath.handle_death,
	# which expires everything it summoned the moment it dies.
	summon.summoned_by = attacker
	# Reads as "your" summon, not a random third color scheme — only the
	# plain Color values, not highlight_mesh/outline_mesh themselves
	# (those stay as whatever mesh nodes the summon's own instance already
	# wires up internally; copying a NODE reference from the attacker
	# would point the summon's selection visuals at the attacker's own
	# meshes instead of its own).
	summon.hover_color = attacker.hover_color
	summon.selected_color = attacker.selected_color

	attacker.get_parent().add_child(summon)
	summon.global_position = target

	if duration_status:
		summon.apply_status(duration_status)

	CombatManager.add_unit_to_combat(summon, attacker)

	SystemLog.print("%s summons %s." % [LogFormat.unit_name(attacker), LogFormat.unit_name(summon)])
	return {"summoned": summon}


func describe() -> String:
	return "Summons a creature to fight alongside you"
