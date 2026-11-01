class_name UnitCombat
extends RefCounted
## Owns ability resolution and damage-taking logic for ONE unit. Owned
## by that Unit (see Unit._combat), same pattern as StatusManager/
## UnitActionState/UnitFacing/UnitSelection/UnitMovement.
##
## Owns NO data fields at all — every stat this touches (read through
## Unit.get_stat()/get_pool(), abilities, ...) stays on Unit, same editor-safety reasoning as every
## previous component's exports. This is purely the LOGIC that resolves
## against those fields through the owner reference — same shape as
## UnitFacing, which also owns nothing of its own.
##
## use_ability()/take_damage() reach back into Unit for cross-cutting
## coordination rather than touching other components directly —
## _owner.snap_face_point() (facing), _owner.notify_status_of_damage()
## (status), _owner.handle_death() (death cleanup, owned by UnitDeath) —
## components talk to their owner, never to each other, same rule
## UnitMovement's notify_movement_idle_check() established.

var _owner: Unit

## Applied to the attacker on a critical-failure to-hit roll — see
## roll_vs()'s critical_failure detection and use_ability()'s miss
## branch below. default_duration=2, not 1: StatusManager.
## tick_turn_start() fires (and decrements) at the START of the owning
## unit's own turn, before that turn's actions are available, so a
## duration-1 status applied mid-turn would already be ticked to 0 and
## removed before the attacker could ever act under it. 2 survives the
## attacker's own next turn (ticks 2->1, stays active) and expires at
## the start of the turn after that (ticks 1->0).
const CRIT_FAIL_PENALTY: StatusEffect = preload("res://data/statuses/crit_fail_penalty.tres")

## General ranged high-ground rule — a live position comparison for
## THIS attack, not a persistent condition on either unit, so it's
## applied directly here rather than through StatusManager's per-status
## aggregation the way Prone/Bless/etc. are. See AltitudeAdvantageBehavior's
## own header for why it used to be Flying-status-only and no longer is.
const PICK_UP: Ability = preload("res://data/abilities/pick_up.tres")

## Multiples of HP below zero at which a unit on the downed rule is dead
## outright, no roll — GURPS's -5x HP.
const DEATH_DEPTH: int = 5

const ALTITUDE_ADVANTAGE: AltitudeAdvantageBehavior = preload("res://data/altitude_advantage.tres")


## GURPS ST-based swing/thrust damage: the Basic Set damage table (B16)
## as a formula, for any ST. Ported from GCS's BasicSet progression
## (github.com/richardwilkes/gcs, model/gurps/enums/progression), which
## matches the table through ST 100 and the book's +1d per 10 ST past it.
##
## Damage climbs a ladder of quarter-dice — 1d-1, 1d, 1d+1, 1d+2, 2d-1 —
## and ST climbs it more slowly the higher it goes: swing a step per ST
## to 27, then roughly a step per 2 ST; thrust a step per 2 ST to 50;
## both slower again past that. The odd constants in _damage_dice are
## those breakpoints. Below 1 die the table never drops to 0d: it keeps
## stacking a penalty on a single d6 (thrust 1d-6 at ST 1).
##
## Lives on the unit, not on StDamageEffect or GearDamageEffect: it is
## this unit's own ST-derived capability, and the character sheet reads
## it too.
enum DamageType { SWING, THRUST }


func _init(owner: Unit) -> void:
	_owner = owner


## Rolls this unit's ST-derived swing/thrust damage plus bonus (an
## ability's own flat bonus, or an equipped weapon's damage_bonus — see
## StDamageEffect/GearDamageEffect, the two current callers).
func roll_damage(damage_type: DamageType, bonus: int) -> int:
	var dice: Dictionary = _damage_dice(damage_type)
	var total: int = 0
	for _i in int(dice.count):
		total += randi_range(1, 6)  # GURPS damage dice are always d6
	return total + int(dice.flat_bonus) + bonus


## Maximum possible swing/thrust damage plus bonus — every die at its
## highest face — for critical hits (GearDamageEffect/StDamageEffect),
## which deal guaranteed max damage instead of rolling.
func max_damage(damage_type: DamageType, bonus: int) -> int:
	var dice: Dictionary = _damage_dice(damage_type)
	return int(dice.count) * 6 + int(dice.flat_bonus) + bonus


## Expected value of roll_damage() without actually rolling — each d6
## averages 3.5 — used by AiScorer to rank candidate actions by expected
## damage rather than sampling a live roll (which would make the AI's
## own decision non-deterministic and untestable independent of RNG).
func average_damage(damage_type: DamageType, bonus: int) -> float:
	var dice: Dictionary = _damage_dice(damage_type)
	return float(dice.count) * 3.5 + float(dice.flat_bonus) + float(bonus)


## Same formula as roll_damage(), without rolling — e.g. "1d+2" — for
## display (see stats_column.gd's Thrust/Swing rows, shown with bonus 0
## for the character's own base capability).
func describe_damage(damage_type: DamageType, bonus: int) -> String:
	var dice: Dictionary = _damage_dice(damage_type)
	var flat: int = int(dice.flat_bonus) + bonus
	var text: String = "%dd" % int(dice.count)
	if flat > 0:
		text += "+%d" % flat
	elif flat < 0:
		text += str(flat)
	return text


func _damage_dice(damage_type: DamageType) -> Dictionary:
	var st: int = floori(_owner.get_stat(StatIds.ST))
	return _swing_dice(st) if damage_type == DamageType.SWING else _thrust_dice(st)


static func _thrust_dice(st: int) -> Dictionary:
	if st < 19:
		return {"count": 1, "flat_bonus": -(6 - (st - 1) / 2)}
	var steps: int = st - 11
	if st > 50:
		steps -= 1
		if st > 79:
			steps -= 1 + (st - 80) / 5
	return _ladder(steps)


static func _swing_dice(st: int) -> Dictionary:
	if st < 10:
		return {"count": 1, "flat_bonus": -(5 - (st - 1) / 2)}
	if st < 28:
		return {"count": (st - 9) / 4 + 1, "flat_bonus": (st - 9) % 4 - 1}
	var steps: int = st
	if st > 40:
		steps -= (st - 40) / 5
	if st > 59:
		steps += 1
	return _ladder(steps + 9)


## Half-steps to dice: every 8 is a die, the rest walk -1, +0, +1, +2.
static func _ladder(steps: int) -> Dictionary:
	return {"count": steps / 8 + 1, "flat_bonus": steps % 8 / 2 - 1}


## Every attack — melee, ranged, any weapon — resolves against this one
## skill rather than a skill per weapon type, by design (see
## data/skills/basic_attack.tres's own description for the reasoning).
## Explicitly trainable independent of raw DX: SkillCalculator.
## get_skill_level() always keeps the better of a unit's actual trained
## level and Basic Attack's own DX default (modifier 0), so an untrained
## unit gets exactly plain DX — identical to this method's old
## placeholder behavior — and training only ever helps, never hurts,
## relative to that floor.
func attack_skill() -> int:
	return SkillCalculator.get_skill_level(_owner, "Basic Attack").skill_level


## abilities[0], or null if this unit has none equipped. Used as the
## fallback when nothing's explicitly armed via AbilityManager — see that
## autoload's doc comment.
func default_ability() -> Ability:
	return _owner.abilities[0] if not _owner.abilities.is_empty() else null


## Whichever ability would fire if `acting_unit` left-clicks this unit
## right now, or null if the click should fall through to normal
## selection instead — called by ClickRouter.click_unit, through
## Unit.click_ability_for.
## Lives on the CLICKED unit's _combat (answering "if acting_unit clicked
## ME, what fires") rather than the acting unit's, matching the existing
## defender-perspective shape incoming_attack_to_hit_modifier() already
## uses, and avoiding a cross-unit forward acting_unit._combat couldn't
## otherwise reach.
##
## Which clicks count depends on the resolved ability's own targeting: an
## ordinary (non-ally) ability only fires on a HOSTILE click; one with
## AbilityTargeting.requires_ally set (a heal, a buff) only fires on a
## click on the SAME faction instead — see
## AbilityTargeting.requires_ally_target's doc comment for why this is a
## flag there rather than a separate targeting subclass. Resolving the
## ability before checking hostility (rather than after) is what makes
## that possible — the routing decision depends on which ability would
## actually be used, not a fixed rule.
##
## A Downed ally takes priority over all of that: clicking one with
## nothing armed picks it up (PICK_UP).
func resolve_click_ability(acting_unit: Unit) -> Ability:
	if not AbilityManager.armed_ability and _owner.is_downed() 			and acting_unit != _owner and not acting_unit.is_hostile_to(_owner):
		return PICK_UP
	var ability: Ability = AbilityManager.armed_ability if AbilityManager.armed_ability else acting_unit.default_ability()
	if not ability:
		return null
	var wants_ally: bool = ability.targeting and ability.targeting.requires_ally_target()
	if wants_ally:
		return ability if not acting_unit.is_hostile_to(_owner) else null
	# Non-ally abilities (ordinary attacks) are routable at anyone who
	# isn't your own side — a neutral or allied-faction unit is a valid
	# target, not just an already-hostile one. See
	## AttackInteraction.is_available()'s own identical rule (right-click
	## menu) and FactionRelations/_maybe_trigger_combat below (what
	## actually happens the instant the attack lands).
	return ability if not _owner.is_player_controlled() else null


## Resolves using ability against target. Range/LoS rules come from
## ability.targeting; what happens on a hit comes from ability.effects
## (see those classes' doc comments) — this method's job is purely turn
## state (the once-per-turn attack action) and the single to-hit roll
## that gates ALL of an ability's effects together, not per-effect
## resolution. A miss still spends the action if the ability uses one,
## same as before: the attempt itself is what's spent, not the hit.
##
## Rejects outright (busy=true in the result, nothing else evaluated) if
## this unit already has something in flight — movement, or a previous
## ability's async effect (e.g. mid-Jump-animation) still resolving —
## OR if a status effect (Sleep, Stun, ...) prevents it from acting at
## all this turn. Both share the same "busy" result key rather than
## separate flags, since from every existing caller's perspective
## (CombatAI, click routing) they mean the same thing: nothing happened,
## try something else or end the turn.
##
## Returns a result dict for logging/UI:
## { in_range, invalid_target, already_acted, busy, hit, damage, to_hit, effects, ability }
## damage is the SUM of every effect's own "damage" key, for convenience
## — usually zero or one DamageEffect, but this doesn't assume that; see
## effects for the individual per-effect results if more detail is
## needed than the aggregate.
##
## Emits ability_use_started BEFORE to-hit is even rolled — see that
## signal's doc comment on Unit for why: animation/VFX need to react to
## "this is happening" immediately (to start a swing, launch a
## projectile), not wait for the final outcome. If ability.timing is
## assigned and its waits_for_impact is set, effects don't actually
## apply until Unit.notify_impact() fires (or a timeout elapses) AFTER a
## confirmed hit — see _wait_for_impact_or_timeout. Most abilities have
## no AbilityTiming at all (see that class), in which case effects apply
## immediately, same as always. ability_used (the final result, same
## signal as always) only fires once effects have actually resolved,
## which may now be meaningfully later than when this method was called
## for abilities that do wait.
func use_ability(ability: Ability, target) -> Dictionary:
	var result := {
		"attacker": _owner,
		"target": target,
		"ability": ability,
		# can_act(), the STRICT form, which still counts walking: a unit
		# mid-path cannot also swing. Only being ORDERED is permissive
		# while moving (see UnitActionState.can_be_commanded).
		"busy": not _owner.can_act(),
		"invalid_target": false,
		"in_range": false,
		"already_acted": false,
		"cant_afford_move_cost": false,
		"cant_afford_fp_cost": false,
		"hit": false,
		"damage": 0,
		"effects": [],
	}

	if result.busy:
		return result

	# Turn order, as a hard precondition rather than a UI convention.
	#
	# There was no check here at all: out-of-turn use was prevented only
	# because the hotbar never showed a non-current unit's abilities. Now
	# that the bar follows the SELECTION, that accident is gone and this
	# has to be real — and it should have been anyway, since every AI
	# attack comes through this same path and nothing else was stopping a
	# misbehaving caller from acting out of turn.
	#
	# Only binding on a unit actually IN a fight, the same way move_to()
	# treats it: standing outside a battle means acting freely while it
	# rages.
	if _owner.in_combat() and not _owner.is_my_turn():
		result["busy"] = true
		return result

	# A structural mismatch, independent of range or turn economy — an
	# ally-only ability (heal.tres/cure.tres/bless.tres, anything with
	# AbilityTargeting.requires_ally set) aimed at a hostile target can
	# never be legal, so it's rejected here rather than in is_in_range's
	# geometry check. This is what actually stops a misconfigured
	# AiBehavior (see systems/ai_system) — or any other future caller —
	# from healing an enemy: previously requires_ally_target() was only
	# ever checked in resolve_click_ability(), the PLAYER's click-routing
	# path, never here in the resolution path CombatAI also calls.
	# Deliberately one-directional: an ordinary (non-ally) ability aimed
	# at an ally is NOT rejected — that targeting is hostility-agnostic
	# by design already (see AbilityTargeting.requires_ally's own doc
	# comment; friendly-fire-capable AoE already relies on this).
	if ability.targeting and ability.targeting.requires_ally_target() and target is Unit and _owner.is_hostile_to(target):
		result["invalid_target"] = true
		return result

	result["in_range"] = ability.is_in_range(_owner, target)
	result["already_acted"] = ability.attack_action_spent_by(_owner)
	# Hard precondition, not a clamp — same pattern Ladder.required_move
	# already uses (see Ability.move_cost's own header): an ability with a
	# flat move_cost either fully executes or is refused outright, never
	# "half cast." Out of combat, budget is effectively unlimited (same
	# convention UnitMovement.move_to() uses), so this only ever applies
	# mid-combat.
	result["cant_afford_move_cost"] = _owner.in_combat() and ability.move_cost > 0.0 and _owner.move_remaining < ability.move_cost
	# NOT wrapped in CombatManager.in_combat, unlike move_cost above — FP
	# is a persistent resource that exists whether or not a fight is
	# happening (move_remaining is meaningless out of combat; the FP pool
	# isn't), so casting an FP-costing ability outside combat still has
	# to be affordable. See Ability.fp_cost's own header.
	result["cant_afford_fp_cost"] = ability.fp_cost > 0.0 and _owner.get_pool(StatIds.FP) < ability.fp_cost

	if result.already_acted:
		return result

	if not result.in_range:
		return result

	if result.cant_afford_move_cost:
		return result

	if result.cant_afford_fp_cost:
		return result

	if _owner.in_combat() and ability.uses_attack_action:
		_owner.has_attacked = true

	if _owner.in_combat() and ability.move_cost > 0.0:
		_owner.spend_move(ability.move_cost)

	if ability.fp_cost > 0.0:
		_owner.set_pool(StatIds.FP, maxi(_owner.get_pool(StatIds.FP) - int(ability.fp_cost), 0))

	_owner.ability_use_started.emit(_owner, target, ability)

	# Face the target the instant the action is confirmed to happen, not
	# gradually — this is what gives CombatAI-driven attacks correct
	# facing too (AI never goes through mouse-hover aiming at all), and
	# covers Jump's facing for free (target is the landing point, so
	# facing it here IS facing the jump direction — no separate rotation
	# logic needed in MoveCasterEffect itself).
	if target is Vector3 or target is Unit:
		_owner.snap_face_point(target if target is Vector3 else target.global_position)

	if ability.requires_to_hit:
		# The DEFENDER's active statuses (Prone, etc.) can modify how
		# easy THEY are to hit — summed onto the attacker's own skill
		# before rolling, so e.g. Prone's melee bonus/ranged penalty
		# applies regardless of which ability is being used against them.
		# The ATTACKER's own active statuses (Bless, etc.) modify the
		# same target number from the other side — see
		# StatusBehavior.modify_outgoing_attack_to_hit. See _roll_to_hit
		# for the actual target-number math.
		var to_hit := _roll_to_hit(target, ability)
		result["to_hit"] = to_hit
		if not to_hit.success:
			SystemLog.print(_miss_log_line(target, ability))
			if to_hit.critical_failure:
				_owner.apply_status(CRIT_FAIL_PENALTY)
			_owner.ability_used.emit(_owner, target, result)
			_maybe_trigger_combat(target)
			return result
		# Every hit but a critical one meets the defender's best defense
		# before anything lands — see best_defense.
		var defense: Dictionary = {} if to_hit.critical_success or not target is Unit 			else target.best_defense(_owner, ability)
		if not defense.is_empty():
			target.spend_defense(defense.kind)
			var roll := SuccessRoll.roll_vs(defense.target)
			result["defense"] = defense.merged(roll)
			if roll.success:
				SystemLog.print(_defense_log_line(target, ability, defense.kind))
				_owner.ability_used.emit(_owner, target, result)
				_maybe_trigger_combat(target)
				return result

	result["hit"] = true

	if ability.timing and ability.timing.waits_for_impact:
		_owner.begin_busy()
		await _wait_for_impact_or_timeout(ability.timing.impact_timeout)
		_owner.end_busy()

	# Abilities with requires_to_hit=false never populate "to_hit" above,
	# so they correctly never critical-hit — there's no roll for a crit
	# to attach to (see this project's ability-by-ability scope check:
	# only the two GearDamageEffect basic attacks currently roll to-hit
	# at all).
	var is_critical: bool = result.get("to_hit", {}).get("critical_success", false)

	var effect_data: Dictionary = _apply_effects(target, ability, is_critical)
	result["effects"] = effect_data.effects
	result["damage"] = effect_data.damage

	if effect_data.damage > 0:
		SystemLog.print(_hit_log_line(target, ability))
	else:
		SystemLog.print(_use_log_line(target, ability))

	_owner.ability_used.emit(_owner, target, result)
	_maybe_trigger_combat(target)
	return result


## Attacker's to-hit target number against target for ability — own
## skill plus outgoing modifiers, defender's incoming modifiers and
## altitude advantage if target is a Unit. The one place that sum is
## built: the roll, the AI's expected damage and the player's hit-chance
## readout all start here.
func to_hit_target(target, ability: Ability) -> int:
	var number: int = attack_skill()
	number += _owner.outgoing_attack_to_hit_modifier(target, ability)
	if target is Unit:
		number += floori(target.get_stat(StatIds.SM))
		number += target.incoming_attack_to_hit_modifier(_owner, ability)
		number += ALTITUDE_ADVANTAGE.modify_incoming_attack_to_hit(target, _owner, ability)
	return number


## Pure computation; use_ability() still owns deciding what a miss DOES
## (crit-fail status, log, signal, early return).
func _roll_to_hit(target, ability: Ability) -> Dictionary:
	return SuccessRoll.roll_vs(to_hit_target(target, ability))


## Chance, 0..1, that ability lands on target: the to-hit roll, then the
## defender's best defense against every hit but a critical one. Exactly
## what use_ability() rolls, as odds — an ability that does not roll to
## hit always lands.
func hit_chance(target, ability: Ability) -> float:
	if not ability.requires_to_hit:
		return 1.0
	var attack: Dictionary = SuccessRoll.chances(to_hit_target(target, ability))
	var defense: Dictionary = target.best_defense(_owner, ability) if target is Unit else {}
	if defense.is_empty():
		return attack.success
	var defended: float = SuccessRoll.chances(defense.target).success
	return attack.critical_success + (attack.success - attack.critical_success) * (1.0 - defended)


## Whether this unit defends at all. A Downed unit is on the ground, and
## one whose status stops its turn (Sleep, Stun, ...) cannot react
## either.
func can_dodge() -> bool:
	return _owner.is_alive() and not _owner.is_downed() and not _owner.status_prevents_turn()


# --- Active defenses (B374-376) ---------------------------------------
# One defense per attack, the highest this unit has right now. Dodge has
# no limit. Parry is 3 + half Basic Attack, -4 for each parry already
# made; Block the same number, once, and only with a shield in hand. Both
# limits run until this unit's own next turn (reset_defenses).

const PARRY_PENALTY: int = -4
## Parrying a weapon with an empty hand.
const BARE_HAND_PARRY: int = -3

var parries: int = 0
var blocked: bool = false


func reset_defenses() -> void:
	parries = 0
	blocked = false


## The defense this unit would roll against ability from attacker:
## {kind: &"dodge"/&"parry"/&"block", target: int}, or {} when it cannot
## defend. The highest target wins; a tie goes to Dodge, then Parry, which
## leave Block for later. Parry is melee only: nothing here is thrown.
func best_defense(attacker: Unit, ability: Ability) -> Dictionary:
	if not can_dodge():
		return {}
	var best: Dictionary = {"kind": &"dodge", "target": dodge_target()}
	if ability.targeting is MeleeEnemyTargeting and parry_target(attacker) > best.target:
		best = {"kind": &"parry", "target": parry_target(attacker)}
	if not blocked and holds_shield() and block_target() > best.target:
		best = {"kind": &"block", "target": block_target()}
	return best


## Counts a defense against its limit — attempted, not only succeeded.
func spend_defense(kind: StringName) -> void:
	if kind == &"parry":
		parries += 1
	elif kind == &"block":
		blocked = true


func parry_target(attacker: Unit) -> int:
	var number: int = _half_skill_defense() + PARRY_PENALTY * parries
	if not _holds_melee_weapon(_owner) and _holds_melee_weapon(attacker):
		number += BARE_HAND_PARRY
	return number


func block_target() -> int:
	return _half_skill_defense()


## Dodge plus DB. The shield's DB is added here rather than in the Dodge
## stat so that halving Dodge (Bloodied, Exhausted) leaves it whole —
## the shield is no smaller for its bearer being hurt.
func dodge_target() -> int:
	return floori(_owner.get_stat(StatIds.DODGE)) + floori(_owner.get_stat(StatIds.DB))


func holds_shield() -> bool:
	for slot in [EquipSlot.Slot.MELEE_MAIN_HAND, EquipSlot.Slot.MELEE_OFF_HAND]:
		var item: Item = _owner.get_equipped_item(slot)
		if item and item.gear_data and item.gear_data.is_shield:
			return true
	return false


func _half_skill_defense() -> int:
	return 3 + floori(attack_skill() / 2.0) + floori(_owner.get_stat(StatIds.DB))


static func _holds_melee_weapon(unit: Unit) -> bool:
	for slot in [EquipSlot.Slot.MELEE_MAIN_HAND, EquipSlot.Slot.MELEE_OFF_HAND]:
		var item: Item = unit.get_equipped_item(slot)
		if item and item.gear_data and item.gear_data.weapon_data:
			return true
	return false


## Whether this unit shrugs off status as it lands, by a roll against
## the stat the status names (StatusEffect.resisted_by). Asleep or Downed
## still rolls: resisting is the body or the mind, not a reaction.
func resists(status: StatusEffect, source: Unit) -> bool:
	if not _rolls_to_resist(status, source):
		return false
	var roll: Dictionary = SuccessRoll.roll_vs(resistance_target(status))
	if roll.success:
		SystemLog.print(_resist_log_line(status))
	return roll.success


## The chance status lands on this unit from source, 0..1 — the same
## odds resists() rolls, for the readout.
func status_land_chance(status: StatusEffect, source: Unit) -> float:
	if not _rolls_to_resist(status, source):
		return 1.0
	return 1.0 - SuccessRoll.chances(resistance_target(status)).success


func resistance_target(status: StatusEffect) -> int:
	return floori(_owner.get_stat(status.resisted_by)) + status.resistance_modifier


## Nothing to roll for a status that names no stat, or one from this
## unit itself or an ally: a willing target never resists. No source at
## all (a surface) is rolled against like a hostile one.
func _rolls_to_resist(status: StatusEffect, source: Unit) -> bool:
	if status.resisted_by == &"":
		return false
	return source == null or not is_instance_valid(source) or source.is_hostile_to(_owner)


## Applies every one of ability's effects against target in order,
## aggregating each effect's own "damage" key into one total — usually
## zero or one DamageEffect, but this doesn't assume that; see effects
## for the individual per-effect results if more detail is needed than
## the aggregate.
func _apply_effects(target, ability: Ability, is_critical: bool) -> Dictionary:
	var effect_results: Array = []
	var total_damage: int = 0
	for effect in ability.effects:
		var effect_result: Dictionary = effect.apply(_owner, target, ability, is_critical)
		effect_results.append(effect_result)
		if effect_result.has("damage"):
			total_damage += effect_result["damage"]
	return {"effects": effect_results, "damage": total_damage}


## Starts real combat if this was an out-of-combat hostile act against a
## living Unit — miss or hit, doesn't matter, an attempted attack is still
## aggression. No-op for point/ground-targeted abilities (target isn't a
## Unit) — AoE/ground-targeted hostile abilities deliberately don't
## trigger combat yet; see CombatManager.start_combat_from_hostile_act.
func _maybe_trigger_combat(target) -> void:
	# THIS unit, not the world. Another fight running somewhere else is no
	# reason for an attack over here not to start its own.
	if _owner.in_combat():
		return
	if not target is Unit or not target.is_alive():
		return
	if not _owner.is_hostile_to(target):
		# Not already hostile — but the attack just happened regardless,
		# so it's a provocation: escalate the two FACTIONS to temporary
		# hostility (see FactionRelations), then re-check. Without the
		# re-check, combat would never actually start against a freshly-
		# provoked target, since the base relation is still non-hostile
		# at this exact instant.
		_owner.attacked_non_hostile_unit.emit(_owner, target)
		FactionRelations.escalate_to_temporary_hostile(_owner.faction, target.faction)
		if not _owner.is_hostile_to(target):
			return
	CombatManager.start_combat_from_hostile_act(_owner, target)


## Awaits Unit.impact_triggered, or `timeout` seconds, whichever comes
## first. The timeout exists so an ability with waits_for_impact set,
## but whose animation/VFX ISN'T actually wired up to call
## notify_impact(), doesn't hang the whole turn forever — it just
## resolves a little late instead, a far safer failure mode than a
## stuck game. Polls once per frame rather than trying to build a true
## signal "race" — simpler to reason about, and the cost is negligible
## given timeouts here are measured in single-digit seconds at most.
##
## `done` is wrapped in a single-element Array rather than a bare bool —
## GDScript lambda closures capture local PRIMITIVE variables (bool,
## int, ...) BY VALUE, not by reference, so `done = true` inside the
## lambda would silently mutate a private copy scoped to the lambda
## itself, never the polling loop's own variable below, even though the
## lambda executes correctly and the assignment "succeeds." Arrays are a
## reference type — the lambda and the loop both hold a reference to the
## SAME array object, so mutating its contents (not reassigning the
## variable) actually propagates. This was a real, confirmed bug (found
## via diagnostic prints — both finish() calls fired exactly as
## expected, but the loop never saw it), not a hypothetical one.
func _wait_for_impact_or_timeout(timeout: float) -> void:
	var done := [false]
	var finish := func(): done[0] = true

	_owner.impact_triggered.connect(finish, CONNECT_ONE_SHOT)
	_owner.get_tree().create_timer(timeout).timeout.connect(finish, CONNECT_ONE_SHOT)

	while not done[0]:
		await _owner.get_tree().process_frame


## Describes an ability's target for log messages — a Unit gets its
## colored name, a Vector3 (ground/area targeting) gets a generic label,
## since there's no "name" to show for a point in space.
func _log_target_desc(target) -> String:
	return LogFormat.unit_name(target) if target is Unit else "the target area"


func _miss_log_line(target, ability: Ability) -> String:
	return "%s [i]misses[/i] %s with %s." % [LogFormat.unit_name(_owner), _log_target_desc(target), ability.ability_name]


const _DEFENSE_VERBS: Dictionary = {&"dodge": "dodges", &"parry": "parries", &"block": "blocks"}


func _defense_log_line(target, ability: Ability, kind: StringName) -> String:
	return "%s [i]%s[/i] %s's %s." % [_log_target_desc(target), _DEFENSE_VERBS[kind], LogFormat.unit_name(_owner), ability.ability_name]


func _resist_log_line(status: StatusEffect) -> String:
	return "%s [i]resists[/i] %s." % [LogFormat.unit_name(_owner), status.status_name]


func _hit_log_line(target, ability: Ability) -> String:
	return "%s hits %s with %s." % [LogFormat.unit_name(_owner), _log_target_desc(target), ability.ability_name]


func _use_log_line(target, ability: Ability) -> String:
	return "%s uses %s on %s." % [LogFormat.unit_name(_owner), ability.ability_name, _log_target_desc(target)]


func _damage_log_line(amount: int) -> String:
	return "%s takes %s damage." % [LogFormat.unit_name(_owner), LogFormat.damage(amount)]


func _death_log_line() -> String:
	return "[b]%s has died.[/b]" % LogFormat.unit_name(_owner)


## Restores amount HP, clamped at maximum HP — the positive-direction
## counterpart to take_damage() below. Emits healed() so anything
## watching for an HP change (unit_portrait.gd's live overlay, notably)
## refreshes on the way up too, not just the way down — take_damage()
## already emitted took_damage() for that; nothing on the heal side ever
## emitted its own equivalent, which is why healing correctly changed
## HP but never visibly showed it: HealEffect/AreaHealEffect/
## HealOverTimeBehavior each mutated HP directly, with no
## caller-side way to know it needed to redraw anything. Returns the
## amount ACTUALLY restored (may be less than amount once near/at
## maximum) so callers can log/report exactly how much landed without
## re-deriving before/after themselves.
##
## Any heal that lands on a Downed unit is also a pick-up from range,
## however small — HP stays wherever the heal left it, negative or not.
func heal(amount: int) -> int:
	if amount <= 0:
		return 0
	var before: int = _owner.get_pool(StatIds.HP)
	_owner.set_pool(StatIds.HP, mini(_owner.get_pool(StatIds.HP) + amount, floori(_owner.get_stat(StatIds.HP))))
	var applied: int = _owner.get_pool(StatIds.HP) - before
	if applied > 0:
		_owner.healed.emit(_owner, applied)
		pick_up()
	return applied


## A unit on the downed rule (Unit.uses_downed_rule) keeps going below 0
## HP. Each time a hit carries it past a threshold — 0, -1x HP, -2x HP,
## -3x HP, -4x HP — it rolls HT once, at the deepest threshold reached,
## or goes Downed. -5x HP is death outright. GURPS's negative-HP death
## checks, turned into a downed state: see downed_status().
##
## A Downed unit has no further threshold rolls; every hit on it is
## instead a mark toward death (DeathRollsBehavior), on top of the
## damage.
func take_damage(amount: int, critical: bool = false) -> void:
	if amount <= 0:
		return
	var before: int = _owner.get_pool(StatIds.HP)
	var floor_hp: int = -DEATH_DEPTH * _hp_step() if _owner.uses_downed_rule() else 0
	_owner.set_pool(StatIds.HP, max(before - amount, floor_hp))
	_owner.took_damage.emit(_owner, amount)
	SystemLog.print(_damage_log_line(amount))
	var was_downed: bool = _owner.is_downed()
	# Downed's own behaviors mark the hit here — and kill, if it was the
	# third mark toward death.
	_owner.notify_status_of_damage(amount, critical)
	if _owner.has_died:
		return

	if _owner.get_pool(StatIds.HP) <= floor_hp:
		_die()
	elif not was_downed:
		var crossed: int = _thresholds_crossed(before, _owner.get_pool(StatIds.HP))
		if crossed > 0:
			_roll_to_stay_up(crossed)


func hp_to_death() -> int:
	if _owner.uses_downed_rule():
		return _owner.get_pool(StatIds.HP) + DEATH_DEPTH * _hp_step()
	return _owner.get_pool(StatIds.HP)


## Clears Downed and leaves HP negative — getting back up does not heal
## anything. No roll until the next threshold. Healing calls this too.
func pick_up() -> bool:
	if not _owner.is_downed():
		return false
	_owner.remove_status(downed_status())
	SystemLog.print("%s is back on their feet at %d HP." % [LogFormat.unit_name(_owner), _owner.get_pool(StatIds.HP)])
	_owner.downed_changed.emit(_owner)
	return true


## The Downed status (data/statuses/downed.tres) is the only record of
## being Downed: its tally is the two tracks, its behaviors roll and
## mark them. Loaded rather than preloaded — the .tres's
## behavior scripts name Unit, which names this.
static var _downed_status: StatusEffect

static func downed_status() -> StatusEffect:
	if _downed_status == null:
		_downed_status = load("res://data/statuses/downed.tres")
	return _downed_status


func stabilize() -> void:
	if not _owner.is_downed() or _owner.is_stable():
		return
	_owner.downed_tally()["stable"] = DeathRollsBehavior.TO_END
	_owner.downed_tally_changed.emit(_owner)
	SystemLog.print("%s is stable, but still down at %d HP." % [LogFormat.unit_name(_owner), _owner.get_pool(StatIds.HP)])


## Thresholds sit at 0 and every negative multiple of HP above the death
## line. Reaching one exactly counts as crossing it.
func _thresholds_crossed(before: int, after: int) -> int:
	var crossed: int = 0
	for depth in DEATH_DEPTH:
		var threshold: int = -depth * _hp_step()
		if before > threshold and after <= threshold:
			crossed += 1
	return crossed


## HT, minus 1 per full multiple of HP below zero (the GURPS depth
## penalty), minus 1 more per threshold this one hit crossed — a single
## blow that goes through several is that much harder to stay standing
## through.
func _roll_to_stay_up(crossed: int) -> void:
	var penalty: int = _depth() + crossed
	var roll: Dictionary = SuccessRoll.roll_vs(floori(_owner.get_stat(StatIds.HT)) - penalty)
	var verdict: String = "stays up" if roll["success"] else "goes down"
	SystemLog.print("%s rolls HT-%d to stay up: %d vs %d — %s." % [
		LogFormat.unit_name(_owner), penalty, roll["roll"], roll["target"], verdict])
	if roll["success"]:
		return
	_owner.apply_status(downed_status())
	SystemLog.print("[b]%s is Downed![/b]" % LogFormat.unit_name(_owner))
	_owner.downed_changed.emit(_owner)


## Each Downed turn's roll (DeathRollsBehavior): HT minus the same depth
## penalty as staying up.
func roll_while_downed() -> Dictionary:
	var penalty: int = _depth()
	var roll: Dictionary = SuccessRoll.roll_vs(floori(_owner.get_stat(StatIds.HT)) - penalty)
	var verdict: String = "success" if roll["success"] else "failure"
	if roll["critical_success"] or roll["critical_failure"]:
		verdict = "critical " + verdict
	SystemLog.print("%s rolls HT-%d while down: %d vs %d — %s." % [
		LogFormat.unit_name(_owner), penalty, roll["roll"], roll["target"], verdict])
	return roll


## Full multiples of HP below zero.
func _depth() -> int:
	var hp: int = _owner.get_pool(StatIds.HP)
	return -hp / _hp_step() if hp < 0 else 0


func _hp_step() -> int:
	return maxi(floori(_owner.get_stat(StatIds.HP)), 1)


## A dead owned demon stays in the roster, marked dead, rather than being
## released — so it can be revived.
func _die() -> void:
	SystemLog.print(_death_log_line())
	if _owner.owned_demon:
		_owner.owned_demon.capture_pools(_owner)
		_owner.owned_demon.is_dead = true
	_owner.handle_death()
	_owner.died.emit(_owner)
