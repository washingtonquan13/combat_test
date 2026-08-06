class_name ForceLandOnExpireBehavior
extends StatusBehavior
## Snaps the unit back onto the ground the instant this status is
## removed — expiry, or an explicit remove_status() call from a
## voluntary Land action (see land_effect.gd). By the time on_remove
## fires, StatusManager.remove() has already erased this status from
## `active` (see status_manager.gd), so Unit.is_flying() is already
## false here regardless of which of those two callers triggered it —
## nothing else needs to check that before calling land().

func on_remove(unit: Unit, _active: ActiveStatus) -> void:
	unit.land()


func describe() -> String:
	return "Lands when this expires"
