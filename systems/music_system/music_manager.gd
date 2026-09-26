extends Node
## Autoload singleton. Register as "MusicManager" under
## Project > Project Settings > AutoLoad, AFTER Music and WorldManager.
##
## Decides WHAT plays and WHEN; the sfzplayer director (the `Music`
## autoload) and music/transitions.json decide HOW. This file never fades,
## times or loads anything itself: it turns the moments the game already
## announces (a world on screen, a fight starting, a negotiation) into
## Music.go_to() calls, and the table says whether that lands on the next
## bar, the next section, or through the outgoing piece's ending.
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


func _ready() -> void:
	CombatManager.combat_started.connect(_on_combat_started)
	CombatManager.combat_ended.connect(_on_combat_ended)
	NegotiationManager.negotiation_started.connect(_on_negotiation_started)
	NegotiationManager.negotiation_ended.connect(_on_negotiation_ended)
	WorldManager.world_loaded.connect(_on_world_loaded)
	# Re-entering a world that stayed loaded emits world_focused and NOT
	# world_loaded, and so does switching to a group standing somewhere
	# else. Both change which area the player is in.
	WorldManager.world_focused.connect(_on_world_focused)
	# The title's music is not preloaded here: its ensemble is hundreds of MB
	# held from boot, alongside everything else the game is loading, for a
	# screen that asks for it seconds later anyway. It loads when asked.


## The director's name for an area's music at a moment. The one place the
## naming convention lives; AreaValidator asks it too.
static func music_area(area_id: StringName, moment: StringName) -> String:
	return "%s.%s" % [area_id, moment]


func play_main_menu() -> void:
	_go(MAIN_MENU)


## A restore builds every area the party stands in and fires this once per
## area, focused area last. Harmless: the director queues requests and only
## the latest one waiting goes, so the focused area is what plays.
func _on_world_loaded(_world: Node, _reason: WorldManager.Entry) -> void:
	_play_moment(EXPLORATION)


## The player is now looking at a different world, which may already have
## a fight running in it.
func _on_world_focused(_world: Node) -> void:
	_play_moment(COMBAT if CombatManager.a_watched_fight_is_running() else EXPLORATION)


## Only a fight in the world on SCREEN. Fights run in worlds the player is
## not looking at (see WorldManager residency), and scoring an unseen
## skirmish over the area the player is walking around in is wrong.
func _on_combat_started(turn_order: Array[Unit]) -> void:
	if not _is_on_screen(turn_order):
		return
	_play_moment(COMBAT, true)


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


## A negotiation_ended that also ends combat does not start the
## exploration music itself; this handler does, whichever order the two
## signals arrive in, so there is only ever one caller.
func _on_combat_ended(_winning_faction: StringName) -> void:
	# A split party can be in two fights at once, and the one that ended
	# may not be the one on screen.
	if CombatManager.a_watched_fight_is_running():
		return
	_play_moment(EXPLORATION)


func _on_negotiation_started(_demon: Unit) -> void:
	_play_moment(NEGOTIATION)


## A RECRUIT/FLEE/HEAL_PLAYER outcome can remove the last hostile and end
## combat in the same beat, so this reads live state rather than trusting
## signal order: no fight left means combat_ended already went back to
## exploration.
func _on_negotiation_ended(_outcome: int) -> void:
	if not CombatManager.any_combat_running():
		return
	_play_moment(COMBAT)


func _play_moment(moment: StringName, urgent: bool = false) -> void:
	var area: AreaDefinition = WorldManager.current_area()
	if area == null:
		return
	_go(music_area(area.id, moment), urgent, _next_likely(area.id, moment))


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
