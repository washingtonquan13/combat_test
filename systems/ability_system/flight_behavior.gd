class_name FlightBehavior
extends StatusBehavior
## Marks the status carrying this behavior as one that grants flight —
## see StatusBehavior.grants_flight()/StatusManager.grants_flight(),
## same "any active status contributes" pattern as IncapacitateBehavior/
## prevents_turn(). Doesn't do anything else by itself — altitude
## control, forced landing on expiry, and mutual flyer avoidance are
## separate, not-yet-built follow-ups (see GrantFlightEffect and
## UnitMovement.move_to()'s flying branch for what's actually wired up
## today).

func grants_flight() -> bool:
	return true


func describe() -> String:
	return "Flying"
