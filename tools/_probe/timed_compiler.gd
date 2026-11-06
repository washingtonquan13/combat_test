extends SfzPerformanceCompiler
# Temporary probe: SfzPerformanceCompiler with its parts timed.

var spent := {}

func _t(name: String, since: int) -> void:
	spent[name] = spent.get(name, 0.0) + (Time.get_ticks_usec() - since) / 1000.0

func _lane(out: Array, lane: SfzScore.Lane, part: String, origin: float, spb: float, beats: float) -> void:
	var s := Time.get_ticks_usec()
	super(out, lane, part, origin, spb, beats)
	_t("lane", s)

func _switched(events: Array) -> Array:
	var s := Time.get_ticks_usec()
	var r := super(events)
	_t("switched", s)
	return r

func sorted(out: Array) -> Array:
	var s := Time.get_ticks_usec()
	var r := super(out)
	_t("sorted", s)
	return r

func tag_lane(out: Array, first: int, lane: SfzScore.Lane) -> void:
	var s := Time.get_ticks_usec()
	super(out, first, lane)
	_t("tag_lane", s)

func _phrases(lane: SfzScore.Lane, beats: float) -> Array:
	var s := Time.get_ticks_usec()
	var r := super(lane, beats)
	_t("phrases", s)
	return r

func compile(score: SfzScore) -> Array:
	var s := Time.get_ticks_usec()
	var r := super(score)
	_t("compile", s)
	return r

func _velocity(e: SfzScore.Event, base: int, after_slur: bool) -> int:
	var s := Time.get_ticks_usec(); var r := super(e, base, after_slur); _t("velocity", s); return r
func _timing(part: String, lane: SfzScore.Lane, e: SfzScore.Event, spb: float) -> float:
	var s := Time.get_ticks_usec(); var r := super(part, lane, e, spb); _t("timing", s); return r
func _duration(lane: SfzScore.Lane, part: String, i: int, e: SfzScore.Event, spb: float) -> float:
	var s := Time.get_ticks_usec(); var r := super(lane, part, i, e, spb); _t("duration", s); return r
func _hold(lane: SfzScore.Lane, part: String, i: int, spb: float, key: int, duration: float) -> float:
	var s := Time.get_ticks_usec(); var r := super(lane, part, i, spb, key, duration); _t("hold", s); return r
func _articulation(part: String, lane: SfzScore.Lane, e: SfzScore.Event, after_slur: bool) -> String:
	var s := Time.get_ticks_usec(); var r := super(part, lane, e, after_slur); _t("articulation", s); return r
func _slide(out: Array, part: String, t: float, e: SfzScore.Event, from: SfzScore.Event) -> String:
	var s := Time.get_ticks_usec(); var r := super(out, part, t, e, from); _t("slide", s); return r
func _bend(out: Array, part: String, lane: SfzScore.Lane, i: int, t: float, spb: float, duration: float, from: SfzScore.Event) -> void:
	var s := Time.get_ticks_usec(); super(out, part, lane, i, t, spb, duration, from); _t("bend", s)
func _legato(out: Array, part: String, t: float, slurred: bool, was_slurred: bool) -> void:
	var s := Time.get_ticks_usec(); super(out, part, t, slurred, was_slurred); _t("legato", s)
func _dynamic_curve(out: Array, part: String, origin: float, spb: float, beats: float, from: int, to: int) -> void:
	var s := Time.get_ticks_usec(); super(out, part, origin, spb, beats, from, to); _t("dyncurve", s)
func _vibrato(out: Array, part: String, t: float, duration: float, vib: String) -> void:
	var s := Time.get_ticks_usec(); super(out, part, t, duration, vib); _t("vibrato", s)
func has_keyswitch(part: String, art: String) -> bool:
	var s := Time.get_ticks_usec(); var r := super(part, art); _t("has_keyswitch", s); return r
func has_control(part: String, control: String) -> bool:
	var s := Time.get_ticks_usec(); var r := super(part, control); _t("has_control", s); return r
func emit_note(out: Array, part: String, t: float, key: int, velocity: int, duration: float) -> void:
	var s := Time.get_ticks_usec(); super(out, part, t, key, velocity, duration); _t("emit_note", s)
