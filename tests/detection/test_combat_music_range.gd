extends AiTestCase
## When combat music is loaded ahead: MusicManager holds an area's combat
## ensemble only while a hostile is within its own sight range of the party
## (see music_manager.gd's header). This guards the range rule itself; the
## load and release are the director's, covered by sfpp_test's preload suite.


func run() -> void:
	_in_range_counts()
	_out_of_range_does_not()
	_neutral_does_not()
	_reach_widens_the_range()
	_hostiles_with_no_party_do_not()
	_threat_level_grades_by_range()


func _in_range_counts() -> void:
	var enemy: Unit = spawn_unit(&"enemy", 10, 12, 20, [melee()], Vector3.ZERO)
	spawn_unit(&"player", 10, 12, 20, [melee()], Vector3(0.0, 0.0, enemy.max_sight_range - 1.0))
	check("a hostile inside its sight range counts", MusicManager.a_hostile_is_in_range())
	free_spawned()


## Facing does not matter: the enemy may turn round, and the load takes longer
## than turning does.
func _out_of_range_does_not() -> void:
	var enemy: Unit = spawn_unit(&"enemy", 10, 12, 20, [melee()], Vector3.ZERO)
	spawn_unit(&"player", 10, 12, 20, [melee()], Vector3(0.0, 0.0, enemy.max_sight_range + 2.0))
	check("a hostile beyond its sight range does not", not MusicManager.a_hostile_is_in_range())
	free_spawned()


func _neutral_does_not() -> void:
	spawn_unit(&"neutral", 10, 12, 20, [melee()], Vector3.ZERO)
	spawn_unit(&"player", 10, 12, 20, [melee()], Vector3(0.0, 0.0, 3.0))
	check("a neutral standing close does not", not MusicManager.a_hostile_is_in_range())
	free_spawned()


## The release range: a held ensemble stays held a little past where it loaded.
func _reach_widens_the_range() -> void:
	var enemy: Unit = spawn_unit(&"enemy", 10, 12, 20, [melee()], Vector3.ZERO)
	var d: float = enemy.max_sight_range * (MusicManager.RELEASE_REACH + 1.0) * 0.5
	spawn_unit(&"player", 10, 12, 20, [melee()], Vector3(0.0, 0.0, d))
	check("between the two ranges: out at 1.0", not MusicManager.a_hostile_is_in_range(1.0))
	check("between the two ranges: in at RELEASE_REACH",
		MusicManager.a_hostile_is_in_range(MusicManager.RELEASE_REACH))
	free_spawned()


func _hostiles_with_no_party_do_not() -> void:
	spawn_unit(&"enemy", 10, 12, 20, [melee()], Vector3.ZERO)
	spawn_unit(&"enemy", 10, 12, 20, [melee()], Vector3(0.0, 0.0, 2.0))
	check("enemies near each other, no party: does not", not MusicManager.a_hostile_is_in_range())
	free_spawned()


## The exploration music's intensity: 2 inside sight range, 1 approaching,
## 0 beyond APPROACH_REACH.
func _threat_level_grades_by_range() -> void:
	var enemy: Unit = spawn_unit(&"enemy", 10, 12, 20, [melee()], Vector3.ZERO)
	var sight: float = enemy.max_sight_range
	var player: Unit = spawn_unit(&"player", 10, 12, 20, [melee()], Vector3(0.0, 0.0, sight - 1.0))
	check("inside sight range: 2", MusicManager.threat_level() == 2)
	player.global_position = Vector3(0.0, 0.0, sight * (1.0 + MusicManager.APPROACH_REACH) * 0.5)
	check("approaching: 1", MusicManager.threat_level() == 1)
	player.global_position = Vector3(0.0, 0.0, sight * MusicManager.APPROACH_REACH + 2.0)
	check("far away: 0", MusicManager.threat_level() == 0)
	free_spawned()
