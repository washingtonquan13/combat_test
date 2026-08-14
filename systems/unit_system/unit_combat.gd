class_name UnitCombat
extends RefCounted
## Owns ability resolution and damage-taking logic for ONE unit. Owned
## by that Unit (see Unit._combat), same pattern as StatusManager/
## UnitActionState/UnitFacing/UnitSelection/UnitMovement.
##
## Owns NO data fields at all — every stat this touches (strength,
## dexterity, current_hp, damage_reduction, abilities, ...) is @export
## and stays directly on Unit, same editor-safety reasoning as every
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
const ALTITUDE_ADVANTAGE: AltitudeAdvantageBehavior = preload("res://data/altitude_advantage.tres")


## GURPS ST-based swing/thrust damage — computed from a formula rather
## than looking up the official table — approximates the real
## (N+1)d-1/+0/+1/+2 progression ST 10-22 is built on (1d, 1d+1, 1d+2,
## 2d-1, 2d, ...):
##
##   swing dice  = ((ST - 10) + 4) / 4
##   thrust dice = ((ST - 10) + 4) / 8
##
## That division produces a fractional die count; the fractional part
## becomes an adjustment on the floored whole-die count:
##   fraction == 0             -> no adjustment
##   fraction <= 0.25          -> +1 flat
##   0.25 < fraction <= 0.5    -> +2 flat
##   0.5  < fraction <= 0.75   -> +1 extra die, with a flat -1 ("1d-1")
##   fraction >  0.75          -> +1 extra die, no flat modifier
##                                 ("1d+0") — rolls over to the next
##                                 full die, continuing the same
##                                 -1/+0/+1/+2 cycle.
##
## That bucketing only applies once the floored die count is already
## >= 1. Thrust's divisor (8, vs. swing's 4) keeps raw below 1.0 all the
## way up to ST13 — including the default ST10 — so it only "just
## works" for swing, by accident of where its divisor happens to cross
## 1.0. GURPS itself never drops below 1 die; a weak thrust keeps
## stacking flat penalty on a single d6 instead (1d-6 at the low end),
## so below the tier-1 threshold _damage_dice pins the count at 1 and
## derives flat_bonus straight from raw, rather than flooring the die
## count to 0 (or negative) and bucketing a fractional adjustment on
## top of it — which is what the code did before, and is how a default
## ST10 unit's thrust ended up rolling a fixed "0d+2" (a constant,
## un-rolled +2) instead of the correct "1d-2".
##
## Lives here rather than on either caller (StDamageEffect,
## GearDamageEffect) since neither actually owns it — it's this unit's
## own ST-derived capability, independent of whichever ability or
## weapon happens to be delivering it. Already had to be pried loose
## from StDamageEffect once (when GearDamageEffect needed the identical
## math for equipped weapons); stats_column.gd's character-sheet display
## needs the same numbers a third time, with no ability involved at all
## — the clearest sign this belongs on the unit, not an effect.
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
	var divisor: int = 4 if damage_type == DamageType.SWING else 8
	var raw: float = float((_owner.get_stat("ST") - 10) + 4) / divisor

	var dice_count: int = int(floor(raw))
	var flat_bonus: int = 0

	if dice_count < 1:
		# Never fewer than 1 die — see this method's doc comment above.
		# flat_bonus is derived directly from raw (not from a fraction
		# against a floor that's already 0 or negative) so it keeps
		# decreasing by 1 every quarter-die below the tier-1 threshold,
		# with no discontinuity at the boundary: this formula and the
		# bucket logic below agree exactly at raw == 1.0.
		dice_count = 1
		flat_bonus = int(ceil(4.0 * (raw - 1.0)))
	else:
		var fraction: float = raw - dice_count
		if fraction > 0.75:
			dice_count += 1
		elif fraction > 0.5:
			dice_count += 1
			flat_bonus = -1
		elif fraction > 0.25:
			flat_bonus = 2
		elif fraction > 0.0:
			flat_bonus = 1

	return {"count": dice_count, "flat_bonus": flat_bonus}


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
## selection instead — called from this unit's own _on_input_event.
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
func resolve_click_ability(acting_unit: Unit) -> Ability:
	var ability: Ability = AbilityManager.armed_ability if AbilityManager.armed_ability else acting_unit.default_ability()
	var wants_ally: bool = ability and ability.targeting and ability.targeting.requires_ally_target()
	var hostile: bool = acting_unit.is_hostile_to(_owner)
	return ability if ability and (wants_ally != hostile) else null


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
## { in_range, already_acted, busy, hit, damage, to_hit, effects, ability }
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
		"busy": not _owner.can_act(),
		"in_range": false,
		"already_acted": false,
		"hit": false,
		"damage": 0,
		"effects": [],
	}

	if result.busy:
		return result

	result["in_range"] = ability.is_in_range(_owner, target)
	# The once-per-turn attack-action economy only means something WITH a
	# turn — gated to combat the same way move_caster_effect.gd already
	# gates Jump's own move-budget spend/check, so has_attacked can't act
	# as a permanent "attacked once, ever" limiter out of combat (nothing
	# outside a real combat's turn-advance ever resets it — see
	# CombatManager._advance_turn/Unit.reset_turn_actions).
	result["already_acted"] = CombatManager.in_combat and ability.uses_attack_action and _owner.has_attacked

	if result.already_acted:
		return result

	if not result.in_range:
		return result

	if CombatManager.in_combat and ability.uses_attack_action:
		_owner.has_attacked = true

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
		# StatusBehavior.modify_outgoing_attack_to_hit.
		var to_hit_target: int = attack_skill()
		to_hit_target += _owner.outgoing_attack_to_hit_modifier(target, ability)
		if target is Unit:
			to_hit_target += target.incoming_attack_to_hit_modifier(_owner, ability)
			to_hit_target += ALTITUDE_ADVANTAGE.modify_incoming_attack_to_hit(target, _owner, ability)

		var to_hit := SuccessRoll.roll_vs(to_hit_target)
		result["to_hit"] = to_hit
		if not to_hit.success:
			SystemLog.print("%s [i]misses[/i] %s with %s." % [LogFormat.unit_name(_owner), _log_target_desc(target), ability.ability_name])
			if to_hit.critical_failure:
				_owner.apply_status(CRIT_FAIL_PENALTY)
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

	var effect_results: Array = []
	var total_damage: int = 0
	for effect in ability.effects:
		var effect_result: Dictionary = effect.apply(_owner, target, ability, is_critical)
		effect_results.append(effect_result)
		if effect_result.has("damage"):
			total_damage += effect_result["damage"]

	result["effects"] = effect_results
	result["damage"] = total_damage

	if total_damage > 0:
		SystemLog.print("%s hits %s with %s." % [LogFormat.unit_name(_owner), _log_target_desc(target), ability.ability_name])
	else:
		SystemLog.print("%s uses %s on %s." % [LogFormat.unit_name(_owner), ability.ability_name, _log_target_desc(target)])

	_owner.ability_used.emit(_owner, target, result)
	_maybe_trigger_combat(target)
	return result


## Starts real combat if this was an out-of-combat hostile act against a
## living Unit — miss or hit, doesn't matter, an attempted attack is still
## aggression. No-op for point/ground-targeted abilities (target isn't a
## Unit) — AoE/ground-targeted hostile abilities deliberately don't
## trigger combat yet; see CombatManager.start_combat_from_hostile_act.
func _maybe_trigger_combat(target) -> void:
	if CombatManager.in_combat:
		return
	if not target is Unit or not target.is_alive():
		return
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


func take_damage(amount: int) -> void:
	if amount <= 0:
		return
	_owner.current_hp = max(_owner.current_hp - amount, 0)
	_owner.took_damage.emit(_owner, amount)
	SystemLog.print("%s takes %s damage." % [LogFormat.unit_name(_owner), LogFormat.damage(amount)])
	_owner.notify_status_of_damage(amount)
	if _owner.current_hp == 0:
		SystemLog.print("[b]%s has died.[/b]" % LogFormat.unit_name(_owner))
		# Cleanup BEFORE the signal, not after — died listeners (e.g.
		# CombatManager's navmesh rebake, which needs to see whether this
		# corpse still carves — see UnitDeath.handle_death) should observe
		# the unit's final post-death state, not catch it mid-death since
		# signal emission is synchronous.
		_owner.handle_death()
		_owner.died.emit(_owner)
