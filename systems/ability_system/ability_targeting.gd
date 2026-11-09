class_name AbilityTargeting
extends Resource
## Base class for "how does this ability pick/validate a target." One
## subclass per targeting SHAPE (melee enemy, ranged enemy with line of
## sight, ground point, area — see GroundPointTargeting, AreaTargeting)
## — each carrying only the fields that shape actually needs, instead of
## every targeting rule's fields living together on one shared Ability
## resource where most of them go unused by any given instance.

## Whether target is a legal target for this ability from attacker's
## current position — geometry/range/LoS only. target's type depends on
## the subclass: a Unit for enemy-targeting subclasses, a Vector3 for
## point-targeting ones. Callers are expected to have already checked
## things like hostility/faction before calling this; it only answers
## "is this within range," not "is this an appropriate thing to target
## at all." Override in each subclass.
func is_valid_target(_attacker: Unit, _target) -> bool:
	return false


## Why a target can or cannot be aimed at, for the previews that colour
## the difference. OK is exactly is_valid_target() saying yes.
## BLOCKED is line of sight; PATH_BLOCKED is something in the way of a
## flight there (ArcFlight.clear_fraction).
enum Reach { OK, OUT_OF_RANGE, BLOCKED, INVALID, PATH_BLOCKED }


## The ONE range/line-of-sight rule for this shape: is_valid_target() is
## `check() == Reach.OK` on every shape that overrides this, and every
## indicator colours itself from it rather than re-deriving "too far" and
## "blocked" on its own. Before this the area, line, line-of-sight and
## seeking indicators each carried their own copy of the rule beside the
## one the cast used, and a copy that drifted showed a green line for a
## cast that was then refused. Default: OK or INVALID, from
## is_valid_target().
func check(attacker: Unit, target) -> Reach:
	return Reach.OK if is_valid_target(attacker, target) else Reach.INVALID


## What a ground click at click_position would get: check() on the target
## resolve_click() would build from it. ClickRouter reads this to answer
## a point click before it is made (the context cursor, the refusal
## feedback), so it has to follow resolve_click's own steps - which is
## why it lives here beside it rather than in the router. Default: the
## point as resolve_target_point() adjusts it.
func check_click(attacker: Unit, click_position: Vector3) -> Reach:
	return check(attacker, resolve_target_point(click_position))


## Whether this shape can be aimed above the ground with a Ctrl height
## drag (see AbilityManager.aim_height_override, which
## resolve_target_point() reads). The router asks this before it holds
## the ground point for a drag, so a shape that would ignore the height
## never freezes the cursor.
func takes_aim_height() -> bool:
	return false


## Whether the caster flies to the point on a curve the player may raise
## or lower (GroundPointTargeting.chosen_arc). The point stays on the
## floor, so this is a separate question from takes_aim_height.
func takes_arc_height() -> bool:
	return false


## Whether attacker has ANY legal target for this ability at all right
## now, regardless of where the player is currently aiming — used to
## disable a hotbar slot outright rather than leaving it clickable for
## an ability that couldn't possibly resolve (see hotbar_slot.gd's
## refresh_state). True on every existing subclass by default, since
## most targeting shapes (melee/ranged enemy, ground point) can always
## find SOME legal point/target in the abstract; override where that
## isn't true — see DismissTargeting, the first case where it matters.
func has_any_valid_target(_attacker: Unit) -> bool:
	return true


## Whether this ability expects to be aimed at a UNIT ON THE SAME FACTION
## rather than a hostile one — a heal, a buff. Read by UnitCombat.
## resolve_click_ability (see ClickRouter.click_unit, the one caller)
## to decide whether clicking a friendly unit should cast this ability at
## them instead of just selecting them (the default, and the only
## behavior before this field existed). Lives here rather than as a
## separate MeleeAllyTargeting/RangedAllyTargeting subclass pair because
## MeleeEnemyTargeting/RangedEnemyTargeting's own is_valid_target was
## ALREADY hostility-agnostic (pure geometry — see their own doc
## comments) — the "Enemy" in their names describes the historical
## default use, not an actual constraint the class enforces, so a single
## flag here reuses the exact same range/LoS logic for an ally-facing
## ability instead of duplicating it. Meaningless for point/area
## targeting (GroundPointTargeting, AreaTargeting) since those don't
## target a Unit at all — left false and unused there.
@export var requires_ally: bool = false
## Whether a click on ANY unit casts this ability at them - the caster
## itself, an ally, an enemy - rather than selecting a friendly one.
## Enlarge and Reduce Person: a buff on a friend, a curse on a foe. Beats
## requires_ally when both are set. Same Unit-target-only scope.
@export var any_unit: bool = false
## Whether this unit-targeted ability may also be used on the ground: a
## click on bare ground (no unit under the cursor) swings or shoots at
## that spot, as BG3 lets a Fire Bolt, a sword or a bow go off at no
## one. Nothing is there to hit, so it always lands (no to-hit roll),
## and an attack of an element (Ability.element) still makes the ground
## react (SurfaceManager.touch): Fire Bolt lights grease, Ray of Frost
## freezes water. Attacks only: a heal or a buff has nothing to do on
## the floor. Range (and line of sight) are this shape's own, measured
## to the point.
@export var aims_at_ground: bool = false


func requires_ally_target() -> bool:
	return requires_ally


## Whether a click on the ground is used by this ability: a point/area
## shape always, a unit-targeted one with aims_at_ground on. The one
## question the click router, the aiming intent and the context cursor
## ask, so none of them keeps its own copy.
func takes_ground_click() -> bool:
	return expects_point_target() or aims_at_ground


## Whether this targeting shape's target is a single hostile Unit — true
## for exactly MeleeEnemyTargeting/RangedEnemyTargeting, the two shapes
## AiScorer's baseline "attack nearest hostile" enumeration considers a
## candidate (see AiScorer._damaging_abilities) and the only two whose
## target is even the right TYPE to score against a hostile unit at all
## (GroundPointTargeting/AreaTargeting target a Vector3; SelfTargeting
## and DismissTargeting don't target an enemy). Named for what the check
## actually selects, not "is offensive" — requires_ally could just as
## well be false on a point-targeting utility ability, and this says
## nothing about damage (see _damaging_abilities' separate
## expected_damage filter for that). Override to true in each subclass.
func targets_single_enemy() -> bool:
	return false


## Whether this targeting shape needs no click at all — the target is
## already fully known the instant the ability is armed (see
## SelfTargeting). Every other shape waits for further input (a unit
## click, a ground click); this is the one case where arming and using
## should be the same action. Checked by ability_hotbar.gd before it
## arms-and-waits — a polymorphic query for the same reason
## expects_point_target() is one rather than a growing "is SelfTargeting
## or is X or..." chain at each call site.
func resolves_immediately() -> bool:
	return false


## Whether this targeting subclass expects a Vector3 (ground point) as
## its target rather than a Unit. Used by ground_click_target.gd to
## decide whether a ground click should route to ability use instead of
## the normal deselect/move behavior — a polymorphic query rather than a
## growing "is GroundPointTargeting or is AreaTargeting or ..." chain
## that would need editing every time a new point-targeting subclass is
## added. Override to true in each point-targeting subclass.
func expects_point_target() -> bool:
	return false


## Adjusts a raw click point into the actual point an ability should be
## used at — called by ground_click_target.gd right before use_ability(),
## on every point-targeting ability regardless of subclass, and by
## Aim.build for the preview, so both land on the same point. Default is a
## no-op passthrough; override where a targeting shape needs to
## transform the raw click before use — see AerialAreaTargeting, which
## lifts it to a Ctrl-dragged height. Keeps the click router itself
## ignorant of which concrete subclasses need this adjustment, rather
## than a growing "is AerialAreaTargeting or is X or ..." chain there.
func resolve_target_point(click_position: Vector3) -> Vector3:
	return click_position


## What a ground click aims the ability at: the target to use it on, or
## null when the click was taken but there's nothing to cast yet — the
## first of LineTargeting's two clicks. Default: the click's point, as
## resolve_target_point() adjusts it.
func resolve_click(_attacker: Unit, click_position: Vector3) -> Variant:
	return resolve_target_point(click_position)


## Who an area-shaped cast aimed at target catches, gated by side: the
## one scan the area effects, the previews' outlines and the AI all ask,
## so none of them keeps its own copy of the shape. Default: no one (a
## shape that targets a single unit, or none).
func units_caught(_attacker: Unit, _target, _affects_hostiles: bool, _affects_allies: bool) -> Array[Unit]:
	return []


## Distance CombatAI should try to close to before considering a target
## in range — used for movement/standoff purposes (see AiScorer.
## standoff_goal). Override in each subclass; base returns 0 (stand
## right next to target) as a safe default for any targeting kind that
## doesn't override this.
func approach_range() -> float:
	return 0.0


## The preview overlays this targeting shape wants live while an ability
## using it is being aimed — see IndicatorBase.serves() and
## Ability.indicator_ids(), which unions this with the ones implied by
## the ability's own effects.
##
## Declared here, once per shape, instead of five indicators each asking
## "is the armed ability's targeting an instance of MY class" every
## frame. That question had exactly one right answer and five places
## keeping it, which is how area_indicator ended up hand-excluding
## AerialAreaTargeting (a subclass of the one it wants) in a guard of its
## own — that exclusion is now simply an override below.
func indicator_ids() -> Array[StringName]:
	return []


## Human-readable summary for tooltips (see hotbar_slot.gd). Override in
## each subclass.
func describe() -> String:
	return ""
