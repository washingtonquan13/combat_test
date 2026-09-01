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

## Senses — cascade onto Unit exactly like every other stat here, so a
## blind burrower and a hawk are the same detection code at different
## numbers. Defaults match Unit's own, making an unauthored species a
## true no-op (see this file's own header).
@export var vision_cone_degrees: float = 120.0
@export var max_sight_range: float = 18.0
@export var proximity_radius: float = 2.5

@export var max_hp: int = 10
@export var max_fp: int = 0
@export var damage_reduction: int = 0

@export var faction: StringName = &"player"

@export var order: StringName = &""
@export var rank: int = 1
## Which shared negotiation reaction table this species draws its
## Liked/Neutral/Disliked/Hated responses from (see negotiation_options
## below — each personality type's shared tree lives directly under
## data/negotiation/conversations/, e.g. .../girly/, same level as a
## per-demon folder) — separate axis from order: personality is about
## how a demon REACTS during negotiation, order is about fusion/
## taxonomy. "" for a species with no
## personality-driven negotiation content (negotiable=false, or content
## not yet migrated).
@export var personality: StringName = &""
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
## The BODY this creature wears, adopted by Unit._enter_tree(). Null means
## "keep whatever body unit_scene was authored with", which is what every
## existing demon does — so adding this changed nothing until a definition
## opts in.
##
## Deliberately separate from unit_scene. Varying the look by giving each
## creature its own unit_scene would duplicate the entire component wiring
## — animator, VFX, SFX, skills, equipment, collision — per creature, when
## the only thing that actually differs is the body. One unit, many
## bodies. See CharacterModel.
@export var model_scene: PackedScene
@export var abilities: Array[Ability] = []
## This species' tactical role — see AiArchetype. Supplies the behaviors
## and smartness tier, so a species normally sets this and nothing else
## AI-related.
@export var ai_archetype: AiArchetype
## Behaviors specific to THIS species, on top of whatever ai_archetype
## already provides (see resolved_ai_behaviors) — a boss bolting its own
## quirk onto a stock role, not a replacement for one. Leave empty for
## the common case.
@export var ai_behaviors: Array[AiBehavior] = []
## How many factors CombatAI's scorer weighs when picking this species'
## actions — see AiScorer's own header for the tier table. Cascades onto
## Unit.ai_smartness exactly like every other field here; 2 (Tactical) is
## both this field's default and Unit's own, so an unauthored species
## behaves identically whether or not this line exists in its .tres.
@export var ai_smartness: int = 2

## Whether this species is negotiable BY DEFAULT — cascades onto
## Unit.negotiable (see that field), still overridable per-instance for
## a specific encounter that wants an exception either way. A species
## with no real negotiation content authored (negotiation_options empty)
## being left negotiable=true is harmless — NegotiationManager's own
## guard already requires resolve_negotiation_root() to return something
## before a conversation can start.
@export_group("Character")
## Law/Chaos and the neutral tendency behind it — read by the alignment
## grid, by AlignmentPrerequisite, and by the overworld avatar, whose whole
## spin is derived from the leader's. A companion carrying 0 here when the
## scene said -100 is a visibly different character.
@export var alignment: int = 0
@export var tendency: int = 0
## Real-time speed while walking an order, distinct from `move`, which is
## the per-turn budget.
@export var move_speed: float = 4.0
## Defaults match Unit's own, so a definition that says nothing about them
## changes nothing. hover_color is deliberately absent: unit.tscn overrides
## it scene-wide, so a definition default would have to duplicate that
## value to avoid re-tinting every unit in the game — the same trap max_fp
## sets, and not worth walking into for a field nothing authors per
## character.
@export var selected_color: Color = Color(1, 0.85, 0.2, 0.9)
## Conversations this character offers. Empty for anything that cannot be
## talked to, which is most of them.
@export var dialogue_options: Array[DialogueRootOption] = []
## Trained skills, as data rather than as scene-tree children.
##
## Reuses PartySkillRecord rather than declaring a parallel type: it is
## already the (Skill, levels_purchased) pair a live SkillInstance carries,
## already a Resource, and already what a party snapshot round-trips. Two
## shapes for one fact is how they drift.
##
## Applied in Unit._ready rather than in the definition cascade, because a
## SkillInstance has to be reparented by UnitSkills and that does not exist
## until _ready. See Unit._apply_definition_skills.
@export var skills: Array[PartySkillRecord] = []

@export_group("Negotiation")
@export var negotiable: bool = false

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


## This species' full behavior list — the archetype's behaviors first,
## then any species-specific ones layered on top. Additive rather than
## either/or, mirroring the cascade-then-override ordering Unit.definition
## already uses for every other field: the role supplies the defaults, the
## species keeps the last word.
##
## Both halves feed the same candidate pool and are scored identically
## (see AiScorer.best_plan), so "first" here is only enumeration order,
## not priority — AiScorer._is_better resolves ties explicitly rather than
## by position.
func resolved_ai_behaviors() -> Array[AiBehavior]:
	if not ai_archetype:
		return ai_behaviors

	var resolved: Array[AiBehavior] = []
	resolved.append_array(ai_archetype.behaviors)
	resolved.append_array(ai_behaviors)
	return resolved


## Smartness tier for this species — the archetype's, unless this
## definition names its own. Distinguishing "authored 2" from "left at the
## default 2" isn't possible on a plain int export, so an explicit
## ai_smartness only wins when it actually differs from the field default;
## a species wanting a different tier from its role simply sets it.
func resolved_ai_smartness() -> int:
	if ai_archetype and ai_smartness == 2:
		return ai_archetype.smartness
	return ai_smartness
