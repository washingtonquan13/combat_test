extends Node
## Autoload singleton. Register as "PendingCharacter" under
## Project > Project Settings > AutoLoad.
##
## Carries a finished character_creation.tscn result across the scene
## boundary into MainRoot/TestArena. A real Unit can't be built at the
## moment Confirm is pressed — there's no arena loaded yet to place it
## in — so this holds plain data instead, consumed and cleared the
## instant test_arena.gd applies it (see its own
## _apply_created_character_if_pending()). is_ready is the actual signal
## that a character was really created; if it's false (e.g. this scene
## loaded straight into a test run without ever going through character
## creation), nothing here should be treated as meaningful.

var is_ready: bool = false
var display_name: String = ""
var strength: int = 10
var dexterity: int = 10
var intelligence: int = 10
var health: int = 10
## skill_name (String, matches Skill.skill_name / SkillDatabase.find's
## key) -> relative level in Bucket C's own -1..+8 notation. A skill
## absent from this dict (or present at 0) got no investment.
var skill_levels: Dictionary = {}


func clear() -> void:
	is_ready = false
	display_name = ""
	strength = 10
	dexterity = 10
	intelligence = 10
	health = 10
	skill_levels.clear()
