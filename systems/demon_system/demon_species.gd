class_name DemonSpecies
extends Resource
## The shared, stateless TEMPLATE for one kind of demon — "what a Pixie
## is," not any specific owned Pixie (see OwnedDemon for that). Every
## OwnedDemon of this species points back at the same DemonSpecies
## instance; nothing here ever changes per-instance.
##
## order is the fusion lookup key (Order A + Order B -> Order C, see
## FusionChart) — a bare StringName tag, not a dedicated Resource type,
## same reasoning Unit.faction stays a bare tag: there's no per-Order
## behavior to plug in, just a grouping label.
##
## rank is this species' position within its own order's ordering —
## FusionCalculator picks whichever species in the result order has the
## rank closest to the fused average, same "next demon up/down" idea
## classic Megaten fusion charts use in place of a level system this
## project doesn't have.
##
## max_hp/max_fp are authored here explicitly rather than read off
## unit_scene at runtime, so OwnedDemon never needs to instantiate a
## scene just to know a fresh recruit's starting stats.

@export var species_id: String = ""
@export var species_name: String = ""
@export var order: StringName = &""
@export var rank: int = 1
## True means this species can never be a fusion RESULT — obtainable
## only via negotiation/story, standard "boss/unique demon" exemption.
## Can still be a fusion INPUT.
@export var is_special: bool = false
@export var portrait_texture: Texture2D
## A Unit-derived scene, exactly the same convention SummonEffect.
## summon_scene and the existing scenes/units/sylph.tscn already use.
@export var unit_scene: PackedScene
@export var max_hp: int = 10
@export var max_fp: int = 0
## Candidate entry points into this species' negotiation conversation —
## exact mirror of Unit.dialogue_options/resolve_dialogue_root(), same
## reasoning: a species that's only ever obtained through fusion (never
## encountered wild) can leave this empty, and one that IS negotiable
## can vary its opening depending on state (first encounter vs. already
## fought once, say) without needing a different mechanism than NPCs
## already use for the same problem.
@export var negotiation_options: Array[DialogueRootOption] = []


## First negotiation_options entry whose prerequisite is satisfied (or
## has none), null if nothing currently applies — see
## Unit.resolve_dialogue_root(), the pattern this mirrors exactly.
func resolve_negotiation_root(actor: Unit) -> DialogueNode:
	for option in negotiation_options:
		if not option.prerequisite or option.prerequisite.is_satisfied(actor):
			return option.root
	return null
