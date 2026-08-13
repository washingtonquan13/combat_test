class_name SelfTargeting
extends AbilityTargeting
## Targets the caster, always — a stance, a self-heal, a self-buff. No
## click needed at all (see resolves_immediately(), which
## ability_hotbar.gd checks to fire this the instant its slot is pressed
## rather than arming it and waiting for further input the way every
## other targeting shape does).
##
## Always valid — there's no geometry to fail; a unit is always in range
## of itself.

func is_valid_target(_attacker: Unit, _target) -> bool:
	return true


func resolves_immediately() -> bool:
	return true


func describe() -> String:
	return "Self"
