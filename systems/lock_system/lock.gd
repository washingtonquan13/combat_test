class_name Lock
extends Node
## Drop this under a prop (a chest today, a door later) to lock it. The
## same composition rule StashComponent follows: whatever wants to know
## whether a thing is locked asks find_on(), never the prop's class.
##
## A locked thing is opened one of two ways. With key_item in the party's
## bag, "Open" (LootInteraction) unlocks it on the spot. Without one,
## "Pick lock" (PickLockInteraction) opens the lockpicking screen
## (LockpickScreen), which needs a lock pick (LOCK_PICK) and enough
## Lockpicking for the lock's tier, as in Fallout 3 / New Vegas: the tier
## gates who may try and sets how precisely the pick must sit; the skill
## sets how long a pick lasts and the odds of forcing it. See
## LockpickScreen for the rule. A failed force jams the lock for good:
## only its key opens it then.
##
## Saved through the prop's persistent_id like a stash is: WorldManager
## records every direct child that has save_state(), keyed by name.

signal unlocked

## Fallout's five lock difficulties.
enum Tier { VERY_EASY, EASY, AVERAGE, HARD, VERY_HARD }

const TIER_NAMES := ["Very easy", "Easy", "Average", "Hard", "Very hard"]
## Lockpicking needed to try each tier. Fallout asks 0/25/50/75/100 on
## its 0-100 scale; on GURPS's that is roughly anyone, competent (8),
## professional (11), expert (14), master (17).
const TIER_SKILL := [0, 8, 11, 14, 17]
## Added to Lockpicking for Force Lock. Fallout's only sure force is a
## very easy lock at 90-100 skill: here, skill 17+ on a very easy lock.
const FORCE_MODIFIER := [2, 0, -2, -4, -6]

## The item every pick attempt uses up when it breaks.
const LOCK_PICK: ItemDefinition = preload("res://data/items/lock_pick.tres")
const SKILL := "Lockpicking"
@export var tier: Tier = Tier.VERY_EASY
## The key that opens it without picking, or null for none.
@export var key_item: ItemDefinition = null
## Shown in the lockpicking screen's title.
@export var lock_name: String = "Lock"
@export var locked: bool = true
## A failed Force Lock broke it: it can't be picked or forced again.
@export var jammed: bool = false


static func find_on(node: Node) -> Lock:
	if node == null:
		return null
	for child in node.get_children():
		if child is Lock:
			return child
	return null


## The picker's Lockpicking, or -1 if they can't use the skill at all.
static func skill_of(picker: Unit) -> int:
	var result: SkillCheckResult = SkillCalculator.get_skill_level(picker, SKILL)
	return result.skill_level if result.can_use_skill else -1


func required_skill() -> int:
	return TIER_SKILL[tier]


func tier_name() -> String:
	return TIER_NAMES[tier]


## How far the picker's skill is over the tier's requirement (0 or more
## if they may try).
func skill_margin(picker: Unit) -> int:
	return skill_of(picker) - required_skill()


func can_pick(picker: Unit) -> bool:
	return not jammed and skill_of(picker) >= 0 and skill_margin(picker) >= 0


## The roll's target for Force Lock.
func force_target(picker: Unit) -> int:
	return skill_of(picker) + FORCE_MODIFIER[tier]


func party_has_key() -> bool:
	return key_item != null and PartyManager.inventory != null \
			and PartyManager.inventory.has(key_item)


func unlock() -> void:
	if not locked:
		return
	locked = false
	unlocked.emit()


func jam() -> void:
	jammed = true


func save_state() -> Dictionary:
	return {"locked": locked, "jammed": jammed}


func load_state(state: Dictionary) -> void:
	locked = bool(state.get("locked", locked))
	jammed = bool(state.get("jammed", jammed))
