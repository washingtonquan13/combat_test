class_name PickLockInteraction
extends InteractionOption
## Right-click "Pick lock" on anything with a locked Lock child. Opens
## the lockpicking screen (LockpickScreen); the reasons it can't are told
## in the log rather than hiding the verb, so the player learns the lock
## needs a pick or more skill.

func is_available(_actor: Unit, target) -> bool:
	var lock := Lock.find_on(target as Node)
	return lock != null and lock.locked


func execute(actor: Unit, target) -> void:
	var lock := Lock.find_on(target as Node)
	if lock == null or not lock.locked:
		return
	if not lock.can_pick(actor):
		SystemLog.print("%s can't pick this lock. It needs its key." % LogFormat.unit_name(actor))
		return
	if not PartyManager.inventory.has(Lock.LOCK_PICK):
		SystemLog.print("No lock picks.")
		return
	LockpickScreen.begin(lock, actor)
