class_name StatusManager
extends RefCounted
## Tracks and resolves every status effect currently active on ONE unit.
## Owned by that Unit (see Unit._status_manager), instantiated once per
## unit — Unit exposes a small public API (apply_status/remove_status/
## has_status/etc.) that just forwards here, same reasoning as
## PathAvoidance being a separate file for movement's own subsystem
## rather than that logic living directly in unit.gd.

## Relayed by Unit as status_applied/status_removed/status_ticked (see
## Unit._ready) — same forwarding convention as UnitActionState.became_idle
## and UnitSelection's four signals, not fired directly by anything
## outside this file. unit_vfx.gd/unit_sfx.gd connect to Unit's relayed
## versions to play StatusEffect.apply_vfx/tick_vfx/remove_vfx and
## apply_sfx/tick_sfx/remove_sfx — this class has no VFX/SFX knowledge of
## its own, same separation as everywhere else in the project.
signal status_applied(effect: StatusEffect, active_status: ActiveStatus)
signal status_removed(effect: StatusEffect)
signal status_ticked(effect: StatusEffect, active_status: ActiveStatus)

var _owner: Unit
var active: Array[ActiveStatus] = []
## Above 0 while apply/remove/load_state are partway through a status —
## listed but its modifiers not all on, or the reverse. A stat change
## from one of those modifiers can set off a rule that reads statuses
## (Unit._update_low_pool_statuses); it waits on this, and runs again
## once the change is whole.
var busy: int = 0


func _init(owner: Unit) -> void:
	_owner = owner


## Statuses as data: which effect, how long left, how many stacks.
##
## The effect itself is a shared Resource, so it is referenced by path
## rather than written out — what is per-unit is only the remaining
## duration and the stack count (see ActiveStatus, which exists to draw
## exactly that line).
func save_state() -> Array:
	var out: Array = []
	for status in active:
		if status.effect == null or status.effect.resource_path.is_empty():
			# An effect built at runtime with no path cannot be found again.
			continue
		out.append({
			"effect": status.effect.resource_path,
			"turns": status.turns_remaining,
			"stacks": status.stacks,
			"stopped": status.stopped,
			"tally": status.tally.duplicate(),
		})
	return out


## Rebuilds `active` directly rather than replaying apply(), because
## these statuses are not being APPLIED — they are being remembered.
## apply() would reset each duration to the effect's default and fire
## whatever an application is supposed to announce. Stat modifiers are
## the exception: they live on the unit's stats, not here, so they are
## taken off with the old list and put back with the new one.
func load_state(state: Array) -> void:
	busy += 1
	for status in active:
		_set_stat_modifiers(status.effect, false)
	active.clear()
	for entry in state:
		var effect: StatusEffect = load(entry.get("effect", ""))
		if effect == null:
			continue
		var status := ActiveStatus.new(effect, int(entry.get("turns", 0)))
		status.stacks = int(entry.get("stacks", 1))
		status.stopped = bool(entry.get("stopped", false))
		status.tally = entry.get("tally", {}).duplicate()
		active.append(status)
		_set_stat_modifiers(effect, true)
	busy -= 1


func _set_stat_modifiers(effect: StatusEffect, on: bool) -> void:
	for behavior in effect.behaviors:
		if behavior is StatModifierBehavior:
			if on:
				_owner.register_stat_modifier(behavior, effect.status_name)
			else:
				_owner.unregister_stat_modifier(behavior, effect.status_name)


func apply(effect: StatusEffect) -> void:
	var existing: ActiveStatus = _find(effect)

	if existing:
		match effect.stack_mode:
			StatusEffect.StackMode.IGNORE:
				return
			StatusEffect.StackMode.REFRESH:
				existing.turns_remaining = effect.default_duration
				return
			StatusEffect.StackMode.STACK:
				existing.stacks = min(existing.stacks + 1, effect.max_stacks)
				existing.turns_remaining = effect.default_duration
				return

	var new_active := ActiveStatus.new(effect, effect.default_duration)
	busy += 1
	active.append(new_active)
	for behavior in effect.behaviors:
		behavior.on_apply(_owner, new_active)
		if behavior is StatModifierBehavior:
			_owner.register_stat_modifier(behavior, effect.status_name)
	busy -= 1
	status_applied.emit(effect, new_active)


## voluntary defaults false — "this removal wasn't the unit's own
## deliberate choice." Only LandEffect (a player-chosen Land action)
## passes true; natural expiry (tick_turn_start below) and
## Unit.ground_if_flying() (Incapacitate forcing a flyer down) both fall
## through to the default, which is exactly right for both: neither is
## a choice the unit made. See ForceLandOnExpireBehavior for the one
## behavior that actually reads this — fall damage only applies when
## false.
func remove(effect: StatusEffect, voluntary: bool = false) -> void:
	var existing: ActiveStatus = _find(effect)
	if not existing:
		return
	busy += 1
	active.erase(existing)
	for behavior in effect.behaviors:
		behavior.on_remove(_owner, existing, voluntary)
		if behavior is StatModifierBehavior:
			_owner.unregister_stat_modifier(behavior, effect.status_name)
	busy -= 1
	status_removed.emit(effect)


func has(effect: StatusEffect) -> bool:
	return _find(effect) != null


func turns_remaining(effect: StatusEffect) -> int:
	var existing: ActiveStatus = _find(effect)
	return existing.turns_remaining if existing else 0


## The live tally, for a caller to read or change — empty when the
## status isn't active.
func tally(effect: StatusEffect) -> Dictionary:
	var existing: ActiveStatus = _find(effect)
	return existing.tally if existing else {}


func _find(effect: StatusEffect) -> ActiveStatus:
	for a in active:
		if a.effect == effect:
			return a
	return null


## Called once at the start of this unit's own turn. Fires on_turn_start
## on every active status FIRST, then ticks duration down and removes
## anything that expires — in that order, so a status still delivers its
## final tick (one last Bleeding hit, say) on the turn it runs out,
## rather than silently skipping it.
func tick_turn_start() -> void:
	for a in active.duplicate():
		for behavior in a.effect.behaviors:
			behavior.on_turn_start(_owner, a)
		status_ticked.emit(a.effect, a)

		if a.stopped:
			continue
		a.turns_remaining -= 1
		if a.turns_remaining <= 0:
			remove(a.effect)


## Whether ANY active status wants to prevent this unit from acting at
## all this turn — checked by Unit.move_to()/use_ability() directly, not
## just advisory.
func prevents_turn() -> bool:
	for a in active:
		for behavior in a.effect.behaviors:
			if behavior.prevents_turn():
				return true
	return false


## Notifies every active status's behaviors that this unit took damage —
## lets e.g. RemoveOnDamageBehavior react (waking from Sleep).
func notify_damage_taken(amount: int, critical: bool = false) -> void:
	for a in active.duplicate():
		for behavior in a.effect.behaviors:
			behavior.on_damage_taken(_owner, amount, a, critical)


## Whether ANY active status grants this unit flight right now — see
## StatusBehavior.grants_flight(). Checked by Unit.is_flying(), which
## UnitMovement.move_to() uses to pick ground vs air navigation.
func grants_flight() -> bool:
	for a in active:
		for behavior in a.effect.behaviors:
			if behavior.grants_flight():
				return true
	return false


## Every currently active StatusEffect that's granting this unit flight
## right now — see Unit.ground_if_flying(), which removes each of these
## to force a fall (e.g. getting Incapacitated mid-air). Plural: nothing
## currently applies more than one flight-granting status to the same
## unit at once, but nothing stops it either, so this doesn't assume
## there's only ever one.
func flight_granting_effects() -> Array[StatusEffect]:
	var result: Array[StatusEffect] = []
	for a in active:
		for behavior in a.effect.behaviors:
			if behavior.grants_flight():
				result.append(a.effect)
				break
	return result


## Sum of every active status's modifier to an incoming attack's to-hit
## target number, from this unit being the DEFENDER — see
## StatusBehavior.modify_incoming_attack_to_hit.
func incoming_attack_to_hit_modifier(attacker: Unit, ability: Ability) -> int:
	var total: int = 0
	for a in active:
		for behavior in a.effect.behaviors:
			total += behavior.modify_incoming_attack_to_hit(_owner, attacker, ability)
	return total


## Sum of every active status's modifier to an OUTGOING attack's to-hit
## target number, from this unit being the ATTACKER — see
## StatusBehavior.modify_outgoing_attack_to_hit.
func outgoing_attack_to_hit_modifier(target, ability: Ability) -> int:
	var total: int = 0
	for a in active:
		for behavior in a.effect.behaviors:
			total += behavior.modify_outgoing_attack_to_hit(_owner, target, ability)
	return total
