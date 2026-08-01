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
## How much taller the portrait gets on this unit's turn, as a multiple
## of its normal height (set via custom_minimum_size in the editor).
## Height only, not width — growing width too would push into
## left/right neighbors, which is exactly what this is meant to avoid.
@export var highlight_height_scale: float = 1.25

@onready var portrait: TextureRect = $Portrait
@onready var damage_overlay: ColorRect = $DamageOverlay

var _base_min_size: Vector2


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
	if value:
		custom_minimum_size = Vector2(_base_min_size.x * highlight_height_scale, _base_min_size.y * highlight_height_scale)
	else:
		custom_minimum_size = _base_min_size


func _update_overlay() -> void:
	if not unit or unit.maximum_hp <= 0:
		return

	var damage_fraction: float = 1.0 - float(unit.current_hp) / float(unit.maximum_hp)
	damage_fraction = clamp(damage_fraction, 0.0, 1.0)

	damage_overlay.anchor_top = 1.0 - damage_fraction
