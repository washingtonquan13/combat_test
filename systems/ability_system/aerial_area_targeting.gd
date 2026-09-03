class_name AerialAreaTargeting
extends AreaTargeting
## AreaTargeting for abilities whose blast center can be aimed anywhere
## in 3D space, not just on the ground — Explosive Fireball, or any
## future ability where "the AoE floats in midair" is physically
## sensible (an explosion, a burst of energy). Plain AreaTargeting stays
## the floor-only default — Grease, which spawns a ground-hugging
## Surface (see SpawnSurfaceEffect/Surface, detection_height=0.05 on
## grease.tres's own Surface sub-resource), can only logically sit ON
## the floor, never airborne, and neither can anything else shaped like
## it. The two are genuinely different SHAPES of area ability, not one
## ability with a toggle — same reasoning every other targeting split in
## this project follows (MeleeEnemyTargeting vs RangedEnemyTargeting,
## GroundPointTargeting vs AreaTargeting, ...).
##
## Carries no fields of its own — max_range/radius/LoS are all identical
## to AreaTargeting, inherited unchanged. Exists purely as a
## distinguishable TYPE: aerial_area_indicator.gd (Ctrl-drag height +
## wireframe-sphere preview) dispatches on this specific subclass via
## is_instance_of/is, rather than AreaTargeting generally — and
## area_indicator.gd explicitly EXCLUDES it (see that file), so exactly
## one of the two indicators ever shows for a given armed ability.
## ground_click_target.gd no longer needs a type-check of its own for
## this: resolve_target_point() below (see AbilityTargeting) applies the
## same Ctrl-dragged height polymorphically instead.


## Lifts the raw ground-click point to the Ctrl-dragged height the
## player aimed at, if any — click_position is always exactly where the
## physics ray hit the ground (see ground_click_target.gd), so it can
## never carry a lifted height on its own. AbilityManager.
## aim_height_override holds the same value aerial_area_indicator.gd's
## own preview was already showing, so the confirmed cast can't disagree
## with what the player saw.
func resolve_target_point(click_position: Vector3) -> Vector3:
	if AbilityManager.has_aim_height_override:
		click_position.y = AbilityManager.aim_height_override
	return click_position


## The three-ring aerial overlay REPLACES the flat one it would otherwise
## inherit from AreaTargeting — an aerial blast is aimed in the air, and
## drawing the floor ring under it as well says the wrong thing about
## where it lands.
func indicator_ids() -> Array[StringName]:
	return [&"aerial_area"]
