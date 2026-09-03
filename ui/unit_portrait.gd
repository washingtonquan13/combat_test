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
## four children, the first three full-rect-anchored (unchanged from the
## original Control version) and one thin edge bar added for the party
## rail:
##   - TextureRect named "Portrait"       — the unit's art
##   - ColorRect named "DamageOverlay"    — semi-transparent red; grows
##     upward from the bottom as the unit loses HP
##   - Panel named "OutlineFrame"         — colored border, see
##     _setup_outline.
##   - ColorRect named "SpeakingMarker"   — thin bar pinned to the top
##     edge, hidden unless set_speaking(true). Last child (drawn on top
##     of everything, OutlineFrame included) so neither the outline nor
##     the damage overlay can ever cover it up.
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
## The group this portrait belongs to. Set by whatever built the row.
## For a member with no live Unit it is the ONLY way back to them —
## they exist as a record inside a group and as part of an avatar on
## the overworld, and neither is a node this portrait could point at.
var group: PartyGroup = null
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
## Small top-edge bar, shown only while this portrait's unit is the
## current speaker in a conversation — see set_speaking() and
## party_panel.gd's _set_speaking_unit(). Not used by initiative_row.gd
## at all (nothing there ever calls set_speaking), same as
## highlight_scale above; harmless to leave authored either way.
@onready var speaking_marker: ColorRect = $SpeakingMarker

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
	if unit:
		# A member standing in another world cannot be selected there — the
		# selection drives orders in the world on screen. Clicking them
		# means "go to them", so that is what it does, and the selection
		# follows once they are in front of the player.
		var context: WorldContext = WorldManager.context()
		if context and not context.contains(unit):
			# By the UNIT. Routing this through the group meant asking a
			# second-hand record where somebody standing right there was.
			var result := WorldManager.reveal(unit, PartyManager.group_of(unit))
			if not WorldManager.revealed(result):
				_report_unreachable(unit.display_name, result)
				return
		var additive: bool = Input.is_action_pressed("select_additive")
		SelectionManager.select(unit, additive)
		return

	# No live Unit: this member is abstract, standing on the overworld as
	# part of an avatar. There is nothing to select, so clicking can only
	# mean "go to them" — and this is the one route back to a group that
	# has no Units to click in the world either.
	if group:
		var result := WorldManager.reveal(null, group)
		if not WorldManager.revealed(result):
			_report_unreachable(data.display_name if data else "That member", result)


## A click that goes nowhere has to say so. Swallowing the refusal is
## what made this feel like an unexplained dead portrait rather than a
## world that is simply not loaded right now.
func _report_unreachable(who: String, result: int) -> void:
	match result:
		WorldManager.Reveal.REFUSED_MODAL:
			SystemLog.print("Can't go to %s right now." % who)
		WorldManager.Reveal.AREA_NOT_LOADED:
			SystemLog.print("%s is somewhere not currently loaded." % who)
		_:
			SystemLog.print("Can't find %s." % who)


## How a member standing in another world reads. Purely a readout — the
## portrait stays clickable either way, and clicking it is how you go to
## them (see _on_pressed).
##
## Two states rather than one, because "away" and "away and stalled
## waiting for you" are different news. Dimmed says the party is split;
## lit warm against the dimmed rest says a fight over there has run out of
## things it can do without you, which is the one thing here that is
## actually urgent.
func set_elsewhere(value: bool, needs_attention: bool = false) -> void:
	if needs_attention:
		modulate = Color(1.35, 0.85, 0.55, 1.0)
	elif value:
		modulate = Color(0.45, 0.45, 0.55, 1.0)
	else:
		modulate = Color(1, 1, 1, 1)


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


## Toggles the top-edge speaking marker — see the SpeakingMarker export
## comment above. Called by party_panel.gd, never set directly here:
## this portrait has no opinion of its own about who is currently
## talking, same reason set_highlighted() is driven by initiative_row.gd
## rather than this script watching CombatManager itself.
func set_speaking(value: bool) -> void:
	speaking_marker.visible = value
