extends Node
## Autoload singleton. Register as "MusicManager" under
## Project > Project Settings > AutoLoad, AFTER Music and WorldManager.
##
## Decides WHAT plays and WHEN; the sfzplayer director (the `Music`
## autoload) and music/transitions.json decide HOW. This file never fades,
## times or loads anything itself: it turns where the game has settled (the
## world on screen, a fight in it, a negotiation) into Music.go_to() calls,
## and the table says whether that lands on the next bar, the next section,
## or through the outgoing piece's ending.
##
## Music is named per game area and moment — "<area id>.<moment>" — and
## derived, never stored: an AreaDefinition does not say what it plays,
## the table does, under a name built from the area's own id. So a new
## area gets its music by adding three entries to the table and nothing
## else. An area the table does not know stays on whatever is already
## playing, with a warning; AreaValidator reports the gap ahead of time.
##
## The game rules that survived from the WAV-stem system, unchanged:
## combat music only for a fight in the world on SCREEN, the fight's music
## comes back after a negotiation, and the title screen has its own piece
## (see main_menu.gd).
##
## What is held in memory ahead of time is decided here too. Preloading
## stops at compiled scores (no samples): a whole ensemble held in the
## background for a fight that may never come doubled the music's memory.
## The one exception is a fight that is plausibly about to start - a hostile
## within its own sight range of the party, in the world on screen. Then the
## area's combat ensemble is loaded, so the fight's music still starts on the
## next bar, and let go again once no hostile has been in range for
## RELEASE_AFTER. Detection itself gives no warning: becoming AWARE of a
## hostile starts the fight in the same scan.

## Every piece of music asked of the director, in order, before it is
## checked against the table. What the game wanted, whatever the director
## then does with it.
signal requested(music: String)

const EXPLORATION: StringName = &"exploration"
const COMBAT: StringName = &"combat"
const NEGOTIATION: StringName = &"negotiation"
const MAIN_MENU: String = "main_menu"

## Seconds between a transition landing and the next likely music starting
## to load. An ensemble load is every layer parsing at once, and landing is
## when the area or the fight it scores is starting too: the two together are
## a hitch on a small machine that either alone is not.
const PRELOAD_DELAY := 3.0

## Names already reported missing. An area without music asks again on
## every world load and fight, and the first warning says all there is.
var _reported_missing: Dictionary[String, bool] = {}

## How often the party's surroundings are checked for a likely fight. Slower
## than DetectionManager's sweep on purpose: a load takes longer than this.
const THREAT_POLL := 0.5
## Seconds with no hostile in range before a held combat ensemble is let go.
## Long enough that walking along the edge of a camp does not load and
## unload it over and over.
const RELEASE_AFTER := 10.0
## Once held, the range that keeps it held: a little past the range that
## loaded it, for the same reason.
const RELEASE_REACH := 1.25

var _poll_elapsed := 0.0
## When a hostile was last in range, in ticks_msec.
var _threat_seen_msec := 0


## Between SaveManager.load_started and load_finished: the game is passing
## through states nobody saved, and none of them is asked for.
var _loading := false


func _ready() -> void:
	CombatManager.combat_started.connect(_on_combat_started)
	CombatManager.combat_ended.connect(_reconcile.unbind(1))
	Conversations.began.connect(_reconcile.unbind(1))
	Conversations.ended.connect(_reconcile.unbind(1))
	# Every change of the world on screen emits this: a door walked through,
	# a world that stayed loaded re-entered, a switch to a group standing
	# somewhere else. world_loaded comes after it for a new world and says
	# nothing more about where the player is.
	WorldManager.world_focused.connect(_reconcile.unbind(1))
	SaveManager.load_started.connect(_on_load_started.unbind(1))
	SaveManager.load_finished.connect(_on_load_finished.unbind(3))
	Music.preload_hold = SfzMusicDirector.Hold.SCORES
	# The game's target for resident sample audio, so the director's meter
	# warns when a load goes past it (its own default is 768 MB).
	Music.memory_budget = 256 << 20
	# The title's music is not preloaded here: its ensemble is hundreds of MB
	# held from boot, alongside everything else the game is loading, for a
	# screen that asks for it seconds later anyway. It loads when asked.


func _process(delta: float) -> void:
	_poll_elapsed += delta
	if _poll_elapsed < THREAT_POLL:
		return
	_poll_elapsed = 0.0
	_hold_combat_if_near()


## Holds the area's combat ensemble while a fight is plausibly about to
## start, and lets go of it once one is not (see the header). Only while
## exploring: in a fight or a negotiation, _go() owns what is preloaded.
func _hold_combat_if_near() -> void:
	if _loading or wanted_moment() != EXPLORATION or Music.is_busy():
		return
	var area: AreaDefinition = WorldManager.current_area()
	if area == null or not Music.table:
		return
	var combat := music_area(area.id, COMBAT)
	if not Music.table.has_area(combat):
		return
	var held := Music.preloaded() == combat
	var now := Time.get_ticks_msec()
	if a_hostile_is_in_range(RELEASE_REACH if held else 1.0):
		_threat_seen_msec = now
		if not held:
			Music.preload_area(combat, SfzMusicDirector.Hold.ENSEMBLE)
	elif held and now - _threat_seen_msec > RELEASE_AFTER * 1000.0:
		Music.release_preload()


## Whether any living hostile in the world on screen is within its own sight
## range (times `reach`) of a party member there: the distance at which
## DetectionManager starts rolling, so the earliest a fight can begin.
func a_hostile_is_in_range(reach: float = 1.0) -> bool:
	var context: WorldContext = WorldManager.context()
	var party: Array[Unit] = []
	var others: Array[Unit] = []
	for unit in UnitQuery.living_units(get_tree()):
		if context != null and not context.contains(unit):
			continue
		if unit.is_player_controlled():
			party.append(unit)
		else:
			others.append(unit)
	for other in others:
		for member in party:
			if other.get_world_3d() == member.get_world_3d() and other.is_hostile_to(member) 					and other.distance_to(member) <= other.max_sight_range * reach:
				return true
	return false


## The director's name for an area's music at a moment. The one place the
## naming convention lives; AreaValidator asks it too.
static func music_area(area_id: StringName, moment: StringName) -> String:
	return "%s.%s" % [area_id, moment]


## The title screen calls this when it shows. The music itself comes from
## _reconcile(), which knows to wait out a load.
func play_main_menu() -> void:
	_reconcile()


## A restore builds and focuses every area the party stands in, one after
## another, the saved one last. Answered step by step, each of those areas'
## music was asked for in turn - and the director never takes back a
## transition it has begun, so each one played before the next. None of them
## is where the player is until the load says so.
func _on_load_started() -> void:
	_loading = true


## Successful or not, the load is over and the game is wherever it left it.
func _on_load_finished() -> void:
	_loading = false
	_reconcile()


## Only a fight in the world on SCREEN cannot wait for a phrase to end. Fights
## run in worlds the player is not looking at (see WorldManager residency),
## and wanted_moment() already leaves those out.
func _on_combat_started(turn_order: Array[Unit]) -> void:
	_reconcile(_is_on_screen(turn_order))


## True when any of these units is in the world being looked at. No world
## loaded means nowhere else to be, so everything counts.
func _is_on_screen(units: Array[Unit]) -> bool:
	var context: WorldContext = WorldManager.context()
	if context == null:
		return true
	for unit in units:
		if is_instance_valid(unit) and context.contains(unit):
			return true
	return false


## The music the game wants, derived from where it is, never from which signal
## arrived: so the order signals arrive in cannot matter (a negotiation that
## ends a fight reports the fight's end first), and the same state asked twice
## is the same music, which the director leaves playing.
func _reconcile(urgent: bool = false) -> void:
	if _loading:
		return
	var area: AreaDefinition = WorldManager.current_area()
	if area == null:
		# No world: the front end. The title has music of its own;
		# character creation keeps whatever was playing.
		if GameMode.current_mode() == GameMode.Mode.MAIN_MENU:
			_go(MAIN_MENU)
		return
	var moment := wanted_moment()
	_go(music_area(area.id, moment), urgent, _next_likely(area.id, moment))


## The moment the game is in, from live state alone. Only a negotiation has
## music of its own; an ordinary dialogue leaves whatever the moment is. A
## split party can be in two fights at once, and only one in the world on
## screen is scored.
func wanted_moment() -> StringName:
	var c: Conversation = Conversations.current
	if c != null and c.presentation == &"negotiation":
		return NEGOTIATION
	if CombatManager.a_watched_fight_is_running():
		return COMBAT
	return EXPLORATION


## What the game may ask for next from here, loaded in the background so it
## starts on the next bar instead of after an ensemble load: a fight can
## break out anywhere, and a negotiation only happens inside one.
func _next_likely(area_id: StringName, moment: StringName) -> String:
	match moment:
		EXPLORATION:
			return music_area(area_id, COMBAT)
		COMBAT:
			return music_area(area_id, NEGOTIATION)
		NEGOTIATION:
			# Loading the negotiation's ensemble unloaded the fight's, and a
			# negotiation mostly ends back in the fight.
			return music_area(area_id, COMBAT)
	return ""


## go_to() queues behind a transition under way and only the latest request
## waits, so this is fire-and-forget. The preload follows the transition
## rather than racing it: the director refuses to preload mid-transition. It
## also waits PRELOAD_DELAY, and does not happen at all if the music has
## moved on meanwhile - the preload is for what may follow this music.
func _go(music: String, urgent: bool = false, preload_next: String = "") -> void:
	requested.emit(music)
	if not Music.table or not Music.table.has_area(music):
		if not _reported_missing.has(music):
			_reported_missing[music] = true
			push_warning("MusicManager: no music called '%s' in the transitions table" % music)
		return
	if not await Music.go_to(music, urgent):
		return
	if preload_next == "" or not Music.table.has_area(preload_next):
		return
	await get_tree().create_timer(PRELOAD_DELAY).timeout
	if Music.area == music and not Music.is_busy():
		Music.preload_area(preload_next)
