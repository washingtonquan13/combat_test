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
## wireframe-sphere preview) and ground_click_target.gd (whether a
## click's height gets overridden) both dispatch on this specific
## subclass via is_instance_of/is, rather than AreaTargeting generally —
## and area_indicator.gd explicitly EXCLUDES it (see that file), so
## exactly one of the two indicators ever shows for a given armed
## ability.
