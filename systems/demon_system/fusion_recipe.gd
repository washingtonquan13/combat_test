class_name FusionRecipe
extends Resource
## One entry in a FusionChart — order_a + order_b fuses into
## result_order. Dumb data only, no logic — same role QuestStage plays
## inside Quest.stages. FusionChart.result_order() checks both
## orderings against order_a/order_b, so a recipe only needs authoring
## once regardless of which slot the player puts which parent in.

@export var order_a: StringName = &""
@export var order_b: StringName = &""
@export var result_order: StringName = &""
