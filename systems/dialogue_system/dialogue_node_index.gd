class_name DialogueNodeIndex
extends RefCounted
## Indexes a directory of DialogueNode .tres files by their own `id`.
## One index per tree folder, shared by every Conversation reading from
## it (see Conversation.index_for) — dialogue and negotiation trees keep
## separate id namespaces. This only owns "find a node by id," not
## showing anything or deciding what a node/choice means.

var _id_to_path: Dictionary = {}  # String id -> String res:// path
var _indexed: bool = false
## Prefixes every push_warning from this index, so its warnings say who
## was indexing.
var _log_prefix: String


func _init(log_prefix: String) -> void:
	_log_prefix = log_prefix


## No-op after the first call — same "index once, not per lookup" fix
## SkillDatabase established.
func ensure_indexed(root_dir: String) -> void:
	if _indexed:
		return
	_indexed = true
	_index_directory(root_dir)


func find_node(id: String) -> DialogueNode:
	if not _id_to_path.has(id):
		return null
	return load(_id_to_path[id]) as DialogueNode


func has_id(id: String) -> bool:
	return _id_to_path.has(id)


## Every currently-indexed id, for a caller's own validation pass (see
## Conversations.lint) — this index doesn't know what a valid reference
## looks like, only what ids actually exist to be referenced.
func all_ids() -> Array:
	return _id_to_path.keys()


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
				if _id_to_path.has(res.id):
					push_warning("%s: duplicate DialogueNode id '%s' — '%s' and '%s' both claim it; the second silently wins." % [_log_prefix, res.id, _id_to_path[res.id], full_path])
				_id_to_path[res.id] = full_path
		entry_name = da.get_next()
	da.list_dir_end()
