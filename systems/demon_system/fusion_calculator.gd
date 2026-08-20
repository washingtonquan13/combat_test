class_name FusionCalculator
extends RefCounted
## Computes a fusion result, mirroring SkillCalculator's shape: static,
## stateless, takes its full input as parameters. Operates purely at
## the SPECIES level — fusion math cares about Order/rank, never about
## a specific OwnedDemon instance's current HP, which is why this takes
## DemonSpecies in and out, not OwnedDemon (see DemonCompendiumPanel,
## which unwraps the two selected OwnedDemon instances to their
## .species before calling this).

## Null if the chart has no recipe connecting the two orders, or the
## resulting order has no valid (non-special) member to land on.
static func compute_fusion(chart: FusionChart, species_a: DemonSpecies, species_b: DemonSpecies) -> DemonSpecies:
	var result_order: StringName = chart.result_order(species_a.order, species_b.order)
	if result_order == &"":
		return null

	var candidates: Array[DemonSpecies] = []
	for species in DemonDatabase.members_of_order(result_order):
		if not species.is_special:
			candidates.append(species)
	if candidates.is_empty():
		return null

	var computed_rank: int = roundi((species_a.rank + species_b.rank) / 2.0)
	var best: DemonSpecies = candidates[0]
	var best_distance: int = absi(best.rank - computed_rank)
	for species in candidates:
		var distance: int = absi(species.rank - computed_rank)
		# A strictly closer distance always wins; an EQUAL distance only
		# wins if this candidate's rank is lower — ties favor the lower
		# rank, per design, regardless of what order members_of_order
		# happened to return them in.
		if distance < best_distance or (distance == best_distance and species.rank < best.rank):
			best = species
			best_distance = distance
	return best
