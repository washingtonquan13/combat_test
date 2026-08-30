extends AiTestCase
## AiArchetype as the authoring unit: a species names a role and inherits
## its behaviors, instead of hand-listing them and guessing at constants.


const EXPECTED_ROLES: Array[String] = ["brute", "artillery", "aerial_artillery",
	"skirmisher", "controller", "support", "aerial_skirmisher", "aerial_support"]


func run() -> void:
	_all_load()
	_cascade()
	_roster_coverage()
	_behaviors_propose_valid_plans()


func _all_load() -> void:
	var broken: PackedStringArray = []
	for name in EXPECTED_ROLES:
		var archetype = load("res://data/ai_archetypes/%s.tres" % name)
		if archetype == null or not (archetype is AiArchetype) or archetype.behaviors.is_empty():
			broken.append(name)
	check("every shipped archetype loads with behaviors attached",
		broken.is_empty(), ", ".join(broken))


func _cascade() -> void:
	var definition: UnitDefinition = load("res://data/demons/avian.tres")
	check("a migrated demon names an archetype", definition.ai_archetype != null)
	check("and no longer hand-lists behaviors", definition.ai_behaviors.is_empty(),
		"%d left" % definition.ai_behaviors.size())
	check("resolved_ai_behaviors() returns the archetype's",
		definition.resolved_ai_behaviors().size() == definition.ai_archetype.behaviors.size())

	var unit: Unit = spawn_demon("avian", Vector3.ZERO)
	check("a spawned Unit receives them through Unit.definition's cascade",
		unit.ai_behaviors.size() == definition.ai_archetype.behaviors.size(),
		"unit=%d archetype=%d" % [unit.ai_behaviors.size(),
			definition.ai_archetype.behaviors.size()])
	free_spawned()


## Guards the migration: a demon with abilities but no role runs on bare
## baseline enumeration, which is the pre-archetype state this replaced.
func _roster_coverage() -> void:
	var uncovered: PackedStringArray = []
	for file in DirAccess.get_files_at("res://data/demons"):
		if not file.ends_with(".tres"):
			continue
		var definition: UnitDefinition = load("res://data/demons/%s" % file)
		if definition and not definition.abilities.is_empty() and definition.ai_archetype == null:
			uncovered.append(file)
	check("every demon with abilities has a role", uncovered.is_empty(), ", ".join(uncovered))


## Smoke test across the whole suite of behaviors — nothing may propose a
## null plan or a plan with no target, both of which AiScorer discards
## silently rather than erroring.
func _behaviors_propose_valid_plans() -> void:
	var unit: Unit = spawn_unit(&"enemy", 12, 12, 20, [melee()], Vector3.ZERO)
	var foe: Unit = spawn_brute(3.0)

	var bad: PackedStringArray = []
	for file in DirAccess.get_files_at("res://data/ai_archetypes"):
		if not file.ends_with(".tres"):
			continue
		var archetype: AiArchetype = load("res://data/ai_archetypes/%s" % file)
		for behavior in archetype.behaviors:
			for plan in behavior.propose(unit):
				if plan == null or plan.target == null:
					bad.append("%s/%s" % [file, behavior.get_script().get_global_name()])
	check("every archetype behavior proposes usable plans", bad.is_empty(), ", ".join(bad))
	free_spawned()
