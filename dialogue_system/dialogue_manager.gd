extends Node
## Autoload singleton. Register as "DialogueManager" under
## Project > Project Settings > AutoLoad.
##
## Orchestrates one conversation at a time: which DialogueNode is
## current, who the participant tokens (see DialogueNode.speaker) resolve
## to, the running transcript (for the conversation log), and moving
## between nodes. Deliberately dumb about PRESENTATION — dialogue_overlay.gd
## and dialogue_camera_rig.gd both just listen to this autoload's signals
## and react; this file never touches a Control or a Camera3D.
##
## Node lookup is indexed once, lazily, the first time a dialogue actually
## starts — NOT rescanned per node transition. The old GURPS-project
## DialogueManager walked res://data/dialogue with DirAccess on every
## single node change; this is the exact same fix already applied once
## for SkillDatabase, applied again here.

signal dialogue_started(root: DialogueNode)
## Fired for EVERY line shown — a node's own text_block, and the smaller
## echo lines a DialogueChoice.resolve() produces (alignment message,
## echoed response, skill check result) — so the overlay (display) and
## dialogue_camera_rig (who to frame) both react to one single event
## instead of needing two different ways to find out what was said.
## speaker_token is "" for the small echo lines (see record_line) — no
## camera re-cut for those, a deliberate simplification: only a node's
## own text_block currently drives a shot change.
signal line_shown(text: String, speaker_token: String)
signal choices_shown(choices: Array[DialogueChoice])
signal dialogue_ended()

const DIALOGUE_DATA_PATH: String = "res://data/dialogue"

var current_node: DialogueNode = null
var participants: Dictionary = {}  # String token ("player"/"npc") -> Unit
var used_choices: Dictionary = {}  # "node_id:index" -> true
var transcript: Array[String] = []

var _id_to_path: Dictionary = {}  # String id -> String res:// path
var _indexed: bool = false


func is_active() -> bool:
	return current_node != null


## participants maps DialogueNode.speaker tokens to actual Units for
## THIS conversation — {"player": actor, "npc": target} for the common
## 1-on-1 case (see talk_interaction.gd), more tokens for a future group
## scene. Blocked during combat — a full-screen conversation has no
## defined interaction with the turn/initiative state machine yet, and
## nothing about talking to an ally requires it to work mid-fight.
func start_dialogue(root: DialogueNode, conversation_participants: Dictionary) -> void:
	if CombatManager.in_combat or not root:
		return

	transcript.clear()
	used_choices.clear()
	participants = conversation_participants
	dialogue_started.emit(root)
	_show_node(root)


func choose(index: int) -> void:
	if not current_node or index < 0 or index >= current_node.choices.size():
		return

	var key: String = "%s:%d" % [current_node.id, index]
	var choice: DialogueChoice = current_node.choices[index]
	used_choices[key] = true

	var next_id: String = choice.resolve(participants.get("player"), participants.get("npc"))
	_load_node_by_id(next_id)


## Only meaningful when current_node.choices is empty (see
## DialogueNode.next_node_id) — the "Continue" affordance rather than a
## real branch.
func advance() -> void:
	if not current_node or not current_node.choices.is_empty():
		return
	if current_node.next_node_id == "":
		end_dialogue()
		return
	_load_node_by_id(current_node.next_node_id)


func end_dialogue() -> void:
	current_node = null
	participants = {}
	dialogue_ended.emit()


## Appends one line to the running transcript (conversation_log.gd reads
## this directly) and tells whatever's listening to show it as the
## current line right now. The single path every line goes through,
## called both by _show_node (a node's own text) and by
## DialogueChoice.resolve/SkillCheckChoice (the smaller echo lines).
func record_line(text: String, speaker_token: String = "") -> void:
	transcript.append(text)
	line_shown.emit(text, speaker_token)


func _show_node(node: DialogueNode) -> void:
	current_node = node
	record_line(node.text_block, node.speaker)

	var visible_choices: Array[DialogueChoice] = []
	for i in node.choices.size():
		var choice: DialogueChoice = node.choices[i]
		var key: String = "%s:%d" % [node.id, i]
		if used_choices.has(key) and not choice.is_repeatable:
			continue
		visible_choices.append(choice)
	choices_shown.emit(visible_choices)


func _load_node_by_id(id: String) -> void:
	if id == "":
		end_dialogue()
		return

	var node: DialogueNode = _find_node(id)
	if not node:
		push_error("DialogueManager: no node found for id '%s'" % id)
		end_dialogue()
		return

	_show_node(node)


func _find_node(id: String) -> DialogueNode:
	_ensure_indexed()
	if not _id_to_path.has(id):
		return null
	return load(_id_to_path[id]) as DialogueNode


func _ensure_indexed() -> void:
	if _indexed:
		return
	_indexed = true
	_index_directory(DIALOGUE_DATA_PATH)


func _index_directory(dir_path: String) -> void:
	var da: DirAccess = DirAccess.open(dir_path)
	if not da:
		return

	da.list_dir_begin()
	var entry_name: String = da.get_next()
	while entry_name != "":
		if entry_name == "." or entry_name == "..":
			entry_name = da.get_next()
			continue

		var full_path: String = dir_path + "/" + entry_name
		if da.current_is_dir():
			_index_directory(full_path)
		elif entry_name.get_extension() == "tres":
			var res: Resource = load(full_path)
			if res is DialogueNode:
				_id_to_path[res.id] = full_path
		entry_name = da.get_next()
	da.list_dir_end()
