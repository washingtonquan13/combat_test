class_name DemonPersonality
extends Resource
## Reusable, author-once-reference-many-times demon temperament — same
## composition discipline as PrerequisiteRule/InteractionOption: the
## data and the logic that interprets it live together here, not spread
## between a data resource and a separate evaluator elsewhere.
##
## One DemonPersonality is referenced by any number of DemonSpecies (see
## that class's own personality field) — "zealous" demons across many
## different species all share the exact same tolerance/weights,
## authored once rather than repeated per species.

## How many alignment_category()/tendency_category() steps (0-2, on the
## existing -1/0/1 scale) away from the DEMON's OWN alignment/tendency
## an actor can be and still be recruitable at all — 0 rejects anyone
## not in the demon's own exact category ("outright reject opposing
## alignments"), 2 always passes (any two categories on a 3-value scale
## are at most 2 steps apart) — "just don't care about it at all."
## Reuses Unit.alignment_category()/tendency_category() and
## AlignmentPrerequisite's own axis-comparison pattern directly (see
## alignment_acceptable/tendency_acceptable below), so this can never
## disagree with what the character sheet already shows the player.
## Gates RECRUIT specifically — see NegotiationManager._roll_outcome().
@export_range(0, 2, 1) var alignment_tolerance: int = 2
@export_range(0, 2, 1) var tendency_tolerance: int = 2

## Response tones (see NegotiationResponse.tone) this personality reacts
## well/badly to — e.g. a "zealous" demon might favor &"pious" and
## disfavor &"mocking". A tone in neither list is simply neutral. Plain
## StringName tags, not a dedicated Resource type — same reasoning
## Unit.faction/DemonSpecies.order stay bare tags: there's no per-tone
## behavior to plug in, just a label tone_favor() below compares against.
@export var favored_tones: Array[StringName] = []
@export var disfavored_tones: Array[StringName] = []

## Relative base likelihood of each outcome once a negotiation round's
## roll actually resolves — see NegotiationManager._roll_outcome(),
## which shifts these by the running favor score before rolling. Not
## required to sum to any particular total; only relative size between
## the four matters.
@export var recruit_weight: float = 1.0
@export var flee_weight: float = 1.0
@export var attack_weight: float = 1.0
@export var heal_weight: float = 0.0


## +1/-1/0 favor shift for picking a response with this tone — applied
## by NegotiationManager.choose_response().
func tone_favor(tone: StringName) -> int:
	if tone in favored_tones:
		return 1
	if tone in disfavored_tones:
		return -1
	return 0


func alignment_acceptable(demon: Unit, actor: Unit) -> bool:
	return absi(demon.alignment_category() - actor.alignment_category()) <= alignment_tolerance


func tendency_acceptable(demon: Unit, actor: Unit) -> bool:
	return absi(demon.tendency_category() - actor.tendency_category()) <= tendency_tolerance
