@tool
class_name InjuryPreset
extends Resource
## One way a body takes injury as a whole: a GURPS Injury Tolerance tier
## (B380) such as Unliving, Homogeneous or Diffuse. A unit has at most
## one (Unit.injury_preset); presets are alternatives, never stacked.
## Things that really are separate, like No Vitals, are their own fields
## on the unit (Unit.missing_locations).

@export var display_name: String = ""
## One line for the examine tooltip.
@export var summary: String = ""
## Applied to the plan in list order.
@export var rules: Array[InjuryRule] = []
## Locations this body doesn't have: a hit there resolves as the torso
## (Homogeneous and Diffuse have no vitals or brain).
@export var missing_locations: Array[HitLocation] = []
