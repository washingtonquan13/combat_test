class_name ForceLandOnExpireBehavior
extends StatusBehavior
## Snaps the unit back onto the ground the instant this status is
## removed — a voluntary Land action (see land_effect.gd), natural
## expiry, or Unit.ground_if_flying() forcing a flyer down
## (IncapacitateBehavior). By the time on_remove fires,
## StatusManager.remove() has already erased this status from `active`
## (see status_manager.gd), so Unit.is_flying() is already false here
## regardless of which caller triggered it — nothing else needs to check
## that before calling land().
##
## voluntary is forwarded straight through to Unit.land() — only the
## Land action passes true; forwarded false hits the fall-damage path
## for BOTH the other callers (expiry and forced grounding), which is
## correct for both: neither is a landing the unit chose.

func on_remove(unit: Unit, _active: ActiveStatus, voluntary: bool = false) -> void:
	unit.land(voluntary)


func describe() -> String:
	return "Lands when this expires"
