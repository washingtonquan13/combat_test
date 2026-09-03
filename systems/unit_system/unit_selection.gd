class_name UnitSelection
extends Node
## Owns hover/selection/box-hover state and the visual highlight/outline
## update logic for ONE unit. A real child Node of that Unit, named
## "Selection" and created in Unit._ready() (never authored in unit.tscn,
## so no scene has to change and every existing unit gains it for free).
##
## A Node rather than a RefCounted — the first of the unit components to
## move, deliberately alone. What the engine gives it in exchange is a
## LIFETIME: when the Unit leaves the tree for any reason (death, a world
## reload freeing everything in it, a test harness tearing a battlefield
## down), this node leaves with it and _exit_tree() runs, so the autoload
## connection below cannot outlive its owner. As a RefCounted it could,
## and did: a Callable bound to a RefCounted holds a STRONG reference, so
## the autoload's own connection list kept each freed unit's component
## alive, and the next mode change anywhere in the game called
## update_highlight() against an already-freed Unit — "previously freed"
## errors on highlight_mesh. That bug was patched with a hand-written
## teardown() called from two places in unit.gd; it is now structural, and
## teardown() is gone. The second thing the engine gives it is visibility:
## the component shows up in the remote scene tree while the game runs,
## which no RefCounted component does.
##
## Because the lifetime is the engine's, the connection is now made in
## _enter_tree and released in _exit_tree — symmetric, and renewed every
## time the unit is reparented. The old code only ever connected once, in
## Unit._ready, so a unit that TRAVELLED (WorldManager carries party units
## between worlds rather than respawning them) lost the connection on its
## first trip and never got it back. See _enter_tree's own comment: that
## is a deliberate behaviour change, not a refactor.
##
## highlight_mesh/outline_mesh/hover_color/selected_color stay as plain
## @export vars directly on Unit rather than moving in here — same
## editor-safety reasoning as UnitFacing's rotation_speed/
## facing_offset_degrees: the editor needs to read/write @export values
## before this component ever exists. This component reads them back
## through its owner reference when it needs them.
##
## Declares its OWN hover_started/hover_ended/selected/deselected
## signals rather than emitting directly on Unit's — Unit relays each
## one in _ready(), same became_idle relay pattern UnitActionState uses,
## so unit.hover_started.connect(...) etc keep working completely
## unchanged for any external code (nothing currently connects to these
## four, but they're part of Unit's public API and should stay stable
## regardless of what's actually listening today).

signal hover_started()
signal hover_ended()
signal selected()
signal deselected()

var is_hovered: bool = false
var is_selected: bool = false
var box_hovered: bool = false

## The Unit this belongs to. Identical to get_parent() once in the tree —
## kept as a typed field anyway because it is set in _init(), before this
## node is added, and _enter_tree/_ready want it already answered rather
## than reconstructed. Unit passes itself in at construction.
var _owner: Unit
var _highlight_material: StandardMaterial3D


func _init(owner: Unit = null) -> void:
	_owner = owner


## The autoload connection, renewed on every tree entry — NOT in _ready.
##
## That is a deliberate behaviour change, and the one thing in this move
## that is not a pure refactor. Units are REPARENTED: WorldManager carries
## the party's units from one world's viewport into the next rather than
## respawning them (see Unit._enter_tree and its _model_adopted guard).
## The old code disconnected on the way out of the tree and reconnected
## nowhere, because its only connect site was Unit._ready, which runs
## once in a unit's life. So the FIRST time a party member travelled
## anywhere, its ring stopped recomputing on a mode change for the rest
## of the session — silently, since a stale ring is not an error, just a
## highlight that fails to clear when a conversation opens. Nothing
## reported it and no test could see it.
##
## Symmetric with _exit_tree now: enter connects, exit disconnects, any
## number of times. Guarded on is_connected() because _enter_tree fires
## on EVERY entry and connecting twice would double every recompute.
func _enter_tree() -> void:
	if _owner == null:
		_owner = get_parent() as Unit
	if _owner == null:
		return

	# update_highlight() only ever runs reactively — on a hover/selection/
	# box-hover CHANGE — and nothing touches this unit's state while
	# something else owns the screen, so nothing would naturally
	# re-trigger it on the way back out either.
	#
	# This was two connections, to DialogueManager's dialogue_started and
	# dialogue_ended, which is a narrower question than the one being
	# asked: a conversation is one of several things that can take the
	# screen (a negotiation, a loot screen, a cutscene, a menu), and the
	# ring should recompute on any of them. GameMode already derives
	# exactly that and emits when it moves, so ask it instead — one
	# connection, and the answer stays right when a new mode is added.
	if not GameMode.mode_changed.is_connected(_on_mode_changed):
		GameMode.mode_changed.connect(_on_mode_changed)


## The rest of what setup() used to do, called explicitly at the end of
## Unit._ready(). Stays in _ready rather than joining the connection
## above: giving this unit its own material instance is a once-in-a-
## lifetime act, not something a reparent should redo, and _ready is the
## notification that fires once.
##
## Equivalent timing to the old setup(): highlight_mesh/outline_mesh are
## bound in Unit's _enter_tree() (see Unit._bind_model), so both are
## already answered by the time any child of the Unit readies.
func _ready() -> void:
	if _owner == null:
		return

	if _owner.highlight_mesh:
		# Give this unit its own material instance so its ring can
		# change color independently of any siblings sharing the same
		# base mesh.
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_highlight_material = mat
		_owner.highlight_mesh.material_override = mat
		_owner.highlight_mesh.visible = false

	if _owner.outline_mesh:
		_owner.outline_mesh.visible = false


## The whole reason this component is a Node. Releases the autoload
## connection the moment this unit stops being part of the live tree — no
## caller has to remember to, which is what the deleted teardown() was and
## what made the leak reachable in the first place (an ordinary world
## reload freeing the outgoing world's Units leaked one component per
## party member per reload, before anything had even died).
##
## Guarded on is_connected() rather than disconnecting blind: _enter_tree
## returns early for an owner-less node without connecting, so there is a
## real case that reaches here with nothing to release. Disconnecting an
## unconnected signal is a hard error, not a no-op.
func _exit_tree() -> void:
	if GameMode.mode_changed.is_connected(_on_mode_changed):
		GameMode.mode_changed.disconnect(_on_mode_changed)


func _on_mode_changed(_mode: GameMode.Mode) -> void:
	update_highlight()


func on_mouse_entered() -> void:
	is_hovered = true
	hover_started.emit()
	update_highlight()


func on_mouse_exited() -> void:
	is_hovered = false
	hover_ended.emit()
	update_highlight()


## Selection state is owned by SelectionManager — call
## SelectionManager.select()/deselect() rather than this directly, so the
## manager's selected_units list and this unit's state never drift apart.
func set_selected(value: bool) -> void:
	if is_selected == value:
		return
	is_selected = value
	if value:
		selected.emit()
	else:
		deselected.emit()
	update_highlight()


## Called by a drag-select box while it's overlapping this unit, purely as
## a visual preview — does not touch is_selected or SelectionManager.
func set_box_hover(value: bool) -> void:
	if box_hovered == value:
		return
	box_hovered = value
	update_highlight()


func update_highlight() -> void:
	var state_color: Variant = null
	var show: bool = false

	if is_selected:
		show = true
		state_color = _owner.selected_color
	elif is_hovered or box_hovered:
		show = true
		state_color = _owner.hover_color

	if _owner.highlight_mesh:
		_owner.highlight_mesh.visible = show
		if show:
			_highlight_material.albedo_color = state_color

	if _owner.outline_mesh:
		_owner.outline_mesh.visible = show
		if show:
			var outline_material := _owner.outline_mesh.material_override as ShaderMaterial
			if outline_material:
				outline_material.set_shader_parameter("outline_color", state_color)
