class_name UnitAwareness
extends RefCounted
## What one unit currently knows about another — the state DetectionManager
## drives and everything downstream reads. Owned per-Unit, same component
## split UnitCombat/UnitMovement/UnitActionState/UnitSkills already use
## (constructed in Unit._ready, reached through thin forwarders on Unit).
##
## Three states, deliberately. A fourth ("investigating," "searching,"
## "lost track") is a stealth game's problem; this is a CRPG, where the
## only question that changes anyone's behavior is whether a fight starts.
##
##   UNAWARE     nothing has registered.
##   SUSPICIOUS  something registered, but not what or who — the unit
##               knows a POSITION worth looking at and nothing more.
##   AWARE       knows what and where. If that something is hostile, this
##               is what starts a fight.
##
## SUSPICIOUS is not decoration: it is the difference between a guard
## snapping instantly to a player who stepped into view for one frame, and
## one that looks over first. It also gives a future sneaking pass
## somewhere to land — being noticed but not identified is exactly the
## state a Hide action needs to be able to retreat to.
##
## Holds no timers and does no scanning. DetectionManager owns the when;
## this owns only the what.

enum State { UNAWARE, SUSPICIOUS, AWARE }

## How obscured a position is, from the observer's side. Supplied by the
## area (see GameArea.obscurity_at) and applied as a to-notice modifier.
##
## Present from the first line of code with only CLEAR ever produced — the
## arithmetic is shaped for a light model so one can drop in later without
## touching detection, but nothing here builds or assumes one. Values are
## GURPS-style modifiers to the observer's effective Perception, so a
## darker tier is simply a bigger penalty.
enum Obscurity { CLEAR = 0, LIGHT = -4, HEAVY = -8 }

var state: State = State.UNAWARE
## Who this unit is aware of. Null while UNAWARE, and null while
## SUSPICIOUS too — that is the whole point of the middle state.
var subject: Unit = null
## Where the subject was when it was last perceived. Survives losing
## track of it, so a unit that breaks line of sight leaves behind
## somewhere to investigate rather than a shrug.
var last_known_position: Vector3 = Vector3.ZERO

var _owner: Unit


func _init(owner: Unit) -> void:
	_owner = owner


## Escalate on a successful perception. Never downgrades — losing sight of
## something you have already identified does not un-identify it, and a
## CRPG that let enemies forget mid-encounter would read as broken rather
## than as realistic. Decay, if it is ever wanted, belongs on a timer in
## DetectionManager, not here.
func notice(target: Unit, identified: bool) -> bool:
	var next: State = State.AWARE if identified else State.SUSPICIOUS
	if next <= state and subject != null:
		# Already at least this aware of something. Refresh where it is,
		# since a known enemy that keeps moving should not leave a stale
		# breadcrumb behind.
		if subject == target:
			last_known_position = target.global_position
		return false

	last_known_position = target.global_position
	if identified:
		subject = target
	state = maxi(state, next) as State
	return true


func is_aware_of(target: Unit) -> bool:
	return state == State.AWARE and subject == target


## Back to knowing nothing — called when a fight ends, so the next
## encounter starts fresh rather than with every survivor permanently
## alerted to everyone they have ever met.
func reset() -> void:
	state = State.UNAWARE
	subject = null
	last_known_position = Vector3.ZERO
