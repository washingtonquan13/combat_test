class_name AiArchetype
extends Resource
## A named, reusable AI role — "artillery," "brute," "support" — bundling
## the behaviors and smartness tier that make a species fight like that.
## A UnitDefinition points at one instead of hand-listing behaviors (see
## UnitDefinition.ai_archetype), so authoring a demon is picking a role
## rather than re-deriving a composition and guessing at its constants.
##
## The problem this solves is concrete: 22 of 31 demons authored
## ai_behaviors by hand, 12 of them referencing the same flight behavior,
## so every fix to that behavior was a twelve-file edit and every new
## species was a fresh guess. Archetypes make a behavior change a
## one-file change.
##
## Same shape both reference CRPGs use. Solasta assigns creatures named
## DECISION PACKAGES rather than loose rules; BG3 ships per-creature
## files under Data/Public/Gustav/AI/Archetypes that "influence AI
## scoring for which actions characters choose in combat." In both, the
## archetype biases one shared scorer — it does not replace it, and it
## does not contain its own decision logic. Same here: everything in an
## archetype is authored data that AiScorer then prices (see AiBehavior's
## contract for why a behavior never prices itself).
##
## Role vocabulary follows the standard tactical taxonomy (D&D 4e, and
## since then Flee Mortals! / The Monsters Know What They're Doing):
## brute, skirmisher, artillery, controller, support — plus ambusher,
## which this project deliberately does NOT implement, having no stealth
## system for one to be built on.

@export var display_name: String = ""
## Which tactical role this is, for authoring clarity and debug output —
## purely descriptive, nothing branches on it. Kept a StringName rather
## than an enum so a project-specific role can be added in data without
## a code change.
@export var role: StringName = &""
@export var behaviors: Array[AiBehavior] = []
## Cascades to Unit.ai_smartness — see AiScorer's tier table for what
## each tier actually considers. 2 (Tactical) is the sensible default for
## authored content; 0 (Feral) is the pre-scorer baseline.
@export var smartness: int = 2
