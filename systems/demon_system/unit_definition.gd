class_name UnitDefinition
extends Resource
## The shared, stateless TEMPLATE for one kind of unit — "what a Goblin
## Rogue is" or "what a Pixie is," not any specific placed/owned instance
## (see OwnedDemon for a roster entry, Unit.definition for the cascading
## setter that applies this onto a live instance). Every unit sharing a
## definition points back at the same UnitDefinition; nothing here ever
## changes per-instance.
##
## Originally demon-specific (DemonSpecies); every hostile unit is now
## treated as conceptually a demon in this game's fiction, and at the
## intended scale (200+ demons) hand-authoring a unique 3D scene per
## unit was never realistic — units share a small set of generic bodies
## (unit_scene) and are differentiated entirely through this resource
## instead. OwnedDemon/DemonRoster/DemonDatabase/the fusion system keep
## their own names — roster-tracking and fusion are still a real
## mechanical subset, not something every unit participates in, even
## though every unit now gets a definition.
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
##
## Every field below that Unit also carries defaults to EXACTLY the same
## value Unit's own script declares — see Unit.definition's setter. That
## makes leaving a field unauthored here a true no-op (a unit cascades
## the same value it would have had anyway), not an accidental zero-out.

@export var id: String = ""
@export var display_name: String = ""

@export var strength: int = 10
@export var dexterity: int = 10
@export var intelligence: int = 10
@export var health: int = 10
@export var move: int = 5
@export var will: int = 10
@export var perception: int = 10

@export var max_hp: int = 10
@export var max_fp: int = 0

@export var faction: StringName = &"player"

@export var order: StringName = &""
@export var rank: int = 1
## True means this species can never be a fusion RESULT — obtainable
## only via negotiation/story, standard "boss/unique demon" exemption.
## Can still be a fusion INPUT.
@export var is_special: bool = false

@export var portrait_texture: Texture2D
## A Unit-derived scene — almost always the one shared, generic
## res://unit.tscn (see this file's own header); kept as a field rather
## than hardcoded so a distinct body archetype remains possible later
## without another schema change.
@export var unit_scene: PackedScene
@export var abilities: Array[Ability] = []
@export var ai_behaviors: Array[AiBehavior] = []

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
