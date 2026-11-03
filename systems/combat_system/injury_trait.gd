@tool
class_name InjuryTrait
extends Resource
## A named change to how a body takes injury: GURPS Injury Tolerance
## (B380) and anything like it, such as Unliving, Diffuse, Reinforced
## Vitals or a fireproof cloak. A unit gets them from its definition, its
## worn gear and its statuses (Unit.injury_profile).

@export var display_name: String = ""
## One line for the examine tooltip.
@export var summary: String = ""
@export var rules: Array[InjuryRule] = []
