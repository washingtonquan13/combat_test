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

## chances() per target number — 216 rolls is cheap, but the readout
## asks every frame.
static var _chances_cache: Dictionary = {}

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
	var outcome: Dictionary = outcome_of(roll, target_number)
	return {
		"roll": roll,
		# The three individual dice. Only the deprecated dice popup reads
		# these; the wheel shows the total.
		"dice": dice,
		"target": target_number,
		"success": outcome.success,
		"margin": target_number - roll,
		"critical_success": outcome.critical_success,
		"critical_failure": outcome.critical_failure,
	}


## The exact odds of roll_vs against target_number — {success,
## critical_success}, each 0..1 — from all 216 equally likely rolls
## rather than sampling. The same outcome_of as roll_vs, so the AI's
## expected damage and the player's hit-chance readout cannot drift from
## the real roll.
static func chances(target_number: int) -> Dictionary:
	if _chances_cache.has(target_number):
		return _chances_cache[target_number]
	var success_count: int = 0
	var critical_count: int = 0
	for d1 in range(1, 7):
		for d2 in range(1, 7):
			for d3 in range(1, 7):
				var outcome: Dictionary = outcome_of(d1 + d2 + d3, target_number)
				if outcome.success:
					success_count += 1
				if outcome.critical_success:
					critical_count += 1
	var result: Dictionary = {
		"success": success_count / 216.0,
		"critical_success": critical_count / 216.0,
	}
	_chances_cache[target_number] = result
	return result


static func outcome_of(roll: int, target_number: int) -> Dictionary:
	var critical_success: bool = roll == 3 or roll == 4 \
		or (roll == 5 and target_number >= 15) \
		or (roll == 6 and target_number >= 16)
	var critical_failure: bool = not critical_success and (
		roll == 18
		or (roll == 17 and target_number <= 15)
		or roll >= target_number + 10
	)
	return {
		# 17 and 18 always fail, whatever the target; only whether 17 is
		# critical depends on it.
		"success": critical_success or (not critical_failure and roll <= mini(target_number, 16)),
		"critical_success": critical_success,
		"critical_failure": critical_failure,
	}


static func _d6(rng: RandomNumberGenerator) -> int:
	return rng.randi_range(1, 6) if rng else randi_range(1, 6)
