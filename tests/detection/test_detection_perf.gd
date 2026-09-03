extends AiTestCase
## Cost of a detection sweep, measured rather than assumed.
##
## The plan flagged this as the pass's real risk: DetectionManager
## raycasts per observer/subject pair, and AiScorer already raycasts in
## its own hot path. Two regular physics consumers is the point at which
## "it's probably fine" stops being good enough.


## Bigger than any encounter this project builds today, on purpose — a
## budget with no headroom isn't a budget.
const OBSERVERS: int = 12
const PARTY: int = 4
const SWEEPS: int = 50

## Per sweep, in milliseconds. Generous against a 0.2s scan interval:
## even at this ceiling a sweep costs under 1% of the budget between
## sweeps. Set as a REGRESSION alarm, not a target.
const BUDGET_MS: float = 2.0


func run() -> void:

	# NEUTRAL, not enemy. A hostile observer starts a fight the moment it
	# succeeds, and from then on scan() skips everyone already in the turn
	# order — so the "measurement" would mostly be timing the skip. Neutral
	# observers run the identical sight path and simply don't escalate.
	var watchers: Array[Unit] = []
	for i in OBSERVERS:
		var watcher: Unit = spawn_unit(&"neutral", 10, 12, 20, [melee()],
			Vector3(-20.0 + i * 3.0, 0.0, 10.0))
		watcher.snap_face_point(Vector3(0.0, 0.0, 0.0))
		watchers.append(watcher)
	for i in PARTY:
		spawn_unit(&"player", 10, 12, 20, [melee()], Vector3(-3.0 + i * 2.0, 0.0, 0.0))

	# One sweep first so any lazy setup isn't charged to the measurement.
	DetectionManager.scan()

	# Awareness reset before every sweep, so each one walks the FULL path
	# — cone, raycast, roll — for every pair. An observer that has already
	# identified someone short-circuits on its next sweep, which is the
	# common case in play but the cheap one, and timing only that would
	# report a cost the system doesn't actually have.
	var started: int = Time.get_ticks_usec()
	for i in SWEEPS:
		for watcher in watchers:
			watcher.awareness().reset()
		DetectionManager.scan()
	var per_sweep_ms: float = float(Time.get_ticks_usec() - started) / float(SWEEPS) / 1000.0

	check("a detection sweep over %d observers x %d party stays under %.1fms"
			% [OBSERVERS, PARTY, BUDGET_MS],
		per_sweep_ms < BUDGET_MS, "%.3fms per sweep" % per_sweep_ms)
	print("        detection: %.3f ms/sweep (%d observers x %d party)"
		% [per_sweep_ms, OBSERVERS, PARTY])

	for encounter in CombatManager.encounters.duplicate():
		if is_instance_valid(encounter) and encounter.is_running:
			encounter.finish(&"")
	free_spawned()
