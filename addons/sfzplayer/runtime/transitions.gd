class_name SfzTransitions
extends RefCounted

# What happens between two areas' music, as data.
#
# The game decides where the player is going and when; that is gameplay, and
# the music has no business second-guessing it. How the music gets there is a
# composer's decision - whether the town theme finishes its phrase or is cut
# at the next barline, whether the battle arrives with a drum fill, how long
# the old piece takes to fade - and a composer's decision belongs in a file a
# composer can edit, not in a script. So the game calls go_to("battle") and
# this table says what that means coming from wherever the music is now.
#
# music/transitions.json:
#
#   "areas": {
#     "field":  { "ensemble": "wayfarer", "score": "long-time-way" },
#     "battle": { "ensemble": "band", "score": "low-end" }
#   },
#   "rules": [
#     { "from": "*", "to": "*",      "exit": "bar",  "fade": 2.0 },
#     { "from": "*", "to": "battle", "exit": "bar",  "fade": 0.8,
#       "urgent": true, "sting": "battle-sting" },
#     { "from": "battle", "to": "*", "exit": "section", "outro": true }
#   ]
#
# A rule's fields, all optional but `from` and `to`:
#
#   exit     where the outgoing piece is left: "now", or the next "beat",
#            "bar", "section" or "pass" (the end of the loop). The incoming
#            piece's first downbeat lands exactly there.
#   outro    true to play the outgoing piece's ending first, and start the
#            incoming one where the ending ends. Otherwise the outgoing piece
#            just stops at the exit, its last notes ringing off.
#   fade     seconds the outgoing music takes to fade once the incoming one
#            has begun - mostly its reverb and its releases; with "now", the
#            crossfade.
#   crossfade  true: the outgoing piece does not stop at the exit but plays
#            on under the incoming one while it fades, and is let go at the
#            first bar after the fade. For two pieces that share a key and a
#            tempo, a handoff with no seam at all; for two that do not, a
#            clash, which is why it is a choice.
#   fade_in  seconds the incoming music takes to come up. 0: it starts at
#            full level, which is right for a piece that begins on a downbeat.
#   sting    a score, played on the incoming ensemble at the exit, with the
#            incoming piece starting when it ends.
#   urgent   the game cannot wait: if the exit is further off than
#            `max_wait`, the next sooner one is taken - pass, section, bar,
#            beat, now - and there is no ending. The game can also ask for this
#            itself, per call, for the moment an ambush has to sound now.
#   max_wait seconds an urgent exit may take (default 2.0).
#   pick_up  true: an area the player has been to before comes back in at
#            the bar its music was left at, not from the top - the field
#            after a battle. Best with a fade_in; an area not yet visited
#            starts from the top as usual.
#
# Rules are matched most specific first: an exact from and to, then an exact
# to, then an exact from, then "*" to "*". The first matching rule of the
# most specific kind wins, and its fields are laid over the defaults below.

const EXITS: Array[String] = ["pass", "section", "bar", "beat", "now"]

const DEFAULTS := {
	"exit": "bar", "outro": false, "fade": 2.0, "fade_in": 0.0,
	"sting": "", "urgent": false, "max_wait": 2.0, "crossfade": false,
	"pick_up": false,
}

var areas: Dictionary = {}     # area -> {ensemble, score}
var rules: Array = []


static func load_from(path: String) -> SfzTransitions:
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		push_error("Transitions: cannot read %s" % path)
		return null
	var data: Variant = JSON.parse_string(text)
	if not data is Dictionary:
		push_error("Transitions: %s is not a JSON object" % path)
		return null
	var table := SfzTransitions.new()
	table.areas = data.get("areas", {})
	table.rules = data.get("rules", [])
	for area in table.areas:
		var entry: Dictionary = table.areas[area]
		if not entry.has("ensemble") or not entry.has("score"):
			push_error("Transitions: area '%s' needs an ensemble and a score" % area)
			return null
	for rule: Dictionary in table.rules:
		if not rule.has("from") or not rule.has("to"):
			push_error("Transitions: a rule needs a from and a to: %s" % rule)
			return null
		if rule.has("exit") and not EXITS.has(rule["exit"]):
			push_error("Transitions: no exit called '%s' (%s)" % [rule["exit"], ", ".join(EXITS)])
			return null
		for key in rule:
			if key != "from" and key != "to" and not DEFAULTS.has(key):
				push_warning("Transitions: unknown rule field '%s'" % key)
	return table


func has_area(area: String) -> bool:
	return areas.has(area)


func ensemble_path(area: String) -> String:
	return SfzSettings.ensemble_path(areas[area]["ensemble"])


func score_path(area: String) -> String:
	return SfzSettings.score_path(areas[area]["score"])


static func sting_path(sting: String) -> String:
	return SfzSettings.score_path(sting)


# The rule for going from `from` ("" when nothing is playing) to `to`, with
# every field filled in.
func rule(from: String, to: String, urgent: bool = false) -> Dictionary:
	var best: Dictionary = {}
	var best_rank := -1
	for candidate: Dictionary in rules:
		var f: String = candidate["from"]
		var t: String = candidate["to"]
		if (f != "*" and f != from) or (t != "*" and t != to):
			continue
		var rank := (2 if t == to else 0) + (1 if f == from else 0)
		if rank > best_rank:
			best = candidate
			best_rank = rank
	var out := DEFAULTS.duplicate()
	for key in best:
		out[key] = best[key]
	out["urgent"] = bool(out["urgent"]) or urgent
	# Nothing playing: there is nothing to wait for and nothing to fade.
	if from == "":
		out["exit"] = "now"
		out["outro"] = false
		out["sting"] = ""
	return out


# Leaves `player` as `rule` says, `now` seconds into it, and returns where the
# incoming music begins, in seconds from the top of the outgoing piece:
#
#   {exit, start, how, outro}
#
# `exit` is where the outgoing piece stops being written - the cut, or where
# its ending begins - and `start` is where the incoming one takes over: the
# exit, or with an ending, the end of it. With "now" both are `now`, and the
# outgoing piece is still left, at its next bar with no ending, so that it
# stops like music under the fade rather than being switched off.
static func leave(player: SfzScorePlayer, rule: Dictionary, now: float) -> Dictionary:
	var how: String = rule["exit"]
	var outro: bool = rule["outro"]
	if player == null or player.score == null:
		return {"exit": now, "start": now, "how": "now", "outro": false}

	if rule["urgent"]:
		# No time for an ending, and no time for a far exit.
		outro = false
		var wait: float = rule["max_wait"]
		var i := EXITS.find(how)
		while how != "now" and player.peek_exit(how, false) - now > wait:
			i += 1
			how = EXITS[i]

	if how == "now":
		player.leave_loop("bar", false)
		return {"exit": now, "start": now, "how": "now", "outro": false}

	if rule["crossfade"] and not outro:
		# The handoff is where the exit would have been; the piece itself
		# carries on under the fade and stops at the first bar past it.
		var at := player.peek_exit(how, false)
		var stop := player.leave_loop("bar", false, at + float(rule["fade"]))
		return {"exit": at, "start": at, "how": how, "outro": false, "stop": stop}

	var exit := player.leave_loop(how, outro)
	var start := player.length() if outro else exit
	return {"exit": exit, "start": start, "how": how, "outro": outro}
