class_name FusionChart
extends Resource
## The whole Order x Order -> Order fusion table, as one authored
## resource (data/fusion_charts/fusion_chart.tres) — the deliberate
## exception to this project's usual one-file-per-thing convention
## (data/skills/, data/quests/): fusion combinations are inherently
## pairs, not naturally one-file-per-thing, and the real games present
## this as one cohesive chart, not scattered recipe files. Its own
## folder, not data/demons/, since it isn't a demon itself — leaves
## room for a future second chart (a fusion-accident table, a
## fusion-while-cursed table, ...) to live alongside it without either
## being mixed in with actual demon definitions.

@export var recipes: Array[FusionRecipe] = []


## "" (no match) if no recipe connects these two orders in either
## direction — the same empty-StringName-as-"nothing" sentinel
## UnitDefinition.order's own default uses.
func result_order(order_a: StringName, order_b: StringName) -> StringName:
	for recipe in recipes:
		if (recipe.order_a == order_a and recipe.order_b == order_b) \
				or (recipe.order_a == order_b and recipe.order_b == order_a):
			return recipe.result_order
	return &""
