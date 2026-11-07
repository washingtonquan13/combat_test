class_name HeldByRuleBehavior
extends StatusBehavior
## For a status that a rule puts on and takes off, not a timer — Bloodied
## and Exhausted last exactly as long as their pool is below a third
## (see Unit._update_low_pool_statuses). The countdown is stopped from
## the moment it goes on, as Downed's is, so it never runs out on its own.


func on_apply(_unit: Unit, active: ActiveStatus) -> void:
	active.stopped = true
