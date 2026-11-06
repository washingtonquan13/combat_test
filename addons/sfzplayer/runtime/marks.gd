class_name SfzMarks
extends Node

# A reference, not engine: bar, section and end marks for one player, timed
# by nothing but SfzScorePlayer.next_boundary() and SfzConductor.heard() -
# the proof that those two are enough. The rest is bookkeeping: is_playing(),
# origin() and started_from() say whether to run and which start it follows,
# and score.order which sections to ask about. Copy it into a game and change
# it there.
#
# A mark fires on the first frame at or past the game time it is heard, and
# carries that time, so a late one is still exact. It follows leave_loop()
# into the outro, because next_boundary() does, and `end` comes once. There
# are no pause or replay rules; those are the game's.

signal mark(kind: String, name: String, heard_at: float)

var player: SfzScorePlayer
var kinds: Array[String] = ["bar", "section", "end"]  # fewer is less work
var _last := {}       # kind -> piece time of the last mark fired
var _origin := NAN    # which start of the player the marks are for


func _init(new_player: SfzScorePlayer = null) -> void:
	player = new_player


func _process(_delta: float) -> void:
	if player == null or not player.is_playing():
		_origin = NAN
		return
	if player.origin() != _origin:
		_origin = player.origin()
		_last = {}
	var now := Time.get_ticks_usec() / 1e6
	for kind in kinds:
		while true:
			var after := maxf(player.started_from(), _last.get(kind, -INF) + 1e-6)
			var next := _next(kind, after)
			var heard_at := player.conductor.heard(player.origin() + next[0])
			if not heard_at <= now:  # not yet, or never (INF)
				break
			_last[kind] = next[0]
			mark.emit(kind, next[1], heard_at)


# The next boundary of `kind` at or after `after`, and for a section its name.
func _next(kind: String, after: float) -> Array:
	if kind != "section":
		return [player.next_boundary(kind, after), ""]
	var best := [INF, ""]
	for name in player.score.order:
		var t := player.next_boundary("section:" + name, after)
		if t < best[0]:
			best = [t, name]
	return best
