class_name SfzScoreParser
extends RefCounted

# Reads the .score text format into a SfzScore.
#
# The format is line-oriented on purpose: it has to be pleasant to write by
# hand, to diff, and to point at when something is wrong. A parser that says
# "sealed-ward.score:34: lane 'lead' reaches a bar line 3.5 beats into a bar" is
# worth more than one that accepts everything and produces a limp.
#
#   // comments run to end of line
#   title: Sealed Ward
#   ensemble: combo
#   parts: lead bass pad perc
#   tempo: 72
#   meter: 4/4
#   key: d minor
#   order: intro verse turn
#
# Brackets in the order mark a loop, the sections a game plays over and over
# until something happens: `order: intro [fight fight2] victory`. Whatever is
# before the bracket plays once, the bracket repeats, and what follows it is
# the way out.
#
#   section verse bars:8
#     lead dyn:mp art:sustain rot:slow
#       | d4:3~ f4:1 | a4:4^ |
#     perc dyn:p feel:loose pocket:push
#       | kick:1 r:1 hat:0.5 r:0.5 kick:1 |
#
# `parts:` declares the parts the lanes name, each `NAME[:FAMILY][@PLAYER]`.
# The family says what kind of part it is (SfzEnsemble.FAMILIES), and is what an
# ensemble without a part of that name plays it on; it defaults to the name,
# so `bass` is `bass:bass`. `high:choir@lead` is a co-part: a part of its own,
# cast on its own instruments, played by the same performer as `lead` - one
# pocket, one drift, one pair of hands. A score with no `parts:` declares the
# six base families, lead guitar keys bass pad perc.
#
# A part may be split into sub-lanes - `perc.right`, `perc.left`,
# `perc.feet` - each its own lane with its own line of bars. That is how drums
# are written on paper, limbs as separate stems, and it is the only way to
# write a kick under a hi-hat, since a lane plays one thing at a time. The sub
# name is the writer's; a sub-lane plays exactly its part's instruments.
#
# A section can start as a copy of an earlier one - `section reprise from:riff`
# - and then write only what changes. A lane written in the copy replaces the
# inherited lane of the same name (or, for a part written whole, all of that
# part's inherited sub-lanes, and a player's co-parts too); everything not
# written plays as it did. That is how a reprise is actually built: the same
# band, with something added on top.
#
# A token is HEAD[:DURATION][MARKS]. HEAD is a note name (d4, f#3, bb2), a
# chord ([d3 f3 a3]), a rest (r), or a drum name (kick) - anything that is
# not a note name is taken as a drum, which is what keeps the score from
# knowing any library's keymap. DURATION is in beats and defaults to 1.
# MARKS are ! accent, . soft, ' staccato, _ tenuto, ~ slur, ^ swell, + muted,
# and the four slides: / slides into the next note, \ glides into it the way
# a mono synth does (arriving on the beat and retuning), < scoops into this
# one from below, > falls off the end of it.
# Short and muted are different sounds: ' is a note cut short, + is a note
# damped at the string (a palm mute, a stopped horn), which is short by nature
# and dark besides. They combine with the rest - `e2:0.25+!` is a hard chug.
#
# `layer:2` puts a lane in an intensity layer: it plays only while the game
# has the music's intensity at 2 or above (`layer:0..1`, only at 0 and 1).
# See SfzScorePlayer.set_intensity().
#
# A lane on an ensemble with a pitch wheel can also be given a written bend,
# `bend:+200@0.4,+200@2,0@3.5`, which every note in it follows - see
# _bend_shape below.
#
# `|` is a checkpoint rather than a container: it asserts that the cursor has
# landed on a bar boundary. That way a note may cross the barline (a pad
# holding 8 beats is written once, not tied) while a bar that adds up to 3.5
# beats is still caught. A lane must also fill its section's `bars:` exactly,
# rests included: one that stops short is refused at its last line, and one
# that runs past at the line that ran past.
#
# A lane reports its first error and no more, and every error inside a lane
# names it. A note that failed to parse took no time, so every bar after it
# would be reported short too, and one typo would read as a page of faults.
# The same goes for a line that should have started a lane and did not: the
# bar lines under it are skipped rather than reported as bars with no lane.
#
# Reuse below the section is written out here, in the parser, so that nothing
# downstream - compiler, player, MIDI export - ever sees it:
#
#   include: grooves.score        // its patterns and chords, nothing else
#   chord minor7 = [a3 c4 e4 g4]
#   pattern riff
#     | d4:1 f4:1 a4:1 d5:1 | c5:2 a4:2 |
#
# and in a lane, `| riff | riff+5 | % | minor7:4 | hat:0.5*8 |`. A pattern
# is whole bars of one lane, used where a bar starts, optionally moved by
# semitones (drums stay where they are). `%` plays again what was written
# between the last two bar lines, `*N` plays one token N times, and a chord
# name stands wherever a [chord] could. All of it must be defined above its
# first use. Errors inside a pattern are reported at the line that used it,
# and name the pattern's own line as well.

const MARKS := "!.'_~^+/\\<>"
const BROKEN := "?"  # the value of a chord whose definition was refused
const HEADERS := ["title", "ensemble", "parts", "tempo", "meter", "key", "order", "include"]
const MODES := ["minor", "major"]  # what the MIDI export can write as a key signature
const BEAT_UNITS := [1, 2, 4, 8, 16, 32]
const USE := "^([A-Za-z_][A-Za-z0-9_.#-]*?)([+-][0-9]+)?$"
const SECTION_SETTINGS := ["bars", "tempo", "repeat", "from"]
const LANE_SETTINGS := ["dyn", "art", "feel", "vib", "pocket", "bend", "rot", "shape", "layer"]

var errors: Array[String] = []

var _score: SfzScore
var _path: String = ""
var _section: SfzScore.Section = null
var _lane: SfzScore.Lane = null
var _inherited := {}  # lane names the current section copied with from:, not yet overwritten
var _cursor: float = 0.0       # beats into the current lane
var _lane_line := 0            # the line of the lane's header
var _lane_last := 0            # the last line that played into it
var _lane_errors := 0          # errors.size() when its bars began
var _lane_over := false        # its overrun has been reported
var _bar_faults := 0           # bar lines reached off a bar, so far
var _explicit_order: Array[String] = []
var _loop_open := -1     # index into _explicit_order where the loop starts
var _loop_close := -1    # and where it has stopped, exclusive
var _order_line := 0     # where order: was written, for the errors it causes
var _headers := {}       # header -> the line it was first given on
var _skip_bars := false  # the lane header above failed; its bar lines are not read

# Reuse. A pattern is {name, path, line, tokens: [[token, line], ...]}.
var _patterns := {}
var _chords := {}        # name -> "[a3 c4 e4]"
var _pattern = null      # the pattern whose bar lines are being read, if any
var _including: Array[String] = []  # files this parse is inside of, for cycles
var _bar: Array = []     # [token, transpose, context] written since the last bar line
var _last_bar: Array = []  # the same for the bar before, which `%` plays again
var _use_re := RegEx.create_from_string(USE)
var _times_re := RegEx.create_from_string("\\*([0-9]+)$")
var _drum_re := RegEx.create_from_string("^[A-Za-z_][A-Za-z0-9_]*$")
var _shift_re := RegEx.create_from_string("^([A-Za-z_][A-Za-z0-9_]*)[+-](.*)$")
var _voice_re := RegEx.create_from_string("^[A-Za-z0-9_]+$")
var _part_re := RegEx.create_from_string("^([a-z][a-z0-9_]*)(?::([a-z][a-z0-9_]*))?(?:@([a-z][a-z0-9_]*))?$")
var _parts_given := false  # the score wrote a parts: header, even a refused one


static func parse_file(path: String) -> SfzScore:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("ScoreParser: cannot open '%s'" % path)
		return null
	var parser := SfzScoreParser.new()
	var score := parser.parse(file.get_as_text(), path)
	if score != null:
		score.id = path.get_file().get_basename()
	return score


func parse(text: String, path: String = "<score>") -> SfzScore:
	errors.clear()
	_read(text, path)
	_build_order()
	_declare_implicit()

	if _score.order.is_empty():
		_err(0, "score has no sections to play")
	if not errors.is_empty():
		for e in errors:
			push_error(e)
		return null
	return _score


func _read(text: String, path: String) -> void:
	_path = path
	_score = SfzScore.new()
	_including.append(_canonical(path))
	var lines := text.split("\n")
	for i in lines.size():
		var line := _strip(lines[i])
		if line.is_empty():
			continue
		_line(line, i + 1)
	_finish_lane()
	_finish_section()


# --- Lines ---------------------------------------------------------------

func _line(line: String, n: int) -> void:
	if line.begins_with("|"):
		if _pattern != null:
			for token in _bar_tokens(line):
				_pattern["tokens"].append([token, n])
			return
		if _skip_bars:
			return
		if _lane == null:
			_err(n, "bars before any lane")
			return
		_bars(line, n)
		return

	# Anything that is not a bar line closes a pattern.
	_pattern = null
	_skip_bars = false
	var tokens := _words(line)
	var head := tokens[0]

	if head == "section":
		_finish_lane()
		_finish_section()
		_start_section(tokens, n)
		return

	if head == "pattern" or head == "chord":
		_finish_lane()
		_finish_section()
		if head == "pattern":
			_start_pattern(tokens, n)
		else:
			_define_chord(line.substr(5).strip_edges(), n)
		return

	if _section != null:
		_declare_implicit()
	if _section != null and _score.parts.has(head.get_slice(".", 0)):
		_finish_lane()
		_start_lane(tokens, n)
		return

	if _section != null:
		# An unrecognised header would otherwise let the bars that follow it
		# pile onto the previous lane, turning one typo into a page of
		# errors. Drop the lane instead and wait for the next valid header.
		_finish_lane()
		_err(n, "lane '%s': '%s' is not a declared part (%s); a section holds lanes, bar lines and the next 'section'"
				% [head, head.get_slice(".", 0), ", ".join(_score.parts.keys())])
		_skip_bars = true
		return

	_header(line, n)


# Song header: `key: value`, one per line, before the first section.
func _header(line: String, n: int) -> void:
	var split := line.split(":", true, 1)
	if split.size() < 2:
		_err(n, "expected 'key: value', got '%s'" % line)
		return
	var key := split[0].strip_edges().to_lower()
	var value := split[1].strip_edges()

	# Only include can be said twice: a second tempo: or order: would quietly
	# replace the first, and which one the author meant is not ours to pick.
	if HEADERS.has(key) and key != "include":
		if _headers.has(key):
			_err(n, "header '%s' is given twice (first on line %d)" % [key, _headers[key]])
			return
		_headers[key] = n
	if value.is_empty() and HEADERS.has(key):
		_err(n, "header '%s' has no value" % key)
		return

	match key:
		"title":
			_score.title = value
		"ensemble":
			_score.ensemble_id = value
		"parts":
			_parts(value, n)
		"tempo":
			_score.tempo = _above_zero(value, n, "tempo")
		"meter":
			var parts := value.split("/")
			if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int() \
					or parts[0].to_int() < 1 or not parts[1].to_int() in BEAT_UNITS:
				_err(n, "meter should look like 4/4 (a beat of 1, 2, 4, 8, 16 or 32), got '%s'"
						% value)
				return
			_score.beats_per_bar = parts[0].to_int()
			_score.beat_unit = parts[1].to_int()
		"key":
			# A key is a pitch class: "d4 minor" names an octave no key has,
			# and parse_note would take it with the appended 0 as octave 40.
			var parts2 := _words(value)
			var root := SfzScore.parse_note(parts2[0] + "0")
			if root < 0 or parts2.size() > 2 or parts2[0].to_lower().substr(1).lstrip("#bsf") != "":
				_err(n, "key should look like 'd minor', got '%s'" % value)
				return
			var mode := parts2[1].to_lower() if parts2.size() > 1 else "minor"
			if not mode in MODES:
				_err(n, "'%s' is not a mode (%s)" % [parts2[1], ", ".join(MODES)])
				return
			_score.key_root = root % 12
			_score.key_mode = mode
		"order":
			_order(value, n)
		"include":
			_include(value, n)
		_:
			_err(n, "unknown header '%s' (%s)" % [key, ", ".join(HEADERS)])


# `parts: lead high:choir@lead bass`. Each entry is checked on its own, and
# the players once every name is known, since a co-part may be written before
# its player.
func _parts(value: String, n: int) -> void:
	_parts_given = true
	var players := {}  # co-part -> its player, checked below
	for entry in _words(value):
		var m := _part_re.search(entry)
		if m == null:
			_err(n, "'%s' in parts is not NAME, NAME:FAMILY or NAME:FAMILY@PLAYER (lower case, a letter first)"
					% entry)
			continue
		var name := m.get_string(1)
		var family := m.get_string(2)
		if family == "":
			if not SfzEnsemble.FAMILIES.has(name):
				_err(n, "part '%s' is not a family, so it needs one: '%s:FAMILY' (%s)"
						% [name, name, ", ".join(SfzEnsemble.FAMILIES.keys())])
				continue
			family = name
		elif not SfzEnsemble.FAMILIES.has(family):
			_err(n, "part '%s' has family '%s', which is not one (%s)"
					% [name, family, ", ".join(SfzEnsemble.FAMILIES.keys())])
			continue
		if _score.parts.has(name):
			_err(n, "part '%s' is declared twice" % name)
			continue
		_score.parts[name] = {"family": family, "player": name}
		if m.get_string(3) != "":
			players[name] = m.get_string(3)
	for name in players:
		var player: String = players[name]
		if not _score.parts.has(player):
			_err(n, "part '%s' is played by '%s', which parts does not declare" % [name, player])
			_score.parts.erase(name)
		elif players.has(player):
			_err(n, "part '%s' is played by '%s', which is itself played by '%s'; a player cannot be a co-part"
					% [name, player, players[player]])
			_score.parts.erase(name)
		else:
			_score.parts[name]["player"] = player


# Without a parts: header a score is written in the six base families, each its
# own family and its own player. Called at the first lane, once the header is
# past, and again at the end for a score with no sections.
func _declare_implicit() -> void:
	if _parts_given or not _score.parts.is_empty():
		return
	for family in SfzEnsemble.BUSES:
		_score.parts[family] = {"family": family, "player": family}


# `order: intro [a b] end`. At most one pair of brackets, around at least one
# section. The first thing wrong with it is reported, once: a second loop
# otherwise reads as a stray ']' as well.
func _order(value: String, n: int) -> void:
	_order_line = n
	var fault := ""
	for word in _words(value):
		var name: String = word
		var opens := name.begins_with("[")
		if opens:
			name = name.substr(1)
		var closes := name.ends_with("]")
		if closes:
			name = name.left(-1)
		if fault == "" and (name.contains("[") or name.contains("]")):
			fault = "'%s' in order is not a section name" % word
		if opens and fault == "":
			if _loop_open >= 0:
				fault = "order can have only one loop"
			_loop_open = _explicit_order.size()
		if not name.is_empty():
			_explicit_order.append(name)
		if closes and fault == "":
			if _loop_open < 0 or _loop_close >= 0:
				fault = "order has a ']' with no '[' before it"
			_loop_close = _explicit_order.size()
	if fault == "" and _loop_open >= 0 and _loop_close < 0:
		fault = "order opens a loop with '[' and never closes it"
	elif fault == "" and _loop_open >= 0 and _loop_close <= _loop_open:
		fault = "order has an empty loop"
	if fault != "":
		_err(n, fault)
		_loop_open = -1
		_loop_close = -1


# --- Reuse ---------------------------------------------------------------

# A pattern line that is refused still owns the bar lines under it, and a
# name it gave still stands, so neither is reported again as something else.
func _start_pattern(tokens: Array[String], n: int) -> void:
	var name := tokens[1] if tokens.size() > 1 else ""
	_pattern = {"name": name, "path": _path, "line": n, "tokens": []}
	if tokens.size() != 2:
		_err(n, "pattern needs a name and nothing else, like 'pattern riff'")
		if _free_name(name):
			_patterns[name] = _pattern
		return
	if _reusable_name(name, "pattern", n):
		_patterns[name] = _pattern


# `chord minor7 = [a3 c4 e4 g4]`, the = optional.
# A chord that is refused is still defined, as BROKEN, so that where it is
# used takes its time and says nothing: its one error is here.
func _define_chord(rest: String, n: int) -> void:
	var name := rest.get_slice(" ", 0).strip_edges()
	var value := rest.substr(name.length()).strip_edges().trim_prefix("=").strip_edges()
	if name.is_empty() or not value.begins_with("[") or not value.ends_with("]"):
		_err(n, "a chord is written 'chord NAME = [a3 c4 e4]'")
		if _free_name(name):
			_chords[name] = BROKEN
		return
	if not _reusable_name(name, "chord", n):
		return
	var notes := _words(value.substr(1, value.length() - 2))
	if notes.is_empty():
		_err(n, "chord '%s' is empty" % name)
		_chords[name] = BROKEN
		return
	for note in notes:
		var key := SfzScore.parse_note(note)
		if key < 0 or key > 127:
			_err(n, "'%s' in chord '%s' is not a note name in the MIDI range" % [note, name])
			_chords[name] = BROKEN
			return
	_chords[name] = "[%s]" % " ".join(notes)


# Whether `name` could be a pattern or chord and is not one yet, asked
# without reporting anything.
func _free_name(name: String) -> bool:
	var m := _use_re.search(name)
	return m != null and m.get_string(2) == "" and name != "r" \
			and SfzScore.parse_note(name) < 0 and not _patterns.has(name) and not _chords.has(name)


# A name that a bar could mistake for something else would silently change
# what plays, so it is refused where it is defined.
func _reusable_name(name: String, what: String, n: int) -> bool:
	var m := _use_re.search(name)
	if m == null or m.get_string(2) != "" or name == "r" or SfzScore.parse_note(name) >= 0:
		_err(n, "'%s' cannot name a %s: use letters, digits and _, not a note name" % [name, what])
		return false
	if _patterns.has(name) or _chords.has(name):
		_err(n, "'%s' is already a pattern or chord" % name)
		return false
	return true


# `include: drums.score` - the patterns and chords of another file, read
# relative to this one, else from res://scores. Its sections, headers and
# order stay behind; it is a library, not a medley.
func _include(value: String, n: int) -> void:
	if value.is_empty():
		_err(n, "include needs a file")
		return
	var path := value
	if not value.contains("://") and not value.is_absolute_path():
		path = _path.get_base_dir().path_join(value)
		if not FileAccess.file_exists(path):
			path = "res://scores".path_join(value)
	var key := _canonical(path)
	if _including.has(key):
		_err(n, "include cycle: %s -> %s" % [" -> ".join(_including.map(func(f): return f.get_file())), value])
		return
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_err(n, "cannot include '%s': no such file here or in res://scores" % value)
		return
	var child := SfzScoreParser.new()
	child._including = _including.duplicate()
	child._read(file.get_as_text(), path)
	errors.append_array(child.errors)
	for name in child._patterns:
		var p: Dictionary = child._patterns[name]
		var had = _patterns.get(name)
		if had != null and _canonical(had["path"]) == _canonical(p["path"]) and had["line"] == p["line"]:
			continue  # the same library reached twice, not a clash
		if _reusable_name(name, "pattern", n):
			_patterns[name] = p
	for name in child._chords:
		if _chords.get(name) == child._chords[name]:
			continue
		if _reusable_name(name, "chord", n):
			_chords[name] = child._chords[name]


func _canonical(path: String) -> String:
	if path.begins_with("res://") or path.begins_with("user://"):
		return ProjectSettings.globalize_path(path).simplify_path()
	return path.simplify_path()


func _start_section(tokens: Array[String], n: int) -> void:
	if tokens.size() < 2:
		_err(n, "section needs a name")
		return
	var section := SfzScore.Section.new()
	section.name = tokens[1]
	var source: SfzScore.Section = null
	var had := errors.size()
	for i in range(2, tokens.size()):
		var pair := _pair(tokens[i], n)
		if pair.is_empty():
			continue
		match pair[0]:
			"bars":
				section.bars = _whole(pair[1], n, "bars")
			"tempo":
				section.tempo = _above_zero(pair[1], n, "tempo")
			"repeat":
				section.repeat = maxi(1, _whole(pair[1], n, "repeat"))
			"from":
				source = _score.sections.get(pair[1])
				if source == null:
					_err(n, "section '%s' copies '%s', which is not defined above it"
							% [section.name, pair[1]])
			_:
				_err(n, "unknown section setting '%s' (%s)" % [pair[0], ", ".join(SECTION_SETTINGS)])
	_inherited.clear()
	if source != null:
		if section.bars <= 0:
			section.bars = source.bars
		elif section.bars != source.bars:
			_err(n, "section '%s' has %d bars but copies '%s', which has %d"
					% [section.name, section.bars, source.name, source.bars])
		if section.tempo == 0.0:
			section.tempo = source.tempo
		for name in source.lanes:
			section.lanes[name] = source.lanes[name]
			_inherited[name] = true
	# One fault on the line is enough: a bars: that was refused, or a from:
	# that named nothing, would otherwise also read as bars: left out.
	if section.bars <= 0 and errors.size() == had:
		_err(n, "section '%s' needs bars:N" % section.name)
	if _score.sections.has(section.name):
		_err(n, "section '%s' is defined twice" % section.name)
	_section = section


func _start_lane(tokens: Array[String], n: int) -> void:
	var lane := SfzScore.Lane.new()
	var head := tokens[0]
	lane.part = head.get_slice(".", 0)
	lane.sub = head.substr(lane.part.length() + 1)
	lane.player = _score.parts[lane.part]["player"]
	lane.base = SfzEnsemble.base_family(_score.parts[lane.player]["family"])
	# A co-part's lanes are named after its player, `lead.high`: the lane name
	# is the performance name, and the seed the performance compiler draws.
	lane.name = head if lane.player == lane.part else "%s.%s" % [lane.player, head]
	# The whole of the lane's part, as a performance name: `lead`, `lead.high`.
	var whole := lane.name if lane.sub == "" else lane.name.left(-(lane.sub.length() + 1))
	_lane = lane
	_lane_errors = errors.size()
	if head != lane.part and not _voice_re.search(lane.sub):
		_err(n, "'%s' is not a lane name: a part, or a part and a sub-lane like perc.feet"
				% head)
	# A lane replaces what it covers: the same lane, the whole player (a lane
	# of any of its parts displaces that), the whole of its own part, and -
	# for a whole-part lane - everything under it.
	for other in _inherited.keys():
		if other == lane.name or other == lane.player or other == whole or (lane.sub == ""
				and other.begins_with(lane.name + ".")):
			_section.lanes.erase(other)
			_inherited.erase(other)
	if _section.lanes.has(lane.name):
		_err(n, "lane '%s' appears twice in section '%s'" % [head, _section.name])
	elif (lane.name != lane.player and _section.lanes.has(lane.player)) \
			or (lane.sub != "" and _section.lanes.has(whole)) \
			or (lane.sub == "" and _section.lanes.keys().any(
				func(other): return other.begins_with(lane.name + "."))):
		_err(n, "lane '%s' mixes a whole-part lane with its sub-lanes or co-parts in section '%s'"
				% [head, _section.name])
	for i in range(1, tokens.size()):
		var pair := _pair(tokens[i], n)
		if pair.is_empty():
			continue
		match pair[0]:
			"dyn":
				var ramp := pair[1].split("..")
				lane.dyn_from = ramp[0]
				lane.dyn_to = ramp[1] if ramp.size() > 1 else ""
				var known := ramp.size() <= 2
				for d in ramp:
					known = known and SfzScore.DYNAMICS.has(d)
				if not known:
					_err(n, "'%s' is not a dynamic (ppp through fff, or a ramp like p..f)"
							% pair[1])
			"art":
				lane.art = pair[1]
			"feel":
				# The feels are the performance compiler's timing table; a
				# name it does not have would quietly play as straight.
				var feels: Array = SfzPerformanceCompiler.JITTER.keys()
				if not feels.has(pair[1]):
					_err(n, "lane '%s': '%s' is not a feel (%s)"
							% [lane.name, pair[1], ", ".join(feels)])
				lane.feel = pair[1]
			"vib":
				if not SfzScore.VIBRATO.has(pair[1]):
					_err(n, "'%s' is not a vibrato (%s)"
							% [pair[1], ", ".join(SfzScore.VIBRATO.keys())])
				lane.vib = pair[1]
			"pocket":
				if SfzScore.POCKETS.has(pair[1]):
					lane.pocket = SfzScore.POCKETS[pair[1]]
				elif pair[1].is_valid_float():
					lane.pocket = pair[1].to_float() / 1000.0
				else:
					_err(n, "'%s' is not a pocket (%s, or milliseconds)"
							% [pair[1], ", ".join(SfzScore.POCKETS.keys())])
			"bend":
				lane.bend = _bend_shape(pair[1], n)
			"rot":
				if pair[1] != "slow" and pair[1] != "fast":
					_err(n, "'%s' is not a rotary speed (slow or fast)" % pair[1])
				lane.rot = pair[1]
			"shape":
				if not SfzScore.SHAPE.has(pair[1]):
					_err(n, "'%s' is not a phrase shape (%s)"
							% [pair[1], ", ".join(SfzScore.SHAPE.keys())])
				lane.shape = pair[1]
			"layer":
				lane.layer = _layer(pair[1], n)
			_:
				_err(n, "unknown lane setting '%s' (%s)" % [pair[0], ", ".join(LANE_SETTINGS)])
	_cursor = 0.0
	_bar = []
	_last_bar = []
	_lane_line = n
	_lane_last = n
	_lane_over = false


# `layer:2` plays from intensity 2 up, `layer:0..1` only at 0 and 1, and
# `layer:..1` is the same as `layer:0..1`. Levels are whole numbers from 0.
func _layer(value: String, n: int) -> Array:
	var ends := value.split("..")
	var lo := ends[0] if ends[0] != "" else "0"
	var hi := ends[1] if ends.size() > 1 and ends[1] != "" else ""
	if ends.size() > 2 or not lo.is_valid_int() or (hi != "" and not hi.is_valid_int()) \
			or (ends.size() == 2 and ends[0] == "" and hi == ""):
		_err(n, "'%s' is not a layer (2, 1..3, ..1, 2..)" % value)
		return []
	var low := lo.to_int()
	var high := hi.to_int() if hi != "" else 1 << 30
	if low < 0 or high < low:
		_err(n, "layer %s is empty: levels are 0 and up, lowest first" % value)
		return []
	return [low, high]


# `bend:+200@0.4,+200@2,0@3.5` - the pitch shape every note in the lane
# follows, in cents at beats from its start, from no bend at the start. The
# marks bend by rule; this is for the one gesture no rule makes, written out
# the way a player would describe it: up a tone at once, hold it, let it sag
# back. Points must go forward in time.
func _bend_shape(value: String, n: int) -> Array:
	var shape: Array = []
	var last := -1.0
	for point in value.split(","):
		var parts := point.split("@")
		if parts.size() != 2 or not parts[0].is_valid_float() or not parts[1].is_valid_float():
			_err(n, "bend point '%s' should look like +200@0.5 (cents at beats)" % point)
			return []
		var at := parts[1].to_float()
		if at <= last:
			_err(n, "bend points must go forward in time; '%s' does not" % point)
			return []
		last = at
		shape.append([at, parts[0].to_float()])
	return shape


# --- Bars ----------------------------------------------------------------

func _bars(line: String, n: int) -> void:
	var tokens: Array = []
	for token in _bar_tokens(line):
		tokens.append([token, 0])
	_play(tokens, n, 0, "", "", [])
	_lane_last = n
	_overrun(n, "")


# Reports, once, a lane that has gone past the end of its section. Past the
# end, a bar line off the bar is the same fault seen from nearer, so a bar
# line asks this first too.
func _overrun(n: int, where: String) -> bool:
	var limit := _section.beats(_score.beats_per_bar)
	if limit <= 0.0 or _lane_over or _cursor <= limit + 0.001 or not _lane_clean():
		return false
	_lane_over = true
	_err(n, "lane '%s' runs %.2f beats past the end of section '%s'%s" % [
		_lane.name, _cursor - limit, _section.name, where])
	return true


# Plays a run of bar tokens into the lane. `n` is always the line in this file
# that asked for them; a pattern's tokens carry their own line besides, which
# goes into `context` so an error can point at both.
func _play(tokens: Array, n: int, transpose: int, context: String, inside: String,
		stack: Array) -> void:
	for item in tokens:
		var token: String = item[0]
		var where := context
		if inside != "":
			var p: Dictionary = _patterns[inside]
			where = " (in pattern '%s', %s:%d)%s" % [inside, p["path"].get_file(), item[1], context]

		if token == "|":
			_checkpoint(n, where)
			continue

		if token == "%":
			if not _on_bar():
				_err(n, "'%%' must start a bar, in lane '%s'%s" % [_lane.name, where])
				continue
			if _last_bar.is_empty():
				_err(n, "'%%' has no bar before it to repeat, in lane '%s'%s" % [_lane.name, where])
				continue
			for again in _last_bar.duplicate():
				_note(again[0], n, again[1], again[2])
			continue

		var times := 1
		var star := _times_re.search(token)
		if star != null:
			times = star.get_string(1).to_int()
			token = token.substr(0, star.get_start())
			if times < 1:
				_err(n, "'*%d' plays nothing; use *1 or more%s" % [times, where])
				continue

		var use := _use_re.search(token)
		if use != null and _patterns.has(use.get_string(1)):
			for _i in times:
				_use(use.get_string(1), use.get_string(2), n, transpose, where, stack)
			continue
		if use != null and use.get_string(2) != "":
			_err(n, "'%s' is not a pattern, so it cannot be moved by %s%s"
					% [use.get_string(1), use.get_string(2), where])
			continue
		var shift := _shift_re.search(token)
		if use == null and shift != null and _patterns.has(shift.get_string(1)):
			_err(n, "'%s' moves pattern '%s' by '%s', which is not a whole number of semitones%s"
					% [token, shift.get_string(1), token.substr(shift.get_start(2) - 1), where])
			continue
		for _i in times:
			_note(token, n, transpose, where)


func _use(name: String, shift: String, n: int, transpose: int, where: String,
		stack: Array) -> void:
	if stack.has(name):
		_err(n, "pattern '%s' uses itself: %s -> %s%s"
				% [name, " -> ".join(stack), name, where])
		return
	if not _on_bar():
		_err(n, "pattern '%s' must start on a bar line, in lane '%s'%s"
				% [name, _lane.name, where])
		return
	_close_bar()
	var p: Dictionary = _patterns[name]
	var start := _cursor
	var had := errors.size()
	var faults := _bar_faults
	_play(p["tokens"], n, transpose + (shift.to_int() if shift != "" else 0), where, name,
			stack + [name])
	var length := _cursor - start
	var into := fposmod(length, float(_score.beats_per_bar))
	# A pattern that is not whole bars also misses its own bar lines. Its
	# length is the fault to report; those misses are what it looks like.
	var clean := had == _lane_errors and errors.size() - had == _bar_faults - faults
	if clean and (length <= 0.001
			or (into > 0.001 and absf(into - _score.beats_per_bar) > 0.001)):
		errors.resize(had)
		_err(n, "pattern '%s' (%s:%d) is %.3f beats, not whole bars of %d%s"
				% [name, p["path"].get_file(), p["line"], length, _score.beats_per_bar, where])
	_close_bar()


func _note(token: String, n: int, transpose: int, where: String) -> void:
	_bar.append([token, transpose, where])
	_event(token, n, transpose, where)


func _checkpoint(n: int, where: String) -> void:
	if _overrun(n, where):
		_close_bar()
		return
	if not _on_bar() and _lane_clean():
		_bar_faults += 1
		_err(n, "lane '%s' reaches a bar line %.3f beats into a bar%s" % [
			_lane.name, fposmod(_cursor, float(_score.beats_per_bar)), where])
	_close_bar()


func _close_bar() -> void:
	if not _bar.is_empty():
		_last_bar = _bar
		_bar = []


# Whether the lane being read has had no error since its bars began.
func _lane_clean() -> bool:
	return errors.size() == _lane_errors


func _on_bar() -> bool:
	var into: float = fposmod(_cursor, float(_score.beats_per_bar))
	return into <= 0.001 or absf(into - _score.beats_per_bar) <= 0.001


# Splits on whitespace, then glues [chord tokens] back together.
func _bar_tokens(line: String) -> Array[String]:
	var out: Array[String] = []
	var open := ""
	for word in _words(line):
		if open != "" and word == "|":
			out.append(open)  # a bar line ends a chord that forgot its ]
			open = ""
		if open != "":
			open += " " + word
			if word.contains("]"):
				out.append(open)
				open = ""
			continue
		if word.begins_with("[") and not word.contains("]"):
			open = word
			continue
		out.append(word)
	if open != "":
		out.append(open)
	return out


func _event(token: String, n: int, transpose: int = 0, where: String = "") -> void:
	var event := SfzScore.Event.new()
	event.at = _cursor
	event.line = n

	var body := token

	# Marks come off the tail first, so a duration never has to compete with
	# one for the last character.
	while not body.is_empty() and MARKS.contains(body[body.length() - 1]):
		match body[body.length() - 1]:
			"!": event.accent = true
			".": event.soft = true
			"'": event.staccato = true
			"_": event.tenuto = true
			"~": event.slur = true
			"^": event.swell = true
			"+": event.muted = true
			"/": event.slide = true
			"\\":
				# The join is a slide in every respect but its bend shape.
				event.slide = true
				event.glide = true
			"<": event.scoop = true
			">": event.fall = true
		body = body.substr(0, body.length() - 1)

	# Then the duration, which is whatever follows the last colon.
	var colon := body.rfind(":")
	if colon >= 0:
		var value := body.substr(colon + 1)
		if not value.is_valid_float():
			_err(n, "'%s' is not a duration in beats%s" % [value, where])
			return
		event.duration = value.to_float()
		if event.duration <= 0.0:
			_err(n, "duration must be positive, got '%s'%s" % [value, where])
			return
		body = body.substr(0, colon)

	if _chords.get(body) == BROKEN:
		_cursor += event.duration
		return
	if _chords.has(body):
		body = _chords[body]
	elif _patterns.has(body):
		_err(n, "pattern '%s' plays whole bars; it takes no duration or marks%s" % [body, where])
		return

	if body.begins_with("["):
		if not body.ends_with("]"):
			_err(n, "chord '%s' is missing its ]%s" % [token, where])
			return
		for name in _words(body.substr(1, body.length() - 2)):
			var key := SfzScore.parse_note(name)
			if key < 0:
				_err(n, "'%s' is not a note name%s" % [name, where])
				return
			if key > 127:
				_err(n, "'%s' leaves the MIDI range (c-1 to g9)%s" % [name, where])
				return
			event.keys.append(key)
		if event.keys.is_empty():
			_err(n, "empty chord%s" % where)
			return
	elif body == "r":
		pass  # a rest: no keys, no drum, just time passing
	elif body.is_empty():
		_err(n, "empty event in lane '%s'%s" % [_lane.name, where])
		return
	else:
		var key := SfzScore.parse_note(body)
		if key > 127:
			_err(n, "'%s' leaves the MIDI range (c-1 to g9)%s" % [token, where])
			return
		if key >= 0:
			event.keys.append(key)
		else:
			# Not a pitch, so it is a drum. Whether this kit has one is the
			# ensemble's business; the score never names a key number. Only a
			# kit has drums, though, so anywhere else a name that is not a
			# note is a typo (or a pattern not yet defined), not a silence.
			if SfzEnsemble.base_family(_score.parts[_lane.part]["family"]) != "perc":
				_err(n, "'%s' is not a note, rest, chord or pattern, in lane '%s' (patterns and chords are defined above their use)%s"
						% [body, _lane.name, where])
				return
			if _drum_re.search(body) == null:
				_err(n, "'%s' is not a drum name, in lane '%s'%s" % [body, _lane.name, where])
				return
			event.drum = body

	if transpose != 0 and not event.keys.is_empty():
		for i in event.keys.size():
			event.keys[i] += transpose
			if event.keys[i] < 0 or event.keys[i] > 127:
				_err(n, "'%s' moved %+d semitones leaves the MIDI range%s" % [token, transpose, where])
				return

	if not event.is_rest():
		_lane.events.append(event)
	_cursor += event.duration


# --- Finishing -----------------------------------------------------------

func _finish_lane() -> void:
	if _lane == null:
		return
	if _section != null:
		# Rests count: a lane is the time it takes, not where its last note
		# stops. A section whose bars: was refused has no length to fill.
		var limit := _section.beats(_score.beats_per_bar)
		if limit > 0.0 and _cursor < limit - 0.001 and _lane_clean():
			_err(_lane_last, "lane '%s' fills %s of the %s beats (%d bars) of section '%s'" % [
				_lane.name, _beats(_cursor), _beats(limit), _section.bars, _section.name])
		_section.lanes[_lane.name] = _lane
	_lane = null


func _finish_section() -> void:
	if _section == null:
		return
	_score.sections[_section.name] = _section
	_score.section_order.append(_section.name)
	_section = null


func _build_order() -> void:
	var names := _explicit_order if not _explicit_order.is_empty() else _score.section_order
	for i in names.size():
		var name: String = names[i]
		if i == _loop_open:
			_score.loop_from = _score.order.size()
		if not _score.sections.has(name):
			_err(_order_line, "order names section '%s', which does not exist" % name)
		else:
			var section: SfzScore.Section = _score.sections[name]
			for _i in section.repeat:
				_score.order.append(name)
		if i + 1 == _loop_close:
			_score.loop_to = _score.order.size()


# --- Small helpers -------------------------------------------------------

func _strip(line: String) -> String:
	var comment := line.find("//")
	if comment >= 0:
		line = line.substr(0, comment)
	return line.strip_edges()


func _words(line: String) -> Array[String]:
	var out: Array[String] = []
	for word in line.split(" ", false):
		var w := word.strip_edges()
		if not w.is_empty():
			out.append(w)
	return out


func _pair(token: String, n: int) -> Array[String]:
	var split := token.split(":", true, 1)
	if split.size() != 2:
		_err(n, "expected key:value, got '%s'" % token)
		return []
	if split[1].is_empty():
		_err(n, "'%s' has no value" % token)
		return []
	return [split[0].to_lower(), split[1]]


# 6, 7.5, 3.333: beats as a person would write them.
func _beats(value: float) -> String:
	var text := "%.3f" % value
	return text.rstrip("0").rstrip(".")


# A tempo of 0 or less would stop the clock or run it backwards.
func _above_zero(value: String, n: int, what: String) -> float:
	if not value.is_valid_float() or value.to_float() <= 0.0:
		_err(n, "%s should be a number above 0, got '%s'" % [what, value])
		return 0.0
	return value.to_float()


# Bars and repeats are counted; 2.5 of them is a typo, not a request.
func _whole(value: String, n: int, what: String) -> int:
	if not value.is_valid_int() or value.to_int() < 1:
		_err(n, "%s should be a whole number above 0, got '%s'" % [what, value])
		return 0
	return value.to_int()


func _err(n: int, message: String) -> void:
	if _lane != null:
		if errors.size() > _lane_errors:
			return  # the lane's first error stands for it
		if not message.contains("lane '"):
			message += ", in lane '%s'" % _lane.name
	if n > 0:
		errors.append("%s:%d: %s" % [_path, n, message])
	else:
		errors.append("%s: %s" % [_path, message])
