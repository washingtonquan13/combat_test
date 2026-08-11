extends Button
## Clickable portrait for a unit — art + HP-as-overlay + team-colored
## outline, click selects the unit. Shared between the turn-order strip
## (initiative_row.gd) and the party panel (party_panel.gd) — renamed
## from the original initiative_portrait.gd/.tscn (Control-based, no
## click handling) once a second UI needed the exact same visual, rather
## than staying named/scoped for turn order specifically.
##
## A Button root, not a plain Control — clicking anywhere on the
## portrait calls SelectionManager.select(), same as clicking the unit
## in the 3D world (including shift-click-to-add, via the same
## select_additive action). flat = true on the root (see the .tscn)
## suppresses Godot's default button chrome (this project has no theme
## at all — a stock Button background/border would show through/around
## the art otherwise); Button still contributes its own hover/pressed
## feedback for free.
##
## Scene setup — a Button root sized to your portrait dimensions, with
## three full-rect-anchored children (unchanged from the original
## Control version):
##   - TextureRect named "Portrait"       — the unit's art
##   - ColorRect named "DamageOverlay"    — semi-transparent red; grows
##     upward from the bottom as the unit loses HP
##   - Panel named "OutlineFrame"         — colored border, see
##     _setup_outline. Last child (drawn on top) so the border stays
##     crisp regardless of how much the damage overlay has filled in.
##
## Put one instance of this scene per unit inside an HBoxContainer (the
## initiative strip) or add directly to any Container (the party panel)
## — HBoxContainer is the right tool for arranging MULTIPLE portraits in
## a row; it's just the wrong tool for a single portrait's internal
## layers, which is why those live as manually-anchored children instead.
##
## The overlay never needs texture masking or a shader: it's just a
## rectangle whose height is driven by anchor_top. anchor_bottom stays
## pinned at 1 (bottom-locked); animating anchor_top from 1.0 (zero
## height) down to 0.0 (full height) as damage_fraction goes 0 -> 1 is
## what makes it read as "filling up from the bottom."

@export var unit: Unit
@export var overlay_color: Color = Color(1, 0, 0, 0.5)
## Border thickness, in pixels — the color itself comes from
## unit.selected_color (see _setup_outline), not a separate field, so a
## portrait's outline automatically matches whatever team color is
## already authored per-unit for the 3D hover/selection ring, instead of
## being a second place that color needs to be kept in sync.
@export var outline_width: float = 3.0
@export var highlight_tint: Color = Color(1.4, 1.3, 0.9, 1.0)
## How much bigger the portrait gets when highlighted, as a multiple of
## whatever size it's CURRENTLY shrunk to (see max_total_width/_fit_scale
## below) — applied uniformly to both axes so the aspect ratio never
## distorts. Allowed to (and normally will) grow PAST the portrait's
## original authored size — the "don't exceed the original size"
## constraint only ever applies to the UNHIGHLIGHTED case (_fit_scale is
## always <= 1.0); highlighting is the one deliberate exception, since
## making the current turn's portrait bigger than normal is the entire
## point of it. Unused by the party panel (nothing there ever calls
## set_highlighted), harmless to leave at its default there.
@export var highlight_scale: float = 1.25

@onready var portrait: TextureRect = $Portrait
@onready var damage_overlay: ColorRect = $DamageOverlay
@onready var outline_frame: Panel = $OutlineFrame

var _base_min_size: Vector2
## Uniform (both axes) scale applied to _base_min_size to get the
## CURRENT unhighlighted size — driven by whichever container this is
## in (initiative_row.gd shrinks every portrait equally as more units
## join a combat; party_panel.gd just sets one fixed value) so a row
## fits within its own target width instead of running off-screen,
## without ever distorting an individual portrait's aspect ratio. Always
## <= 1.0 — this only ever shrinks portraits below their authored size,
## never grows them past it. See _apply_size, which combines this with
## highlight_scale.
var _fit_scale: float = 1.0
var _highlighted: bool = false


func _ready() -> void:
	damage_overlay.color = overlay_color
	_base_min_size = custom_minimum_size

	# Top-aligned within a row, not vertically centered/filled — this is
	# what keeps every portrait's TOP edge level regardless of height, so
	# growing one's height on its turn extends downward from that shared
	# top edge instead of growing symmetrically (which would push into
	# neighbors) or shifting the whole row's baseline around.
	size_flags_vertical = Control.SIZE_SHRINK_BEGIN

	pressed.connect(_on_pressed)

	if not unit:
		return

	if unit.portrait_texture:
		portrait.texture = unit.portrait_texture

	_setup_outline()

	unit.took_damage.connect(func(_u, _amount): _update_overlay())
	unit.died.connect(func(_u): _update_overlay())
	_update_overlay()


func _on_pressed() -> void:
	if not unit:
		return
	var additive: bool = Input.is_action_pressed("select_additive")
	SelectionManager.select(unit, additive)


## Called by initiative_row.gd — grows the slot's actual RESERVED height
## in the HBoxContainer (custom_minimum_size), not a visual scale
## transform, so the container allocates the extra room itself instead
## of the portrait spilling into space that belongs to a neighbor.
## Setting custom_minimum_size triggers Godot's normal container
## re-layout automatically; nothing else needs to be told to update.
func set_highlighted(value: bool) -> void:
	modulate = highlight_tint if value else Color(1, 1, 1, 1)
	_highlighted = value
	_apply_size()


## Uniform scale, set by whichever container owns this instance — see
## _fit_scale's doc comment. Combined with highlight growth in
## _apply_size rather than either one clobbering the other's write to
## custom_minimum_size.
func set_fit_scale(factor: float) -> void:
	_fit_scale = factor
	_apply_size()


## The size THIS portrait was originally authored at (custom_minimum_size
## in the editor, before any fit/highlight scaling) — read by
## initiative_row.gd to compute how much every portrait needs to shrink
## to fit N of them within its own target width, without needing its own
## separately-maintained copy of that number.
func get_base_min_size() -> Vector2:
	return _base_min_size


## Combines fit_scale with highlight_scale into ONE uniform multiplier.
## Unhighlighted, that's just fit_scale — always <= 1.0, so a unit NOT
## currently highlighted never renders bigger than its original authored
## size. Highlighted, fit_scale and highlight_scale multiply together
## with no ceiling — deliberately allowed to exceed the original size,
## since that's the whole visual point of highlighting.
func _apply_size() -> void:
	var scale: float = _fit_scale * highlight_scale if _highlighted else _fit_scale
	custom_minimum_size = _base_min_size * scale


## A transparent-center StyleBoxFlat with just a border is the simplest
## way to draw an outline on a Control — no shader, no custom _draw().
## border_color comes from unit.selected_color rather than a field of its
## own (see outline_width's doc comment).
func _setup_outline() -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0)
	style.set_border_width_all(outline_width)
	style.border_color = unit.selected_color
	outline_frame.add_theme_stylebox_override("panel", style)


func _update_overlay() -> void:
	if not unit or unit.maximum_hp <= 0:
		return

	var damage_fraction: float = 1.0 - float(unit.current_hp) / float(unit.maximum_hp)
	damage_fraction = clamp(damage_fraction, 0.0, 1.0)

	damage_overlay.anchor_top = 1.0 - damage_fraction
