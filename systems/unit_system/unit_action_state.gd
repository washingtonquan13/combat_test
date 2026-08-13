class_name UnitActionState
extends RefCounted
## Owns the per-turn action economy for ONE unit — move budget, the
## once-per-turn attack flag, and busy-tracking (is anything currently
## in flight: movement, or an async ability effect like Jump's arc).
## Owned by that Unit (see Unit._action_state), same pattern as
## StatusManager: Unit exposes a small set of forwarding
## properties/methods (move_remaining, has_attacked, is_busy(),
## can_act(), etc.) that just delegate here, so nothing outside Unit
## needs to know this component exists at all — every existing caller
## keeps reading/writing unit.move_remaining, calling unit.is_busy(),
## etc. exactly as before.
##
## is_busy()/can_act() intentionally query _owner.is_moving() and
## _owner.status_prevents_turn() rather than owning movement or status
## state themselves — those live in Unit (movement, for now) and
## StatusManager (status) respectively. This component only owns the
## action-ECONOMY bookkeeping; it composes the OTHER subsystems' current
## state into its own is_busy()/can_act() answers rather than duplicating
## what they already know. That composition-over-ownership is also what
## keeps this safe to build before Unit's movement code has been
## extracted into its own component too — this only ever asks Unit
## through its stable public is_moving() method, never reaches into
## Unit's internals directly, so it doesn't care when or whether that
## extraction happens later.

signal became_idle()

var move_remaining: float = 0.0
var has_attacked: bool = false

var _owner: Unit
var _busy_count: int = 0


func _init(owner: Unit) -> void:
	_owner = owner


## Called by CombatManager when this unit's turn begins. Refills the
## move budget from `move` and clears the attack flag.
func reset_turn_actions(move_stat: float) -> void:
	move_remaining = move_stat
	has_attacked = false


## Whether this unit has anything currently in flight — movement (asked
## of the owner directly, see this file's header), or any async ability
## effect that's bracketed itself with begin_busy().
func is_busy() -> bool:
	return _owner.is_moving() or _busy_count > 0


## Call when starting an async action (an ability's animation, etc.)
## that CombatManager should wait for before letting the turn end. Must
## be paired with a later end_busy() call once that action finishes.
func begin_busy() -> void:
	_busy_count += 1


func end_busy() -> void:
	_busy_count = max(_busy_count - 1, 0)
	check_idle()


## Public (not a private _check_idle) since movement code outside this
## component — currently still living directly in Unit — needs to call
## this whenever _moving flips to false, since that's a change in
## is_busy()'s answer this component has no other way to learn about
## (is_moving() is polled, not pushed).
func check_idle() -> void:
	if not is_busy():
		became_idle.emit()


## Whether this unit is currently free to take a NEW action at all — not
## busy, and not prevented by an active status effect. Queries the
## owner's status_prevents_turn() the same composition-over-ownership
## way is_busy() queries is_moving() — see this file's header.
func can_act() -> bool:
	return not is_busy() and not _owner.status_prevents_turn()


## Whether `distance` could be covered without exceeding the remaining
## budget.
func can_move(distance: float) -> bool:
	return distance <= move_remaining + 0.001


## Deducts distance already moved from the remaining budget this turn.
## Clamped so overshoot (e.g. rounding) can't push it negative.
func spend_move(distance: float) -> void:
	move_remaining = max(move_remaining - distance, 0.0)


func has_move_remaining() -> bool:
	return move_remaining > 0.0
