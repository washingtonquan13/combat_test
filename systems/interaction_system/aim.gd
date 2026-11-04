class_name Aim
extends RefCounted
## What the player is aiming at this frame: the Cursor, read against the
## acting unit and the intent's ability. Built once per frame by
## ClickRouter, after the intent has applied any height drag, and handed
## to every live indicator's draw() - so no indicator re-derives the
## caster, the armed ability, the lifted point or the hovered hostile on
## its own.

var cursor: Cursor = null

## The unit being commanded (ClickRouter.active_unit), or null - in which
## case there is nothing to preview.
var caster: Unit = null

## The ability being aimed, or null while idle.
var ability: Ability = null

## The cursor's ground point as the armed ability would take it (see
## AbilityTargeting.resolve_target_point - lifted to the dragged height
## for the shapes that take one), or the bare ground point while idle.
## Null when the ray missed the ground.
var point = null

## cursor.unit when it is alive and hostile to the caster, else null.
var hostile: Unit = null


static func build(from: Cursor, intent: PlayerIntent) -> Aim:
	var aim := Aim.new()
	aim.cursor = from
	aim.caster = ClickRouter.active_unit()
	aim.ability = intent.ability if intent else null
	aim.point = from.ground
	if from.ground != null and aim.ability and aim.ability.targeting:
		aim.point = aim.ability.targeting.resolve_target_point(from.ground)
	if aim.caster and from.unit and from.unit.is_alive() and aim.caster.is_hostile_to(from.unit):
		aim.hostile = from.unit
	return aim
