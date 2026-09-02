class_name LootInteraction
extends InteractionOption
## Right-click "Open" — available on anything carrying a StashComponent
## child, regardless of what kind of node it is (a chest today, maybe a
## lootable corpse or a barrel later — see stash_component.gd). Hands
## off to StashManager rather than touching any UI directly, same
## division of responsibility TalkInteraction already uses with
## DialogueManager: this just decides WHETHER and starts it.

func is_available(_actor: Unit, target) -> bool:
	return target is Node and StashComponent.find_on(target) != null


func execute(actor: Unit, target) -> void:
	StashManager.open_stash(StashComponent.find_on(target), actor)
