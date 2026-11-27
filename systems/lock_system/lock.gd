class_name Lock
extends Node
## Drop this under a prop (a chest today, a door later) to lock it. The
## same composition rule StashComponent follows: whatever wants to know
## whether a thing is locked asks find_on(), never the prop's class.
##
## A locked thing is opened one of two ways. With key_item in the party's
## bag, "Open" (LootInteraction) unlocks it on the spot. Without one,
## "Pick lock" (PickLockInteraction) opens the lockpicking screen
## (LockpickScreen), which needs a lock pick (LOCK_PICK) and the
## Lockpicking skill. The skill against the lock's modifier sets how
## forgiving the pick is; see LockpickScreen for the rule.
##
## Saved through the prop's persistent_id like a stash is: WorldManager
## records every direct child that has save_state(), keyed by name.

signal unlocked

## The item every pick attempt uses up when it breaks.
const LOCK_PICK: ItemDefinition = preload("res://data/items/lock_pick.tres")
const SKILL := "Lockpicking"
## Below this effective skill the lock can't be picked at all; only its
## key opens it. GURPS rolls 3 at best, so a target under 3 never succeeds.
const MIN_EFFECTIVE_SKILL := 3

## Added to the picker's Lockpicking: 0 is an ordinary lock, -5 a good
## one, -10 a superb one, positive a cheap one.
@export var modifier: int = 0
## The key that opens it without picking, or null for none.
@export var key_item: ItemDefinition = null
## Shown in the lockpicking screen's title.
@export var lock_name: String = "Lock"
@export var locked: bool = true


static func find_on(node: Node) -> Lock:
	if node == null:
		return null
	for child in node.get_children():
		if child is Lock:
			return child
	return null


## The picker's Lockpicking with this lock's modifier on it, or -1 if
## they can't use the skill at all.
func effective_skill(picker: Unit) -> int:
	var result: SkillCheckResult = SkillCalculator.get_skill_level(picker, SKILL)
	if not result.can_use_skill:
		return -1
	return result.skill_level + modifier


func can_pick(picker: Unit) -> bool:
	return effective_skill(picker) >= MIN_EFFECTIVE_SKILL


func party_has_key() -> bool:
	return key_item != null and PartyManager.inventory != null \
			and PartyManager.inventory.has(key_item)


func unlock() -> void:
	if not locked:
		return
	locked = false
	unlocked.emit()


func save_state() -> Dictionary:
	return {"locked": locked}


func load_state(state: Dictionary) -> void:
	locked = bool(state.get("locked", locked))
