extends Control
## Single portrait for a BG3-style initiative order row.
##
## Scene setup — a plain Control (NOT a layout Container, since its two
## children need to overlap, not flow side by side), sized to your
## portrait dimensions, with two full-rect-anchored children:
##   - TextureRect named "Portrait"       — the unit's art
##   - ColorRect named "DamageOverlay"    — semi-transparent red; grows
##     upward from the bottom as the unit loses HP
##
## Put one instance of this scene per combatant inside an HBoxContainer
## for the horizontal initiative strip — HBoxContainer is the right tool
## for arranging MULTIPLE portraits in a row; it's just the wrong tool
## for a single portrait's internal layers, which is why those live in a
## plain Control instead.
##
## The overlay never needs texture masking or a shader: it's just a
## rectangle whose height is driven by anchor_top. anchor_bottom stays
## pinned at 1 (bottom-locked); animating anchor_top from 1.0 (zero
## height) down to 0.0 (full height) as damage_fraction goes 0 -> 1 is
## what makes it read as "filling up from the bottom."

@export var unit: Unit
@export var overlay_color: Color = Color(1, 0, 0, 0.5)
@export var highlight_tint: Color = Color(1.4, 1.3, 0.9, 1.0)
## How much bigger the portrait gets on this unit's turn, as a multiple
## of whatever size it's CURRENTLY shrunk to by the row (see
## initiative_row.gd's max_total_width/_fit_scale) — applied uniformly to
## both axes, unlike before, so the aspect ratio never distorts. This is
## allowed to (and normally will) grow PAST the portrait's original
## authored size — the "don't exceed the original size" constraint only
## ever applied to the UNHIGHLIGHTED case (see _fit_scale, which is
## always <= 1.0); highlighting is the one deliberate exception, since
## making the current turn's portrait bigger than normal is the entire
## point of it.
@export var highlight_scale: float = 1.25

@onready var portrait: TextureRect = $Portrait
@onready var damage_overlay: ColorRect = $DamageOverlay

var _base_min_size: Vector2
## Uniform (both axes) scale applied to _base_min_size to get the
## CURRENT unhighlighted size — driven by initiative_row.gd to shrink
## every portrait equally as more combatants join, so the whole row fits
## within its own max_total_width instead of running off-screen. Always
## <= 1.0 — this only ever shrinks portraits below their authored size,
## never grows them past it. Uniform on purpose: scaling width and height
## by the SAME factor is what keeps each portrait's aspect ratio exactly
## as authored. See _apply_size, which combines this with highlight_scale.
var _fit_scale: float = 1.0
var _highlighted: bool = false


func _ready() -> void:
	damage_overlay.color = overlay_color
	_base_min_size = custom_minimum_size

	# Top-aligned within the row, not vertically centered/filled — this
	# is what keeps every portrait's TOP edge level regardless of height,
	# so growing one's height on its turn extends downward from that
	# shared top edge instead of growing symmetrically (which would push
	# into neighbors) or shifting the whole row's baseline around.
	size_flags_vertical = Control.SIZE_SHRINK_BEGIN

	if not unit:
		return

	if unit.portrait_texture:
		portrait.texture = unit.portrait_texture

	unit.took_damage.connect(func(_u, _amount): _update_overlay())
	unit.died.connect(func(_u): _update_overlay())
	_update_overlay()


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


## Uniform fit-to-row scale, set by initiative_row.gd — see _fit_scale's
## doc comment. Combined with highlight growth in _apply_size rather than
## either one clobbering the other's write to custom_minimum_size.
func set_fit_scale(factor: float) -> void:
	_fit_scale = factor
	_apply_size()


## The size THIS portrait was originally authored at (custom_minimum_size
## in the editor, before any fit/highlight scaling) — read by
## initiative_row.gd to compute how much every portrait needs to shrink
## to fit N of them within max_total_width, without needing its own
## separately-maintained copy of that number.
func get_base_min_size() -> Vector2:
	return _base_min_size


## Combines the row's fit_scale with highlight_scale into ONE uniform
## multiplier. Unhighlighted, that's just fit_scale — always <= 1.0, so a
## unit NOT currently taking its turn never renders bigger than its
## original authored size. Highlighted, fit_scale and highlight_scale
## multiply together with no ceiling — deliberately allowed to exceed the
## original size, since that's the whole visual point of highlighting the
## current turn.
func _apply_size() -> void:
	var scale: float = _fit_scale * highlight_scale if _highlighted else _fit_scale
	custom_minimum_size = _base_min_size * scale


func _update_overlay() -> void:
	if not unit or unit.maximum_hp <= 0:
		return

	var damage_fraction: float = 1.0 - float(unit.current_hp) / float(unit.maximum_hp)
	damage_fraction = clamp(damage_fraction, 0.0, 1.0)

	damage_overlay.anchor_top = 1.0 - damage_fraction
