class_name LootInteraction
extends InteractionOption
## Right-click "Open" — available on any Chest. Hands off to StashManager
## rather than touching any UI directly, same division of responsibility
## TalkInteraction already uses with DialogueManager: the InteractionOption
## just decides WHETHER and starts it, a manager autoload + its reactive
## view own what happens next.

func is_available(_actor: Unit, target) -> bool:
	return target is Chest


func execute(actor: Unit, target) -> void:
	StashManager.open_stash(target, actor)
