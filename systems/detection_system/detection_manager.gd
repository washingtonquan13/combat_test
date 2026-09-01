extends Node
## Autoload singleton. Register as "DetectionManager" under
## Project > Project Settings > AutoLoad, after CombatManager and
## FactionRelations (it calls both).
##
## Answers the question nothing in this project could answer before: does
## that NPC know you are there? Until now an NPC noticed exactly one thing
## — a single-target ability landing on it (see
## UnitCombat._maybe_trigger_combat) — so a party could walk through a camp
## untouched until it chose to swing first.
##
## Deliberately built ON TOP of the existing entry point rather than beside
## it. Reaching AWARE of a hostile calls the same
## CombatManager.start_combat_from_hostile_act() that being attacked does,
## so faction escalation and the aggro pull keep working unchanged and
## there is exactly one way a fight begins.
##
## SCANNING, not watching. A timed sweep (SCAN_INTERVAL) rather than a
## per-frame check or a pile of Area3D sensors: detection is a gameplay
## question that resolves on human timescales, the pair count is small,
## and a raycast per pair per frame would be real cost for no perceptible
## difference. Repeated rolls are also the mechanism — see _attempt_sight.
##
## Runs in every mode except when the world isn't live. During combat it
## only scans units NOT in turn_order, which is what lets a fight pull in
## anyone who hears it — and _draw_in_latecomers, which runs first, pulls
## in anyone standing in one regardless of which side they are on.

## How often the sweep runs. Slow enough to be free, fast enough that
## walking into view resolves in well under a second.
const SCAN_INTERVAL: float = 0.2

## Per metre of distance, subtracted from the observer's effective
## Perception. GURPS-ish and deliberately gentle: at 18m (a default
## max_sight_range) this is -4.5, which a Perception-12 guard still passes
## more often than not in the open.
const DISTANCE_PENALTY_PER_METRE: float = 0.25

## Applied instead of the cone test when the target is within the
## observer's proximity_radius — you do not need to be looking at someone
## standing against your shoulder.
const PROXIMITY_BONUS: int = 4

## How far a fight carries. Hearing ignores facing and line of sight
## entirely — this is BG3's "shouting range," and it is why a brawl in the
## next room brings people running while one across the map does not.
const HEARING_RADIUS: float = 22.0

## Eye height and obstruction mask for the sight raycast — same values
## every targeting class uses, so detection and shooting agree about what
## counts as a wall.
const EYE_HEIGHT: float = 1.5
const OBSTRUCTION_MASK: int = 1

## Emitted whenever a unit's awareness escalates, for UI and debugging.
signal awareness_changed(observer: Unit, subject: Unit, state: UnitAwareness.State)

var _elapsed: float = 0.0
## Set false by tests, which drive scan() directly rather than waiting on
## wall-clock time — a suite that sleeps is a suite nobody runs.
var enabled: bool = true


func _ready() -> void:
	CombatManager.combat_ended_in_world.connect(_on_combat_ended_in_world)


func _process(delta: float) -> void:
	if not enabled:
		return
	_elapsed += delta
	if _elapsed < SCAN_INTERVAL:
		return
	_elapsed = 0.0
	scan()


## One full sweep. Public so tests (and any future "look again now"
## trigger, like a loud noise) can force one without waiting.
func scan() -> void:
	var tree: SceneTree = get_tree()
	if tree == null:
		return

	var units: Array[Unit] = UnitQuery.living_units(tree)
	if units.size() < 2:
		return

	if CombatManager.any_combat_running():
		_draw_in_latecomers(units)

	for observer in units:
		# The player's own units don't roll to notice anything. Detection
		# exists to decide what the WORLD does about the player; a party
		# member spotting a goblin is the player's job to act on, and
		# making it mechanical would start fights the player didn't pick.
		#
		# That restraint is about STARTING a fight, though — see
		# _draw_in_latecomers for joining one, which applies to both sides.
		if observer.is_player_controlled():
			continue
		# Already fighting — its perception is that encounter's problem,
		# not this sweep's.
		if observer.in_combat():
			continue

		for subject in units:
			if subject == observer or not subject.is_player_controlled():
				continue
			# Same world only. The sweep itself is global (one manager for
			# however many worlds are loaded), but perception is not — an
			# NPC in one area has no business noticing someone in another,
			# and with two worlds authored around the same origin they can
			# be metres apart in raw coordinates.
			if subject.get_world_3d() != observer.get_world_3d():
				continue
			if _consider(observer, subject):
				break


## Anyone standing in an ongoing fight who isn't yet part of it — either
## side — gets pulled in.
##
## Written as its own pass because the main loop above deliberately never
## treats a party member as an observer, and that exclusion was silently
## doing double duty: it correctly stops the party from starting fights on
## its own, but it also meant a player unit left out of a fight could
## stand in the middle of one indefinitely, unable to join. Walking a
## straggler over to the battle did nothing.
##
## Joining is not the same decision as attacking. Being in a brawl is a
## fact about where you are standing, not a choice about whom to fight, so
## it applies symmetrically and needs no roll — which is also why this
## sits outside the perception machinery rather than inside it.
func _draw_in_latecomers(units: Array[Unit]) -> void:
	for unit in units:
		if unit.in_combat():
			continue

		# Whichever fight it actually walked into — not "the" fight, since
		# there may be several running and joining the wrong one would drop
		# a unit into a battle happening somewhere else entirely.
		# ALL of them, not the focused world's: a unit standing in a world
		# nobody is watching still walks into its own fights.
		for encounter in CombatManager.all_encounters():
			if not is_instance_valid(encounter) or not encounter.is_running:
				continue
			var joined: bool = false
			for combatant in encounter.turn_order:
				if not is_instance_valid(combatant) or not combatant.is_alive():
					continue
				# Only somebody's enemy joins. A neutral bystander standing
				# in the middle of a fight it has no stake in stays one.
				# Same world FIRST, before any distance is measured. Every
				# area in this project is authored around the origin, so raw
				# distance says a unit two areas away is standing on top of
				# the fight — and it would be pulled into a battle in a world
				# it is not in, which then makes it impossible for a fight to
				# start where it actually is, since it already counts as
				# fighting.
				if not combatant.is_inside_tree() or not unit.is_inside_tree():
					continue
				if combatant.get_world_3d() != unit.get_world_3d():
					continue
				if not unit.is_hostile_to(combatant):
					continue
				if unit.distance_to(combatant) > HEARING_RADIUS:
					continue
				SystemLog.print("%s joins the fight." % LogFormat.unit_name(unit))
				CombatManager.add_unit_to_combat(unit, null, encounter)
				joined = true
				break
			if joined:
				break


## Resolves one observer/subject pair, returning true if awareness
## escalated (so the caller can stop looking — one thing noticed is enough
## to act on this tick).
func _consider(observer: Unit, subject: Unit) -> bool:
	var awareness: UnitAwareness = observer.awareness()
	if awareness.is_aware_of(subject):
		# Already knows. Keep the breadcrumb current, but nothing new
		# happens — and specifically don't re-trigger combat.
		awareness.notice(subject, true)
		return false

	var identified: bool = _attempt_sight(observer, subject)
	var heard: bool = not identified and _hears_disturbance(observer, subject)
	if not identified and not heard:
		return false

	if not awareness.notice(subject, identified):
		return false

	awareness_changed.emit(observer, subject, awareness.state)

	_react_to(observer, subject, awareness.state)
	return true


## Can observer see subject well enough to identify it, this tick?
##
## Rolled rather than thresholded, and rolled REPEATEDLY — that is the
## design, not an accident. A single deterministic test makes detection a
## tripwire; rolling every sweep means standing in the open gets you
## noticed almost immediately, while clipping the far edge of someone's
## vision might genuinely go unnoticed. It reproduces the feel of BG3's
## gradually-filling detection indicator without a second meter to build,
## tune, and display.
func _attempt_sight(observer: Unit, subject: Unit) -> bool:
	var distance: float = observer.distance_to(subject)
	if distance > observer.max_sight_range:
		return false

	var close: bool = distance <= observer.proximity_radius
	if not close and not _within_cone(observer, subject):
		return false

	if not LineOfSight.has_clear_shot(observer, subject, OBSTRUCTION_MASK, EYE_HEIGHT):
		return false

	var target_number: int = observer.perception
	target_number -= roundi(distance * DISTANCE_PENALTY_PER_METRE)
	target_number -= _stealth_of(subject)
	target_number += obscurity_at(subject.global_position)
	if close:
		target_number += PROXIMITY_BONUS

	return SuccessRoll.roll_vs(target_number).success


## Is subject inside observer's forward vision?
##
## Uses Unit.visual_forward(), never a raw -basis.z: the real rig carries
## facing_offset_degrees = 180, so the two point in opposite directions and
## the naive version produces a unit that can only see behind itself.
func _within_cone(observer: Unit, subject: Unit) -> bool:
	var to_subject: Vector3 = subject.global_position - observer.global_position
	to_subject.y = 0.0
	if to_subject.length() < 0.01:
		return true
	var forward: Vector3 = observer.visual_forward()
	forward.y = 0.0
	if forward.length() < 0.01:
		return true
	var angle: float = rad_to_deg(forward.normalized().angle_to(to_subject.normalized()))
	return angle <= observer.vision_cone_degrees * 0.5


## Whether observer hears something worth turning around for. Ignores the
## cone and line of sight on purpose — a fight is loud through a wall.
## Only ever produces SUSPICIOUS, never AWARE: hearing tells you where,
## not who.
func _hears_disturbance(observer: Unit, subject: Unit) -> bool:
	if not subject.in_combat():
		return false
	return observer.distance_to(subject) <= HEARING_RADIUS


## Subject's Stealth, as a penalty to the observer's roll — BG3's rule
## that the observer's stat sets the difficulty and the sneaker's skill
## opposes it, expressed in this project's roll-under arithmetic.
##
## The whole hook for a future sneaking pass: today every unit returns its
## plain Stealth level, and a Hide action would simply raise it.
func _stealth_of(subject: Unit) -> int:
	var result: SkillCheckResult = SkillCalculator.get_skill_level(subject, "Stealth")
	if not result.can_use_skill:
		return 0
	# Relative to an average skill, so a merely competent sneak is neutral
	# rather than a flat bonus to being seen.
	return maxi(result.skill_level - 10, 0)


## How obscured a position is, as a modifier to anyone trying to see it.
##
## Always CLEAR today. It exists as a real parameter threaded through the
## arithmetic from the first line of code so a light model can drop in
## later — authored light volumes, darkvision per species — without
## touching detection itself. Deliberately NOT a stub that returns a magic
## number: the value it returns is used, it just happens to be zero.
func obscurity_at(_position: Vector3) -> int:
	return UnitAwareness.Obscurity.CLEAR


## What actually happens when an NPC identifies someone.
##
## Routed through the SAME entry point being attacked uses, so there is
## exactly one path into combat and faction escalation behaves identically
## whether you were spotted or you swung first.
func _react_to(observer: Unit, subject: Unit, state: UnitAwareness.State) -> void:
	if not observer.is_hostile_to(subject):
		# Noticing a neutral is not a reason to attack it. This is what
		# keeps a town from erupting because a guard looked at you.
		return

	if CombatManager.combat_running_in_world_of(observer):
		# Joining an ongoing fight is _draw_in_latecomers' job — it covers
		# both sides and runs before this, so anything close enough is
		# already in by the time perception gets a look.
		#
		# IN THIS WORLD, not anywhere. Asked globally, a battle in one area
		# stopped anything from ever starting a fight in any other — the
		# sandbox turning a local rule into a global one without the rule
		# changing.
		return

	# STARTING one is a higher bar. A half-heard noise is not grounds to
	# attack someone: the observer has to have actually identified what it
	# is looking at.
	if state == UnitAwareness.State.AWARE:
		CombatManager.start_combat_from_hostile_act(observer, subject)


## Everyone forgets when the fight is over, so the next encounter starts
## fresh instead of with every survivor permanently alerted to everyone
## they have ever seen.
## Only where the fight was. Every unit in every world forgetting
## because a battle ended somewhere else means an ambush two areas away
## is quietly undone by an unrelated skirmish finishing.
##
## Scoped by the ENDED FIGHT's world, not the focused one: the fight
## that ended may well be in a world nobody was watching, which is the
## whole reason the encounter has to remember where it was.
func _on_combat_ended_in_world(world: World3D) -> void:
	for unit in UnitQuery.living_units(get_tree()):
		if world != null and unit.is_inside_tree() and unit.get_world_3d() != world:
			continue
		unit.awareness().reset()
