class_name HotbarDivider
extends VSeparator
## Draggable divider between two adjacent hotbar sections — whole-column
## snapping only, never a raw pixel offset. Converts a horizontal drag
## gesture into a whole-column delta and emits it; stays completely
## unaware of what it's actually dividing (no sibling node references at
## all) — the parent (ability_hotbar.gd) owns clamping that delta against
## its own two specific neighbor sections' column counts and the
## 1-column floor. See that file's _on_divider_dragged.
##
## Scene setup: a VSeparator (default engine theme, no custom StyleBox —
## this project has no Theme resource anywhere yet). Widen
## custom_minimum_size.x for a comfortable grab target — the rendered
## line itself stays thin, the CONTROL's hit area is what
## custom_minimum_size widens. Set column_width_px to match the flanking
## GridContainers' actual column pitch (HotbarSlot's own width + the
## GridContainer's h_separation theme constant) — nothing derives this
## automatically, so update it if either changes.

## How many horizontal pixels equal one whole column of drag distance.
## Purely a number, never a node reference — keeps this script reusable
## between both divider instances without knowing anything about which
## specific GridContainers it sits between.
@export var column_width_px: float = 36.0

var _dragging: bool = false
var _drag_start_global_x: float = 0.0
## Only used to avoid re-emitting the same delta repeatedly — NOT
## accumulated into, see columns_dragged's own doc comment.
var _last_emitted_delta: int = 0

## Total signed column offset since the current drag gesture began (not
## an incremental step) — always recomputed fresh from
## _drag_start_global_x on every motion event, never accumulated
## frame-to-frame, so this can't drift no matter how many small mouse
## motions happen in between. Treat this as authoritative/replace-not-
## accumulate on the receiving end.
signal columns_dragged(delta: int)
## Fired once when a gesture begins, before any columns_dragged — lets
## the parent snapshot its two neighbor sections' CURRENT column counts
## as the baseline this gesture's deltas apply against.
signal drag_started()
signal drag_ended()


func _ready() -> void:
	mouse_default_cursor_shape = Control.CURSOR_HSPLIT
	mouse_filter = Control.MOUSE_FILTER_STOP


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			_dragging = true
			_drag_start_global_x = mb.global_position.x
			_last_emitted_delta = 0
			drag_started.emit()
		elif _dragging:
			_dragging = false
			drag_ended.emit()
		return

	if event is InputEventMouseMotion and _dragging:
		var raw_delta_px: float = (event as InputEventMouseMotion).global_position.x - _drag_start_global_x
		var delta: int = roundi(raw_delta_px / column_width_px)
		if delta == _last_emitted_delta:
			return
		_last_emitted_delta = delta
		columns_dragged.emit(delta)
