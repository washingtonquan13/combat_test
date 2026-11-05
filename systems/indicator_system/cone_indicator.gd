class_name ConeIndicator
extends IndicatorBase
## Cone ability preview (ConeTargeting, Fire Breath): the cone's volume as
## an AoeShell, apex at the caster's chest, turned toward the aim and
## pitched by a Ctrl height drag. Its cut line is where the breath washes
## over the floor and walls. No aim line: a cone always fires, so there
## is no reach to colour. Units it would catch are outlined.
##
## Scene setup: attach to a Node3D under Indicators in the main scene.

## Not an answer colour, same as the area shell: it says how big the cone
## is, never whether the cast is allowed.
@export var shell_color: Color = IndicatorPalette.AOE

var _shell: AoeShell


func serves() -> StringName:
	return &"cone"


func _ready() -> void:
	super()
	_shell = AoeShell.new()
	add_child(_shell)
	_owned_meshes.append(_shell)
	_shell.set_tint(shell_color)


func draw(aim: Aim) -> void:
	var unit: Unit = aim.caster
	var ability: Ability = aim.ability
	var targeting: ConeTargeting = ability.targeting as ConeTargeting if ability else null
	if not unit or not targeting or aim.point == null:
		hide_visuals()
		return
	var point: Vector3 = aim.point
	_shell.show_cone(targeting.origin(unit), targeting.direction(unit, point), targeting.length, targeting.half_angle())
	_outline_caught(unit, ability, point)
