class_name UseTerminalInteraction
extends InteractionOption
## Right-click "Use" on a Terminal: the actor walks up to it (reach) and
## the view glides into its screen. See Terminal.use.

func is_available(_actor: Unit, target) -> bool:
	return target is Terminal and (target as Terminal).can_use()


func execute(_actor: Unit, target) -> void:
	(target as Terminal).use()
