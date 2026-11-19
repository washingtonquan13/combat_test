class_name EncounterGroup
extends Resource
## One line of a district's encounter table: who you fight when its red
## avatar catches you. Owned by the overworld (see
## docs/systems/areas_bootstrap.md, "Random encounters").

## Everyone in the fight, one entry per body: list a definition twice for
## two of them.
@export var units: Array[UnitDefinition] = []
## How often this line is picked against the others in the same table.
@export var weight: float = 1.0
