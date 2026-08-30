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
## Alternate, data-only source — used when unit is null (see _ready()).
## Renders the texture and outline color from a captured record with no
## live signal hookups and no click-to-select, for a party member that
## isn't currently spawned as a real Unit at all (the overworld's party
## display, e.g. — see PartyManager.roster).
@export var data: PartyMemberData
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

	# Shrink to natural size on whichever axis ends up being the CROSS axis
	# for whatever container this lands in — Godot's FILL default (both
	# flags) stretches a child across the full cross-axis space, which is
	# wrong here in either orientation this component gets used in: in
	# initiative_row.gd's HBoxContainer that's height (a tall portrait
	# would push into its neighbors); in party_panel.gd's VBoxContainer
	# that's width (stretches the button far past its authored aspect
	# ratio, and Portrait's STRETCH_KEEP_ASPECT_COVERED then crops/zooms
	# to cover the mismatched rect instead of showing the whole image).
	# Setting both SHRINK_BEGIN here means whichever axis turns out to be
	# "cross" is already handled, regardless of which container this ends
	# up in. Also keeps every portrait's TOP-LEFT corner level regardless
	# of size changes (highlighting, fit-scale), instead of growing
	# symmetrically or shifting a row's baseline around.
	size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	size_flags_vertical = Control.SIZE_SHRINK_BEGIN

	pressed.connect(_on_pressed)

	if unit:
		if unit.portrait_texture:
			portrait.texture = unit.portrait_texture
		_setup_outline(unit.selected_color)
		unit.took_damage.connect(func(_u, _amount): _update_overlay())
		unit.healed.connect(func(_u, _amount): _update_overlay())
		unit.died.connect(func(_u): _update_overlay())
		_update_overlay()
	elif data:
		if data.portrait_texture:
			portrait.texture = data.portrait_texture
		_setup_outline(data.selected_color)
		# No live HP to show for a record that isn't spawned right now.
		damage_overlay.visible = false


func _on_pressed() -> void:
	if not unit:
		return

	# A member standing in another world can't be selected there — the
	# selection drives orders in the world on screen. Clicking them means
	# "go to them", so that is what it does, and the selection follows once
	# they are actually in front of the player.
	var context: WorldContext = WorldManager.context()
	if context and not context.contains(unit):
		if not WorldManager.focus_world_of(unit):
			return

	var additive: bool = Input.is_action_pressed("select_additive")
	SelectionManager.select(unit, additive)


## Dims a member who is somewhere the player isn't looking. Purely a
## readout — the portrait stays clickable, and clicking it is how you go
## to them (see _on_pressed).
func set_elsewhere(value: bool) -> void:
	modulate = Color(0.45, 0.45, 0.55, 1.0) if value else Color(1, 1, 1, 1)


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
## color comes from whichever source _ready() is currently using
## (unit.selected_color or data.selected_color) rather than a field of
## its own (see outline_width's doc comment).
func _setup_outline(color: Color) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0)
	style.set_border_width_all(outline_width)
	style.border_color = color
	outline_frame.add_theme_stylebox_override("panel", style)


func _update_overlay() -> void:
	if not unit or unit.maximum_hp <= 0:
		return

	var damage_fraction: float = 1.0 - float(unit.current_hp) / float(unit.maximum_hp)
	damage_fraction = clamp(damage_fraction, 0.0, 1.0)

	damage_overlay.anchor_top = 1.0 - damage_fraction
