class_name SummonDemonEffect
extends AbilityEffect
## Fields a specific OwnedDemon roster entry as a live Unit — a fully
## separate class from SummonEffect (which stays untouched, still
## available for any future non-demon summon, e.g. a controllable
## fireball) since demon summons need roster-aware behavior SummonEffect
## has no reason to carry: reading/writing OwnedDemon state, and
## enforcing the party-wide summon cap below.
##
## Unlike SummonEffect, owned_demon identifies WHICH roster entry to
## field, not a fixed definition — so a single shared ability template
## (data/abilities/summon_demon_template.tres) works for every owned
## demon; hotbar_slot.gd constructs a fresh SummonDemonEffect instance
## per pick from the roster popup instead of one .tres existing per
## demon (see that file's own header for the full popup flow).
##
## Initializes the summoned Unit's current_hp/current_fp from
## owned_demon's OWN current values, not full health — a demon that
## came into the roster damaged (from a prior Dismiss, or eventually a
## rough negotiation) stays damaged until something actively heals it;
## re-summoning isn't free healing.

@export var owned_demon: OwnedDemon
## Party-wide cap on how many demons can be actively fielded at once —
## kept per-effect rather than a global constant so a future capacity
## item/ability could differ, though nothing currently varies it.
## Counted live across the whole party (see apply() below), not
## per-summoner: this project only ever has one summoner today, but the
## rule is written to not silently break if that changes.
@export var max_active_summons: int = 1


func apply(attacker: Unit, target, _ability: Ability, _is_critical: bool) -> Dictionary:
	if not owned_demon or not (target is Vector3):
		return {}
	if not DemonRoster.is_owned(owned_demon):
		# Defensive only — the roster entry could theoretically have been
		# consumed by fusion between the picker opening and this resolving.
		return {}

	var active_count: int = 0
	for unit in UnitQuery.all_units(attacker.get_tree()):
		if unit.is_alive() and unit.is_player_controlled() and unit.summoned_by != null and unit.owned_demon != null:
			active_count += 1
	if active_count >= max_active_summons:
		SystemLog.print("%s can't field any more demons right now." % LogFormat.unit_name(attacker))
		return {}

	var summon: Unit = owned_demon.species.unit_scene.instantiate()
	# The cascade off .definition carries display_name/portrait_texture/
	# the full stat block/abilities/ai_behaviors onto the summon in one
	# line (see Unit.definition's setter) — faction/current_hp/current_fp
	# still need an explicit override afterward: a recruited demon fights
	# for whoever fielded it, not its species' default faction, and a
	# damaged demon shouldn't be free-healed back to full just by being
	# re-summoned (see owned_demon.gd's own header).
	summon.definition = owned_demon.species
	summon.faction = attacker.faction
	summon.current_hp = owned_demon.current_hp
	summon.current_fp = owned_demon.current_fp
	# Ties this summon's lifetime to attacker's — see UnitDeath.handle_death,
	# which expires everything it summoned the moment it dies. Same
	# convention SummonEffect already uses for its own summons.
	summon.summoned_by = attacker
	summon.owned_demon = owned_demon
	summon.hover_color = attacker.hover_color
	summon.selected_color = attacker.selected_color

	owned_demon.has_been_summoned = true

	attacker.get_parent().add_child(summon)
	summon.global_position = target

	CombatManager.add_unit_to_combat(summon, attacker)

	SystemLog.print("%s summons %s." % [LogFormat.unit_name(attacker), LogFormat.unit_name(summon)])
	# Same result key SummonEffect.apply() returns — party_panel.gd's
	# "hand of cards" summon-chip UI already keys off result.effects
	# containing a "summoned" entry generically, not off which effect
	# class produced it, so a demon summon shows up there with zero
	# changes to that file.
	return {"summoned": summon}


func describe() -> String:
	return "Summons a demon from your roster to fight alongside you"
