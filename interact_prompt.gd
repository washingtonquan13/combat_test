extends PanelContainer
## Bottom-centre "Enter X" prompt for the overworld's walk-into-range
## interactions (see overworld_door.gd) — the JRPG-style counterpart to
## the arena's right-click Travel verb. The overworld and in-level party
## control deliberately do NOT share a control schema right now: WASD +
## walk-into-range-then-press-interact here, versus click-to-move +
## right-click-a-verb for the tactical party (see overworld_avatar.gd's
## own header for the full comparison). Whether to eventually unify the
## two is an open, deliberately deferred decision — nothing here should
## be built toward either outcome.
##
## A candidate registers itself while the avatar is standing in its
## trigger volume and unregisters on exit. Candidates are duck-typed by
## activate() (same convention as get_interactions()/get_spawn_point()) —
## this file doesn't know or care what kind of node registered, only that
## it can be told to fire. A small stack, not a single slot, so
## overlapping volumes resolve to whichever candidate registered most
## recently, and popping the wrong one on exit can't leave a stale prompt
## showing for a candidate the avatar is still standing in.
##
## Authored directly in MainRoot.tscn (a PanelContainer + Label, not
## built procedurally) so it stays genuinely editable in the Godot
## editor. Found by candidates via get_tree().get_first_node_in_group()
## — same find-by-role idiom esc_menu.gd/main_menu.gd/
## character_creation.gd already use — rather than a new autoload, since
## this is ordinary UI content living in MainRoot's own CanvasLayer, not
## global state.

@onready var _label: Label = $Label

var _candidates: Array[Node] = []
var _texts: Dictionary = {}  # Node -> String


func _ready() -> void:
	add_to_group("interact_prompt")
	visible = false
	# body_exited doesn't fire reliably for a world being freed out from
	# under a candidate — clear proactively on every load instead of
	# trusting every candidate to unregister itself first.
	WorldManager.world_loading.connect(_on_world_loading)
	WorldManager.world_focused.connect(_on_world_focused)


func register(candidate: Node, text: String) -> void:
	_candidates.erase(candidate)
	_candidates.append(candidate)
	_texts[candidate] = text
	_refresh()


func unregister(candidate: Node) -> void:
	_candidates.erase(candidate)
	_texts.erase(candidate)
	_refresh()


func _unhandled_input(event: InputEvent) -> void:
	if _candidates.is_empty() or not event.is_action_pressed("interact"):
		return
	var candidate: Node = _candidates.back()
	if is_instance_valid(candidate) and candidate.has_method("activate"):
		candidate.activate()
	get_viewport().set_input_as_handled()


## Switching to a group somewhere else changes which world is on screen
## without loading anything, so world_loading never fires — and the
## prompt for a door in the world just left stayed up, offering to enter
## somewhere the player is no longer standing.
##
## A prompt always belongs to the world being looked at, so the honest
## rule is that changing worlds clears it. Anything still genuinely
## under the player re-offers itself (see overworld_door).
func _on_world_focused(_world: Node) -> void:
	_candidates.clear()
	_texts.clear()
	_refresh()


func _on_world_loading(_scene: PackedScene) -> void:
	_candidates.clear()
	_texts.clear()
	_refresh()


func _refresh() -> void:
	var should_show: bool = not _candidates.is_empty() and GameMode.current_mode() == GameMode.Mode.OVERWORLD
	visible = should_show
	if should_show:
		_label.text = _texts.get(_candidates.back(), "Enter")
