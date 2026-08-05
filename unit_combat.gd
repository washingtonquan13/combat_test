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
## (status), _owner._handle_death() (death cleanup spans selection,
## movement, and physics all at once, so it stays a Unit-level
## orchestrator rather than combat-specific logic) — components talk to
## their owner, never to each other, same rule UnitMovement's
## notify_movement_idle_check() established.

var _owner: Unit


func _init(owner: Unit) -> void:
	_owner = owner


## GURPS-style roll-under: 3d6 <= target_number succeeds. Lower rolls are
## always better, and margin is how far under (positive = comfortable pass).
func roll_vs(target_number: int) -> Dictionary:
	var roll: int = randi_range(1, 6) + randi_range(1, 6) + randi_range(1, 6)
	return {
		"roll": roll,
		"target": target_number,
		"success": roll <= target_number,
		"margin": target_number - roll,
	}


## Placeholder melee/ranged skill — just DX for now. Swap in a real skill
## lookup later (weapon skill, ability-specific skill, etc.) without
## touching use_ability()'s call site.
func attack_skill() -> int:
	return _owner.dexterity


## abilities[0], or null if this unit has none equipped. Used as the
## fallback when nothing's explicitly armed via AbilityManager — see that
## autoload's doc comment.
func default_ability() -> Ability:
	return _owner.abilities[0] if not _owner.abilities.is_empty() else null


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
	result["already_acted"] = ability.uses_attack_action and _owner.has_attacked

	if result.already_acted:
		return result

	if not result.in_range:
		return result

	if ability.uses_attack_action:
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

		var to_hit := roll_vs(to_hit_target)
		result["to_hit"] = to_hit
		if not to_hit.success:
			SystemLog.print("%s [i]misses[/i] %s with %s." % [LogFormat.unit_name(_owner), _log_target_desc(target), ability.ability_name])
			_owner.ability_used.emit(_owner, target, result)
			return result

	result["hit"] = true

	if ability.timing and ability.timing.waits_for_impact:
		_owner.begin_busy()
		await _wait_for_impact_or_timeout(ability.timing.impact_timeout)
		_owner.end_busy()

	var effect_results: Array = []
	var total_damage: int = 0
	for effect in ability.effects:
		var effect_result: Dictionary = effect.apply(_owner, target, ability)
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
	return result


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
		# corpse still carves — see Unit._handle_death) should observe
		# the unit's final post-death state, not catch it mid-death since
		# signal emission is synchronous.
		_owner._handle_death()
		_owner.died.emit(_owner)
