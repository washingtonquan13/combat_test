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

## Fired on each shot's impact(), up to `shots` — later calls are
## ignored.
signal impacted()
## Fired as each shot leaves — even after finished, since a missed shot
## still has to fly.
signal released()
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
## Shots this use fires: rapid fire's rounds (UnitCombat._decide), else
## one. Each is released and impacts on its own — a clip with one
## release key per shot, a projectile per release — and the hits among
## them land one per impact, in order.
var shots: int = 1

var _released_shots: int = 0
var _impacts: int = 0
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


## Lets the first shot go. Returns true for the call that counts, false
## for a repeat.
func release() -> bool:
	if _released_shots > 0:
		return false
	return release_next()


## Lets the next shot go: a release key in the clip. Returns false once
## every shot is out.
func release_next() -> bool:
	if _released_shots >= shots:
		return false
	_released_shots += 1
	released.emit()
	if is_instance_valid(attacker):
		attacker.cast_released.emit(self)
	return true


## Lets every shot still held go at once: the clip ran out of release
## keys, or was cut short.
func release_all() -> void:
	while release_next():
		pass


func is_released() -> bool:
	return _released_shots > 0


## The safety net for a caster nothing animates: release_all() anyway
## after `seconds`. UnitCombat starts it on every use.
func release_after(tree: SceneTree, seconds: float) -> void:
	tree.create_timer(seconds).timeout.connect(_releaser(self))


## The timer has to keep the action alive until then — nothing else may
## hold it — and a Callable to its own method would not; a static
## lambda's capture does.
static func _releaser(action: AbilityAction) -> Callable:
	return func(): action.release_all()


## The next shot arrives, released first if it wasn't. Returns true for
## a call that counts, false past the last shot.
func impact() -> bool:
	if _finished or _impacts >= shots:
		return false
	if _released_shots <= _impacts:
		release_next()
	_impacts += 1
	impacted.emit()
	return true


## Waits for the `nth` shot's impact(), or `timeout` seconds after that
## shot's release — the wind-up isn't flight time. Already there returns
## at once.
func wait_for_impact(tree: SceneTree, timeout: float, nth: int = 1) -> void:
	while _released_shots < nth and _impacts < nth:
		await released
	if _impacts >= nth:
		return
	tree.create_timer(timeout).timeout.connect(_timeout_for(self, nth))
	while _impacts < nth:
		await impacted


## Same reason as _releaser.
static func _timeout_for(action: AbilityAction, nth: int) -> Callable:
	return func(): action._on_timeout(nth)


## Flagged before impact(): the waiting use_ability resumes inside it.
func _on_timeout(nth: int) -> void:
	if _finished or _impacts >= nth:
		return
	result["impact_timed_out"] = true
	while _impacts < nth and impact():
		pass


func finish() -> void:
	if _finished:
		return
	_finished = true
	finished.emit()


func is_finished() -> bool:
	return _finished
