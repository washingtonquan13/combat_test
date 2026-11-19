class_name Camp
extends BattleField
## Where the party makes camp away from an inn (Rest.make_camp): arrive,
## and the night's rest is taken (Rest.rest_at_camp). If the camp was
## found (Rest.CAMP_FLAG's "ambush", rolled by the world it was made
## from), the fight walks in from the treeline at the EnemySpawns markers
## after the rest, or before it with ambush_interrupts, the rest then
## finishing once the fight is won. Won, the party stays: R breaks camp
## (Rest.break_camp). Owned by the rest system (see docs/systems/rest.md);
## the fight itself is BattleField's.

## Seconds after arriving before the ambush walks in.
@export var ambush_delay: float = 2.5
## The ambush comes in the night, before the rest, which finishes after
## the fight is won. Off: the party rests, then is set upon.
@export var ambush_interrupts: bool = false


func _on_world_focused(world: Node) -> void:
	if world == self and _encounter == null:
		_arrive.call_deferred()


func _arrive() -> void:
	var plan := Rest.camp()
	var ambush: Dictionary = plan.get("ambush", {})
	# A fight already pending here is a Retry, or a save made mid-ambush.
	if not OverworldEncounters.pending().is_empty():
		_start_pending()
		return
	if ambush.is_empty():
		Rest.rest_at_camp()
		SystemLog.print("Press R to break camp.")
		return
	if not ambush_interrupts:
		Rest.rest_at_camp()
	# The fight is pending from here on, and no longer the camp's to roll.
	plan.ambush = {}
	FlagManager.set_flag(Rest.CAMP_FLAG, plan)
	FlagManager.set_flag(OverworldEncounters.PENDING_FLAG, ambush)
	SystemLog.print("Something moves at the edge of the firelight.")
	await get_tree().create_timer(ambush_delay).timeout
	if is_inside_tree() and WorldManager.current_world() == self and _encounter == null:
		if not _start_pending():
			FlagManager.clear_flag(OverworldEncounters.PENDING_FLAG)
			Rest.rest_at_camp()


func _won() -> void:
	# Rested already unless the ambush interrupted the night.
	Rest.rest_at_camp()
	SystemLog.print("The camp is quiet again. Press R to break camp.")
