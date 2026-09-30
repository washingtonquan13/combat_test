class_name SuccessRoll
extends RefCounted
## GURPS-style roll-under success resolution — 3d6 <= target_number
## succeeds, lower rolls are always better. A distinct mechanic in its
## own right in GURPS (Basic Set's own "Success Rolls" section) — not
## owned by combat, not owned by skills; both just feed it a target
## number, same as anything else that needs one (a resistance roll, some
## other check) would. Stateless, same "static func, takes what it
## needs as parameters" convention as SkillCalculator/
## PlayerInteractionState — not an owned Unit component, since nothing
## about this needs one.

## critical_success is checked first and forces success=true even when
## roll > target_number — a natural 3 or 4 always succeeds regardless of
## skill, a real GURPS rule easy to miss. critical_failure symmetrically
## forces success=false even when roll <= target_number — an 18 is
## always a critical failure even for a very high skill. Thresholds:
## 3/4 always crit-succeed; 5 crit-succeeds at skill 15+; 6 at skill 16+;
## 18 always crit-fails; 17 crit-fails unless skill 16+; anything 10+
## over skill crit-fails.
##
## rng is optional so combat keeps using the global generator. A
## conversation passes its own (see Conversation.rng), which is what lets
## a test pin one seed and reach a chosen outcome on purpose.
static func roll_vs(target_number: int, rng: RandomNumberGenerator = null) -> Dictionary:
	var dice: Array[int] = [_d6(rng), _d6(rng), _d6(rng)]
	var roll: int = dice[0] + dice[1] + dice[2]
	var critical_success: bool = roll == 3 or roll == 4 \
		or (roll == 5 and target_number >= 15) \
		or (roll == 6 and target_number >= 16)
	var critical_failure: bool = not critical_success and (
		roll == 18
		or (roll == 17 and target_number <= 15)
		or roll >= target_number + 10
	)
	return {
		"roll": roll,
		# The three individual dice, not just their sum — added for
		# skill_check_dice_popup.gd, which shows the actual rolled
		# faces rather than an abstract number. Purely additive: every
		# existing caller only ever read "roll" and ignores this key.
		"dice": dice,
		"target": target_number,
		"success": critical_success or (not critical_failure and roll <= target_number),
		"margin": target_number - roll,
		"critical_success": critical_success,
		"critical_failure": critical_failure,
	}


static func _d6(rng: RandomNumberGenerator) -> int:
	return rng.randi_range(1, 6) if rng else randi_range(1, 6)
