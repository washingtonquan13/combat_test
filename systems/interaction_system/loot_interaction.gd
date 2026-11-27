class_name LootInteraction
extends InteractionOption
## Right-click "Open" — available on anything carrying a StashComponent
## child, regardless of what kind of node it is (a chest today, maybe a
## lootable corpse or a barrel later — see stash_component.gd). Hands
## off to StashManager rather than touching any UI directly, same
## division of responsibility TalkInteraction already uses with
## Conversations: this just decides WHETHER and starts it.
##
## A locked stash (a Lock child) still offers "Open": with the key in the
## party's bag it unlocks and opens, without it the log says it is locked
## and "Pick lock" (PickLockInteraction) is the way in.

func is_available(_actor: Unit, target) -> bool:
	return target is Node and StashComponent.find_on(target) != null


func execute(actor: Unit, target) -> void:
	var lock := Lock.find_on(target)
	if lock and lock.locked:
		if not lock.party_has_key():
			SystemLog.print("It's locked.")
			return
		lock.unlock()
		SystemLog.print("%s unlocks it with the %s." % [LogFormat.unit_name(actor), lock.key_item.item_name])
	StashManager.open_stash(StashComponent.find_on(target), actor)
