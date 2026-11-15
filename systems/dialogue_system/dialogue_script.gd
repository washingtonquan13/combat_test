class_name DialogueScript
extends RefCounted
## Reads a dialogue file (.dlg) into the DialogueNodes a Conversation plays.
##
## WHY A TEXT FORMAT. A conversation is written as a run of short lines, the
## way it is heard: one beat per line, the camera free to move on each. As
## one resource file per node that is a folder of twenty files for a speech,
## so nobody writes it that way and the speeches come out as paragraphs. Here
## a beat costs one line of text.
##
##     // The townsperson. Node ids are "<file name>_<node name>".
##     == quest_intro
##     before: [present DwarfFighter] -> quest_intro_dwarf_reaction
##     npc: You mean the raids.
##     npc: Goblins, mostly. Small bands, quick and mean.      #close
##     ~ She looks away.
##     * What exactly have they done?
##         give healing_potion
##         -> quest_details
##     * [passive Insight] You aren't telling me everything.
##         -> quest_insight
##     * [Light] [repeat] That's terrible.
##         -> ROOT
##     * [contest Intimidation vs Will] Tell me, or I walk.
##         success -> quest_insight
##         failure -> quest_pushed_back
##
## "== name" starts a node. "speaker: text" is a spoken line and "~ text" (or
## a line with no speaker) is narration; several in a row become a chain of
## nodes that follow on by themselves, the first keeping the node's id and
## the last carrying its responses. A trailing #word is a staging tag. "*"
## is a response; its [brackets] hold an alignment, repeat, silent/spoken,
## hidden, a check, or a condition; the indented lines under it are what
## choosing it does and where it leads ("-> END" or nothing ends the
## conversation, "-> ROOT" returns to the NPC's opening). An unindented
## "-> name" after the lines is where a node with no responses goes next.
## "start:" lines are effects applied when a conversation opens on the node.
## A file that begins with "responses silent" is one whose responses are
## acts, not speech (negotiation).
##
## LINE IDS. Every line, response and "say:" ends in "#line:xxxxxx", a name
## for those words that survives rewording and reordering: it is what a
## recording, a translation or a shot bound to the line is filed under. They
## are not typed. Running the game from the editor writes one onto any line
## that lacks it (see stamp_file); copy a line and the copy's id must be
## deleted, or the file reports the duplicate.
##
## Conditions and effects are not named here. Each PrerequisiteRule or
## DialogueEffect that can be written in a file says so itself with a
## SCRIPT_WORDS constant and reads its own arguments in read_script(), so a
## new system adds its words without this file changing.

const EXTENSION: String = "dlg"
const END: String = "END"
const ROOT: String = "ROOT"
const ALIGNMENTS: PackedStringArray = ["Light", "Dark", "Lawful", "Chaotic"]

var nodes: Array[DialogueNode] = []
## What is wrong with the file, each with its line number. A file with
## problems still yields every node that could be read.
var problems: PackedStringArray = []

var _source: String = ""
var _prefix: String = ""
var _silent: bool = false
var _line_no: int = 0
var _locals: Dictionary = {}
var _blocks: Array[Dictionary] = []
## Indices of the source lines that hold words and have no line id yet.
var _unstamped: PackedInt32Array = []

static var _speaker_pattern: RegEx = RegEx.create_from_string("^([A-Za-z_][A-Za-z0-9_]*):\\s*(.*)$")
static var _tag_pattern: RegEx = RegEx.create_from_string("\\s#([A-Za-z_][A-Za-z0-9_]*)$")
static var _id_pattern: RegEx = RegEx.create_from_string("(^|\\s)#line:([0-9a-z]+)$")
## Line id -> "file:line" of the line that holds it, across every file read.
static var _ids: Dictionary = {}
const ID_TAG: String = "#line:"
const ID_LETTERS: int = 6
## Root class name -> { word -> Script }. See _script_for.
static var _words: Dictionary = {}


static func compile_file(path: String) -> DialogueScript:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		var failed := DialogueScript.new()
		failed.problems.append("%s: cannot be opened." % path)
		return failed
	return compile_text(file.get_as_text(), path)


## `source` is the file's path: its base name is the prefix of every node id
## in it, and it is what problems are reported against.
static func compile_text(text: String, source: String) -> DialogueScript:
	var script := DialogueScript.new()
	script._source = source
	script._prefix = source.get_file().get_basename() + "_"
	script._compile(text)
	return script


## compile_file, after first writing a line id onto every line of the file
## that has none. The file is only rewritten when something was missing.
static func stamp_file(path: String) -> DialogueScript:
	var script: DialogueScript = compile_file(path)
	if script._unstamped.is_empty():
		return script
	var read: FileAccess = FileAccess.open(path, FileAccess.READ)
	var lines: PackedStringArray = read.get_as_text().split("\n")
	read.close()
	for i in script._unstamped:
		var ending: String = "\r" if lines[i].ends_with("\r") else ""
		lines[i] = "%s  %s%s%s" % [lines[i].strip_edges(false, true), ID_TAG, _new_id(), ending]
	var write: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if write == null:
		return script
	write.store_string("\n".join(lines))
	write.close()
	_forget_ids(path)
	return compile_file(path)


static func _new_id() -> String:
	var id: String = ""
	while id == "" or _ids.has(id):
		id = ("%08x" % randi()).right(ID_LETTERS)
	_ids[id] = ""
	return id


static func _forget_ids(source: String) -> void:
	for id in _ids.keys():
		if _ids[id] == "" or _ids[id].begins_with(source + ":"):
			_ids.erase(id)


## Takes the line id off the end of `words`. Returns [the words, the id].
func _take_id(words: String) -> Array:
	var found: RegExMatch = _id_pattern.search(words)
	if found == null:
		_unstamped.append(_line_no - 1)
		return [words, ""]
	var id: String = found.get_string(2)
	var here: String = "%s:%d" % [_source, _line_no]
	if _ids.get(id, here) not in ["", here]:
		_problem("line id '%s' is already the line at %s; delete it from the copy." % [id, _ids[id]])
	else:
		_ids[id] = here
	return [words.substr(0, found.get_start()).strip_edges(), id]


func _compile(text: String) -> void:
	_forget_ids(_source)
	var lines: PackedStringArray = text.replace("\r", "").split("\n")
	for raw in lines:
		if raw.begins_with("=="):
			_locals[_node_name(raw)] = true
	var block: Dictionary = {}
	var choice: Dictionary = {}
	for i in lines.size():
		_line_no = i + 1
		var raw: String = lines[i]
		var line: String = raw.strip_edges()
		if line == "" or line.begins_with("//"):
			continue
		var indented: bool = raw[0] == " " or raw[0] == "\t"
		if line.begins_with("=="):
			block = {"name": _node_name(line), "line": _line_no, "start": [], "before": [],
					"lines": [], "choices": [], "next": ""}
			choice = {}
			_blocks.append(block)
		elif block.is_empty():
			if line == "responses silent":
				_silent = true
			else:
				_problem("'%s' is outside any node; a node starts with '== name'." % line)
		elif line.begins_with("*"):
			choice = _read_choice(line.substr(1).strip_edges(), block)
			block.choices.append(choice)
		elif indented and not choice.is_empty():
			_read_choice_body(line, choice, block)
		elif not block.choices.is_empty():
			_problem("'%s' comes after the responses; a node's lines come first." % line)
		elif line.begins_with("start:"):
			var effect: DialogueEffect = _worded(line.substr(6), &"DialogueEffect", block) as DialogueEffect
			if effect:
				block.start.append(effect)
		elif line.begins_with("before:"):
			_read_before(line.substr(7).strip_edges(), block)
		elif line.begins_with("->"):
			block.next = _target(line.substr(2))
		elif block.next != "":
			_problem("'%s' comes after the node's '->'; nothing can follow it." % line)
		else:
			block.lines.append(_read_line(line))
	for b in _blocks:
		_emit(b)


func _node_name(line: String) -> String:
	return line.trim_prefix("==").trim_suffix("==").strip_edges()


func _read_line(line: String) -> Dictionary:
	var named: Array = _take_id(line)
	line = named[0]
	var tags: PackedStringArray = []
	var tagged: RegExMatch = _tag_pattern.search(line)
	while tagged:
		tags.insert(0, tagged.get_string(1))
		line = line.substr(0, tagged.get_start()).strip_edges()
		tagged = _tag_pattern.search(line)
	var speaker: String = ""
	var text: String = line
	if line.begins_with("~"):
		text = line.substr(1).strip_edges()
	else:
		var spoken: RegExMatch = _speaker_pattern.search(line)
		if spoken:
			speaker = spoken.get_string(1)
			text = spoken.get_string(2)
	return {"speaker": speaker, "text": _unescape(text), "tags": tags, "id": named[1]}


func _unescape(text: String) -> String:
	return text.replace("\\n", "\n")


func _read_before(rest: String, block: Dictionary) -> void:
	var option := DialogueRootOption.new()
	if rest.begins_with("["):
		var close: int = rest.find("]")
		if close < 0:
			_problem("'[' is never closed.")
			return
		option.prerequisite = _worded(rest.substr(1, close - 1), &"PrerequisiteRule", block) as PrerequisiteRule
		rest = rest.substr(close + 1).strip_edges()
	if not rest.begins_with("->"):
		_problem("'before:' needs '-> node' to say which node cuts in.")
		return
	option.root_id = _target(rest.substr(2))
	block.before.append(option)


func _read_choice(rest: String, block: Dictionary) -> Dictionary:
	var c: Dictionary = {"line": _line_no, "text": "", "alignment": "", "repeat": false,
			"silent": _silent, "hidden": false, "kind": &"line", "skill": "", "npc_skill": "",
			"prerequisite": null, "say": null, "flag": "", "effects": [], "id": "", "say_id": "",
			"next": "", "root": false, "success": "", "failure": ""}
	while rest.begins_with("["):
		var close: int = rest.find("]")
		if close < 0:
			_problem("'[' is never closed.")
			break
		_read_bracket(rest.substr(1, close - 1).strip_edges(), c, block)
		rest = rest.substr(close + 1).strip_edges()
	var named: Array = _take_id(rest)
	c.text = _unescape(named[0])
	c.id = named[1]
	return c


func _read_bracket(inside: String, c: Dictionary, block: Dictionary) -> void:
	var word: String = inside.get_slice(" ", 0)
	var rest: String = inside.substr(word.length()).strip_edges()
	if ALIGNMENTS.has(inside):
		c.alignment = inside
	elif inside == "repeat":
		c.repeat = true
	elif inside == "silent":
		c.silent = true
	elif inside == "spoken":
		c.silent = false
	elif inside == "hidden":
		c.hidden = true
	elif word == "check":
		c.kind = &"check"
		c.skill = rest
	elif word == "contest":
		var sides: PackedStringArray = rest.split(" vs ")
		if sides.size() != 2:
			_problem("a contest is written '[contest Skill vs Skill]'.")
			return
		c.kind = &"contest"
		c.skill = sides[0].strip_edges()
		c.npc_skill = sides[1].strip_edges()
	elif c.prerequisite != null:
		_problem("a response takes one condition; '[%s]' is a second." % inside)
	else:
		c.prerequisite = _worded(inside, &"PrerequisiteRule", block)


func _read_choice_body(line: String, c: Dictionary, block: Dictionary) -> void:
	if line.begins_with("->"):
		var target: String = line.substr(2).strip_edges()
		if target == ROOT:
			c.root = true
		else:
			c.next = _target(target)
	elif line.begins_with("success") and line.substr(7).strip_edges().begins_with("->"):
		c.success = _target(line.substr(7).strip_edges().substr(2))
	elif line.begins_with("failure") and line.substr(7).strip_edges().begins_with("->"):
		c.failure = _target(line.substr(7).strip_edges().substr(2))
	elif line.begins_with("say:"):
		var named: Array = _take_id(line.substr(4).strip_edges())
		c.say = _unescape(named[0])
		c.say_id = named[1]
	elif line.begins_with("set "):
		c.flag = line.substr(4).strip_edges()
	else:
		var effect: DialogueEffect = _worded(line, &"DialogueEffect", block) as DialogueEffect
		if effect:
			c.effects.append(effect)


## A node named in this file by its short name, or any node by its full id.
func _target(written: String) -> String:
	var name: String = written.strip_edges()
	if name == END or name == "":
		return ""
	if name == ROOT:
		_problem("only a response can lead '-> ROOT'.")
		return ""
	return _prefix + name if _locals.has(name) else name


func _emit(block: Dictionary) -> void:
	var id: String = _prefix + block.name
	var lines: Array = block.lines
	if lines.is_empty():
		lines = [{"speaker": "", "text": "", "tags": PackedStringArray(), "id": ""}]
	for i in lines.size():
		var node := DialogueNode.new()
		node.id = id if i == 0 else "%s.%d" % [id, i + 1]
		node.speaker = lines[i].speaker
		node.text_block = lines[i].text
		node.tags = lines[i].tags
		node.line_id = lines[i].id
		if i == 0:
			for effect in block.start:
				node.start_effects.append(effect)
			for option in block.before:
				node.interjection_options.append(option)
		if i < lines.size() - 1:
			node.next_node_id = "%s.%d" % [id, i + 2]
			node.continues = true
		else:
			node.next_node_id = block.next
			for c in block.choices:
				node.choices.append(_build_choice(c))
		nodes.append(node)


func _build_choice(c: Dictionary) -> DialogueChoice:
	_line_no = c.line
	var choice: DialogueChoice
	if c.kind == &"line":
		var plain := LineChoice.new()
		plain.next_node_id = c.next
		plain.returns_to_root = c.root
		if c.success != "" or c.failure != "":
			_problem("'success ->' and 'failure ->' belong to a [check] or [contest].")
		choice = plain
	else:
		if c.kind == &"check":
			choice = SkillCheckChoice.new()
		else:
			choice = QuickContestChoice.new()
			choice.npc_skill_name = c.npc_skill
		choice.skill_name = c.skill
		choice.success_node_id = c.success
		choice.failure_node_id = c.failure
		choice.show_to_player = not c.hidden
		if c.next != "" or c.root:
			_problem("a [check] or [contest] leads 'success ->' and 'failure ->', not '->'.")
	choice.text = c.text
	choice.line_id = c.id
	choice.spoken_line_id = c.say_id if c.say != null else c.id
	choice.alignment_name = c.alignment
	choice.is_repeatable = c.repeat
	choice.sets_flag = c.flag
	choice.prerequisites = c.prerequisite
	if c.say != null:
		choice.dialogue_line = c.say
	elif not c.silent:
		choice.dialogue_line = c.text
	for effect in c.effects:
		choice.effects.append(effect)
	return choice


## Builds the condition or effect a phrase names: its first word picks the
## class, and the class reads the rest.
func _worded(phrase: String, root: StringName, block: Dictionary) -> Resource:
	var parts: PackedStringArray = phrase.strip_edges().split(" ", false)
	if parts.is_empty():
		_problem("nothing is written here.")
		return null
	var word: String = parts[0]
	parts.remove_at(0)
	var script: Script = _script_for(word, root)
	if script == null:
		_problem("'%s' is not a known %s (known: %s)." % [word,
				"condition" if root == &"PrerequisiteRule" else "effect",
				", ".join(_words[root].keys())])
		return null
	var made: Resource = script.new()
	var wrong: String = made.read_script(word, parts, _prefix + block.name)
	if wrong != "":
		_problem(wrong)
		return null
	return made


func _problem(what: String) -> void:
	problems.append("%s:%d: %s" % [_source, _line_no, what])


## Every script class under `root` that declares SCRIPT_WORDS, by word.
static func _script_for(word: String, root: StringName) -> Script:
	if not _words.has(root):
		var base_of: Dictionary = {}
		var path_of: Dictionary = {}
		for entry in ProjectSettings.get_global_class_list():
			base_of[entry["class"]] = entry["base"]
			path_of[entry["class"]] = entry["path"]
		var found: Dictionary = {}
		for name in base_of:
			var up: StringName = name
			while base_of.has(up) and up != root:
				up = base_of[up]
			if up != root or name == root:
				continue
			var script: Script = load(path_of[name])
			var declared: Variant = script.get_script_constant_map().get("SCRIPT_WORDS")
			if declared == null:
				continue
			for w in declared:
				found[w] = script
		_words[root] = found
	return _words[root].get(word)
