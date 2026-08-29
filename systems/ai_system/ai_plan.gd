class_name AiPlan
extends RefCounted
## One scored candidate action, produced either by AiScorer's own
## enumeration (see that file) or by an authored AiBehavior.propose() —
## both feed the same pool, so an authored preference and the scorer's
## own arithmetic compete on equal footing (see AiBehavior's own header
## for why this replaced the old first-match-wins resolve() contract).
##
## Wider than the {ability, target} dictionary this replaces: a plan can
## also express WHERE to stand and at what altitude BEFORE acting, which
## a flight behavior (see systems/ai_system's Swoop/MaintainAltitude/...)
## genuinely needs to say and the old shape had no room for.

var ability: Ability
## A Unit for a unit-targeted ability, a Vector3 for a point-targeted one
## — same "type depends on targeting" convention Ability.is_in_range and
## AbilityEffect.apply already use.
var target = null

## Where to move before acting, if anywhere. has_destination false (the
## default) means "let CombatAI's existing _standoff_goal() figure it
## out," i.e. exactly today's behavior — most plans never need to set
## this explicitly.
var destination: Vector3 = Vector3.ZERO
var has_destination: bool = false

## Set unit.flight_target_altitude to this before moving, if not NAN.
## Only meaningful alongside has_destination — a plan that doesn't move
## has no reason to change altitude first.
var flight_altitude: float = NAN

## True for a plan that only ever moves and never intends to actually use
## `ability` this turn (a Flee — see FleeBehavior) — `ability` on such a
## plan is a formality to satisfy AiPlan's own non-null contract, not a
## real cast. AiScorer skips both the ability-economy hard preconditions
## and its own damage/heal scoring for a plan marked this way (see
## AiScorer._prepare_plan): those checks exist to answer "can/should this
## ability actually be used," which is simply the wrong question for a
## plan that was never going to use one. Set via mark_pure_reposition(),
## never directly — see that method.
var pure_reposition: bool = false

var score: float = 0.0
## Short label for the combat log / debug overlay — "expected kill",
## "swoop attack", "flee, low FP" — not shown to the player today, but
## cheap to carry and useful the first time this needs debugging.
var reason: String = ""


func _init(p_ability: Ability = null, p_target = null) -> void:
	ability = p_ability
	target = p_target


func with_destination(p_destination: Vector3, p_flight_altitude: float = NAN) -> AiPlan:
	destination = p_destination
	has_destination = true
	flight_altitude = p_flight_altitude
	return self


func with_score(p_score: float, p_reason: String = "") -> AiPlan:
	score = p_score
	reason = p_reason
	return self


func mark_pure_reposition() -> AiPlan:
	pure_reposition = true
	return self
