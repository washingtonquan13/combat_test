class_name OwnedDemon
extends Resource
## ONE individual demon the player actually owns — not the same thing
## as its species. Two Pixies are two separate OwnedDemon instances,
## each tracking its own current_hp/current_fp independently, so
## damage one takes in battle doesn't vanish the moment it's dismissed
## (see DismissEffect, which syncs a live Unit's state back here) and
## doesn't heal for free just by re-summoning it (see
## SummonDemonEffect, which reads these values back out instead of
## always starting a summon at full health).
##
## Deliberately dumb data — no logic of its own, same as QuestStage.
## DemonRoster owns the array these live in and the identity-based
## add/remove operations (an OwnedDemon has no id of its own; instance
## equality via the roster's own Array is enough, since nothing needs
## to look one up by name — you always already have the reference from
## whichever list the player clicked into).

@export var species: DemonSpecies
@export var current_hp: int = 0
@export var current_fp: int = 0
## Purely informational for now (e.g. a "battle-tested" indicator in
## the compendium UI) — no mechanical effect is specified yet, so none
## is built. Still real per-instance state, which is exactly why this
## whole class exists instead of a bare species reference.
@export var has_been_summoned: bool = false
