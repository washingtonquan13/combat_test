class_name AbilityAction
extends RefCounted
## One use of an ability, decided before anyone sees it. UnitCombat
## rolls everything first (to-hit, defense, each effect's dice — see
## AbilityEffect.resolve), then hands this to presentation: the animator,
## VFX and SFX read it off Unit.current_action when ability_use_started
## fires and only show what it says. Nothing they do can change it.
##
## The rules wait on presentation in exactly one place: an ability with
## AbilityTiming.waits_for_impact holds its effects until impact() —
## an animation's Call Method Track or an ImpactSignalStep, both through
## Unit.notify_impact(). wait_for_impact() always comes back, by impact
## or by timeout, so a missing or interrupted animation makes an attack
## late, never stuck.

## Fired once, on the first impact() — later calls are ignored.
signal impacted()
## Fired once, when the action's effects have applied (or it missed) and
## ability_used has gone out.
signal finished()

static var _next_id: int = 1

## Unique per use, for telling one swing's events from the next.
var id: int
var attacker: Unit
## A Unit, or a Vector3 for ground/area abilities.
var target
var ability: Ability
## The same dictionary ability_used carries — hit, to_hit, defense, hits.
var result: Dictionary
var hit: bool = false
var is_critical: bool = false
## One entry per ability.effects, from that effect's resolve(): the
## rolled dice and the injury they will do, before any of it lands.
var plans: Array[Dictionary] = []

var _impacted: bool = false
var _finished: bool = false


func _init(p_attacker: Unit, p_target, p_ability: Ability, p_result: Dictionary) -> void:
	id = _next_id
	_next_id += 1
	attacker = p_attacker
	target = p_target
	ability = p_ability
	result = p_result


## The injury this action will do once it lands, summed over every plan.
func planned_damage() -> int:
	var total: int = 0
	for plan in plans:
		total += plan.get("damage", 0)
	return total


## Returns true for the call that counts, false for a repeat.
func impact() -> bool:
	if _impacted or _finished:
		return false
	_impacted = true
	impacted.emit()
	return true


## Waits for impact(), or `timeout` seconds. Already impacted (a VFX
## sequence that signals on its first step does it inside
## ability_use_started) returns at once.
func wait_for_impact(tree: SceneTree, timeout: float) -> void:
	if _impacted:
		return
	tree.create_timer(timeout).timeout.connect(_on_timeout)
	await impacted


## Flagged before impact(): the waiting use_ability resumes inside it.
func _on_timeout() -> void:
	if _impacted or _finished:
		return
	result["impact_timed_out"] = true
	impact()


func finish() -> void:
	if _finished:
		return
	_impacted = true
	_finished = true
	finished.emit()


func is_finished() -> bool:
	return _finished
