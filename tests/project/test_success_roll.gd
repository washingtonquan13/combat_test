extends AiTestCase
## 17 and 18 fail at any target: past 16, a higher target buys nothing.


func wants_world() -> bool:
	return false


func run() -> void:
	# 17 and 18 are 4 of the 216 rolls.
	for target in [16, 17, 25]:
		var odds: float = SuccessRoll.chances(target).success
		check("target %d succeeds on 212 of 216" % target, is_equal_approx(odds, 212.0 / 216.0),
			"got %.4f" % odds)
