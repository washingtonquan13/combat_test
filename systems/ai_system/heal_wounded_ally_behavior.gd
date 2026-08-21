class_name HealWoundedAllyBehavior
extends AiBehavior
## Heals whichever living ally is proportionally most wounded, if any
## are below hp_threshold — the most-wounded pick (not just "first
## found") matters once more than one ally is hurt at once. Doesn't
## consider unit itself a candidate (see UnitQuery.living_allies) —
## self-preservation is a different concern than party support and not
## part of what this behavior claims to do.
@export var heal_ability: Ability
@export_range(0.0, 1.0) var hp_threshold: float = 0.5


func resolve(unit: Unit) -> Dictionary:
	if not heal_ability:
		return {}
	var most_wounded: Unit = null
	var lowest_fraction: float = hp_threshold
	for ally in UnitQuery.living_allies(unit.get_tree(), unit):
		if ally.maximum_hp <= 0:
			continue
		var fraction: float = float(ally.current_hp) / float(ally.maximum_hp)
		if fraction < lowest_fraction:
			lowest_fraction = fraction
			most_wounded = ally
	if not most_wounded:
		return {}
	return {"ability": heal_ability, "target": most_wounded}
