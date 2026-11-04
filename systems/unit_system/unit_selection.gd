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
## highlight_mesh/outline_mesh stay as plain @export vars directly on Unit
## rather than moving in here — same editor-safety reasoning as
## UnitFacing's rotation_speed/facing_offset_degrees: the editor needs to
## read/write @export values before this component ever exists. This
## component reads them back through its owner reference when it needs
## them.
##
## THE RING. highlight_mesh is no longer drawn. It was a filled 1 m disc
## sitting on the floor, which z-fought with it and covered whatever was
## underfoot. The body still declares it, because the body is what knows
## its footprint: its mesh is read once for a radius, then cleared, and
## the node stays on as the ring's on/off switch (its `visible` is what
## everything outside, tests included, reads as "the ring is showing").
## Under it hang two Decals and a drop line, all top_level so they can be
## put where the GROUND is rather than where the body is:
## - each physics frame a ring is up and the unit has moved, a ray goes
##   straight down from the unit, past every unit body, and both decals
##   are placed at the first hit. A decal paints every surface inside its
##   box, so the box is short (DECAL_HEIGHT) and sits ON that hit: a unit
##   on a bridge rings the bridge, not the street under it. Parenting a
##   tall decal to the unit would have painted both.
## - cull_mask leaves out Unit.RENDER_LAYER, which every unit body and
##   held weapon wears (Unit.wear_render_layer), so a ring never paints a
##   boot — the same arrangement the ground surfaces (Grease, Water) use.
## - a flier (or anything well above the hit) also gets a thin vertical
##   line from its feet down to the ring, so its height reads at a glance.
##
## COLOUR IS RELATION, STATE IS WEIGHT (see IndicatorPalette). The hue
## says who the unit is to the party — PARTY, ENEMY, NEUTRAL, decided by
## FactionRelations — and hover/selection only change thickness and
## opacity. hover_color/selected_color on Unit no longer touch the ring;
## selected_color lives on as the unit's UI accent (portrait, dialogue).
## The gold outer ring marks whose turn it is, for any faction, and while
## it is not a party unit's turn the party's own rings dim, so a
## selection left over from your last turn does not read as "yours to
## act" while an enemy moves.
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

## Ring widths, as fractions of the ring's own radius — the state axis.
## Thin, BG3-style: a crisp core of a few cm plus a soft halo
## (RING_GLOW), so selection reads by brightness, not by bulk.
const RING_WIDTH_HOVER: float = 0.035
const RING_WIDTH_SELECTED: float = 0.06
const RING_ALPHA_HOVER: float = 0.6
const RING_ALPHA_SELECTED: float = 1.0
## How far a party ring fades while someone outside the party is acting.
## Dimmed, not hidden: the player should still see who they had selected
## when control comes back.
const PARTY_WAITING_ALPHA: float = 0.35
## The turn marker: an outer ring, so it reads alongside a selection ring
## rather than replacing it.
const TURN_RING_WIDTH: float = 0.04
const TURN_RING_SCALE: float = 1.3
const TURN_PULSE_HZ: float = 1.2
const TURN_PULSE_MIN_ALPHA: float = 0.55
## Used when the body's highlight mesh has no readable footprint. Same as
## the PickArea's radius, so the ring is the size of what you can click.
const DEFAULT_RING_RADIUS: float = 0.5
## Decal box height. Short on purpose: everything inside the box gets
## painted, so this is the vertical slop the ring tolerates (a step, a
## slope under the footprint) and no more.
const DECAL_HEIGHT: float = 0.8
## The ring is emissive as well as coloured, so it still reads in a
## Darkness cloud or an unlit corner; decals are otherwise lit like the
## floor they sit on.
const RING_EMISSION: float = 1.0
## The ray starts this far above the feet, so a unit standing on a floor
## hits that floor from above rather than starting inside it.
const RAY_START_HEIGHT: float = 0.5
const RAY_LENGTH: float = 60.0
## The world's physics layer — the same default GroundClickTarget's
## ground_collision_mask uses. Units are on it too, hence the re-cast
## past them in _ground_below.
const GROUND_COLLISION_MASK: int = 1
## Below this a grounded unit's feet and the hit are the same place; above
## it the gap is worth drawing.
const DROP_LINE_MIN_HEIGHT: float = 0.3
## The drop line's fade at each end (it is a PathTube, the one look
## every indicator line shares).
const DROP_LINE_FADE: float = 0.25
const RING_TEXTURE_SIZE: int = 256
## Soft halo either side of the core, as a fraction of the radius, and
## its peak opacity. Inside the ring it is weaker, so the floor under
## the unit stays clean.
const RING_GLOW: float = 0.1
const RING_GLOW_ALPHA: float = 0.35

## Ring textures by width, shared by every unit: [albedo, emission].
static var _ring_textures: Dictionary = {}

var _ring: Decal
var _turn_ring: Decal
var _drop_line: PathTube
var _drop_color: Color = IndicatorPalette.ACTIVE_TURN
var _ring_radius: float = DEFAULT_RING_RADIUS
## Where the last ground ray started. The ray only re-casts when this
## moves, so a standing unit with its ring up costs nothing per frame.
var _last_cast_from: Vector3 = Vector3.INF
var _pulse_time: float = 0.0
var _update_queued: bool = false


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
	# This was two connections, to the old dialogue manager's started and
	# ended signals, which is a narrower question than the one being
	# asked: a conversation is one of several things that can take the
	# screen (a negotiation, a loot screen, a cutscene, a menu), and the
	# ring should recompute on any of them. GameMode already derives
	# exactly that and emits when it moves, so ask it instead — one
	# connection, and the answer stays right when a new mode is added.
	#
	# The turn and relation signals beside it follow the same lifetime for
	# the same reason: they are autoloads, so each connection must go when
	# this unit leaves the tree (see _exit_tree) and come back when it
	# returns.
	for pair in _autoload_connections():
		var sig: Signal = pair[0]
		if not sig.is_connected(pair[1]):
			sig.connect(pair[1])


## Every autoload signal this component listens to, in one list so
## _enter_tree and _exit_tree can never disagree about what to release.
##
## Turn signals are relayed by CombatManager from every running fight, so
## each unit hears every turn change anywhere; it only recomputes its own
## ring from its own encounter, which is cheap. Relation signals are here
## because a provoked attack turns a neutral faction hostile mid-scene,
## and a ring already lit should change colour with it.
func _autoload_connections() -> Array:
	return [
		[GameMode.mode_changed, _on_mode_changed],
		[CombatManager.turn_started, _on_turn_changed],
		[CombatManager.turn_ended, _on_turn_changed],
		[CombatManager.unit_joined_combat, _on_turn_changed],
		[CombatManager.unit_left_combat, _on_turn_changed],
		[CombatManager.combat_ended, _on_combat_ended],
		[FactionRelations.relation_changed, _on_relation_changed],
		[FactionRelations.temporary_hostility_started, _on_temporary_hostility_started],
		[FactionRelations.temporary_hostilities_cleared, _queue_update],
	]


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
		_build_ring(_owner.highlight_mesh)
		_owner.highlight_mesh.visible = false

	if _owner.outline_mesh:
		_owner.outline_mesh.visible = false

	# The owner's own signal, not an autoload's, so it dies with the owner
	# and needs no release. A unit can die on its own turn, and nothing
	# else would take the turn marker off its corpse in the meantime.
	_owner.died.connect(_on_owner_died)
	set_physics_process(false)


## Turns the body's highlight mesh into the ring's anchor and hangs the
## decals and drop line under it. Each unit builds its own nodes, so rings
## change colour independently; only the textures are shared.
func _build_ring(anchor: MeshInstance3D) -> void:
	if anchor.mesh:
		var extent: Vector3 = anchor.mesh.get_aabb().size * anchor.global_basis.get_scale()
		var footprint: float = maxf(extent.x, extent.z) * 0.5
		if footprint > 0.05:
			_ring_radius = footprint
	# The disc itself is what z-fought with the floor. The node stays, as
	# the switch and the parent; only its drawing goes.
	anchor.mesh = null
	anchor.material_override = null

	_ring = _make_ring_decal("Ring", _ring_radius)
	anchor.add_child(_ring)

	_turn_ring = _make_ring_decal("TurnRing", _ring_radius * TURN_RING_SCALE)
	_set_ring_look(_turn_ring, TURN_RING_WIDTH, IndicatorPalette.ACTIVE_TURN)
	anchor.add_child(_turn_ring)

	_drop_line = PathTube.new()
	_drop_line.name = "DropLine"
	_drop_line.fade_start = DROP_LINE_FADE
	_drop_line.fade_end = DROP_LINE_FADE
	# On the units' layer, so ground decals (this ring included) leave it
	# alone rather than smearing over its lower end.
	_drop_line.layers = 1 << (Unit.RENDER_LAYER - 1)
	anchor.add_child(_drop_line)


func _make_ring_decal(decal_name: String, ring_radius: float) -> Decal:
	var decal := Decal.new()
	decal.name = decal_name
	decal.top_level = true
	decal.size = Vector3(ring_radius * 2.0, DECAL_HEIGHT, ring_radius * 2.0)
	# A decal projects straight down; on a wall or a riser the ring would
	# smear into vertical streaks. Same value the ground surfaces use.
	decal.normal_fade = 0.6
	# Keep the ring crisp across the box: the defaults fade it out well
	# before the box's ends, which on a short box loses half a step.
	decal.upper_fade = 0.1
	decal.lower_fade = 0.1
	decal.albedo_mix = 1.0
	decal.cull_mask = 0xFFFFF & ~(1 << (Unit.RENDER_LAYER - 1))
	# Drawn over a ground surface (Grease, Water) rather than under it.
	decal.sorting_offset = 1.0
	decal.visible = false
	return decal


## Width is the texture (thickness is part of the picture); colour and
## brightness are the decal's modulate and emission. Emission ignores
## modulate's alpha, so a dimmed ring has its emission dimmed to match.
func _set_ring_look(decal: Decal, width: float, color: Color) -> void:
	var textures: Array = _ring_textures_for(width)
	decal.texture_albedo = textures[0]
	decal.texture_emission = textures[1]
	decal.modulate = color
	decal.emission_energy = RING_EMISSION * color.a


## An anti-aliased ring filling the texture, `width` as a fraction of its
## radius. Two pictures per width: albedo is white with the ring in alpha,
## emission is the ring in RGB on black — a decal's emission reads only
## RGB, so a white emission texture would light the whole square.
static func _ring_textures_for(width: float) -> Array:
	if _ring_textures.has(width):
		return _ring_textures[width]
	var size: int = RING_TEXTURE_SIZE
	var half: float = size * 0.5
	# A pixel and a half of margin, so the ring's outer edge is
	# anti-aliased rather than clipped by the texture border.
	var outer: float = half - 1.5
	var inner: float = outer - width * outer
	var glow: float = RING_GLOW * outer
	outer -= glow
	inner -= glow
	var albedo := Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
	var emission := Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
	for y in size:
		for x in size:
			var d: float = Vector2(x + 0.5 - half, y + 0.5 - half).length()
			var core: float = clampf(minf(outer - d, d - inner) + 0.5, 0.0, 1.0)
			var gap: float = maxf(d - outer, inner - d)
			var halo: float = 0.0
			if gap > 0.0:
				var side: float = 1.0 if d > outer else 0.5
				halo = RING_GLOW_ALPHA * side * exp(-pow(gap / (glow * 0.45), 2.0))
			var coverage: float = maxf(core, halo)
			albedo.set_pixel(x, y, Color(1.0, 1.0, 1.0, coverage))
			emission.set_pixel(x, y, Color(coverage, coverage, coverage, 1.0))
	albedo.generate_mipmaps()
	emission.generate_mipmaps()
	var textures: Array = [ImageTexture.create_from_image(albedo), ImageTexture.create_from_image(emission)]
	_ring_textures[width] = textures
	return textures


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
	for pair in _autoload_connections():
		var sig: Signal = pair[0]
		if sig.is_connected(pair[1]):
			sig.disconnect(pair[1])


func _on_mode_changed(_mode: GameMode.Mode) -> void:
	update_highlight()


## Untyped: turn_ended and unit_left_combat can name a unit freed this
## same frame, and a typed parameter would error at the call.
func _on_turn_changed(_unit) -> void:
	_queue_update()


func _on_combat_ended(_winning_faction: StringName) -> void:
	_queue_update()


func _on_relation_changed(_faction_a: StringName, _faction_b: StringName, _tier) -> void:
	_queue_update()


func _on_temporary_hostility_started(_faction_a: StringName, _faction_b: StringName) -> void:
	_queue_update()


func _on_owner_died(_unit) -> void:
	update_highlight()


## Turn and relation changes recompute once, at the end of the frame,
## rather than inside the signal. Two reasons: those signals fire mid-
## transition (turn_ended before the next turn exists, unit_left_combat
## from inside a release), so the settled state is what should be drawn;
## and every unit hears every one of them, so a burst of them collapses
## into one recompute per unit.
func _queue_update() -> void:
	if _update_queued:
		return
	_update_queued = true
	_flush_update.call_deferred()


func _flush_update() -> void:
	_update_queued = false
	if is_inside_tree() and is_instance_valid(_owner):
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
	var show: bool = is_selected or is_hovered or box_hovered
	var my_turn: bool = _is_active_turn()

	# Hue from relation, weight from state. Selected wins over hovered.
	var width: float = RING_WIDTH_SELECTED if is_selected else RING_WIDTH_HOVER
	var state_color: Color = _relation_color()
	state_color.a = RING_ALPHA_SELECTED if is_selected else RING_ALPHA_HOVER
	if _party_is_waiting():
		width = RING_WIDTH_HOVER
		state_color.a *= PARTY_WAITING_ALPHA

	if _owner.highlight_mesh:
		var was_showing: bool = _owner.highlight_mesh.visible
		var any_ring: bool = show or my_turn
		_owner.highlight_mesh.visible = any_ring
		if _ring:
			_ring.visible = show
			if show:
				_set_ring_look(_ring, width, state_color)
		if _turn_ring:
			if my_turn and not _turn_ring.visible:
				_pulse_time = 0.0
			_turn_ring.visible = my_turn
		var line_color: Color = state_color if show else IndicatorPalette.ACTIVE_TURN
		line_color.a = minf(line_color.a, 0.7)
		if line_color != _drop_color:
			_drop_color = line_color
			# Recoloured where it already stands.
			_last_cast_from = Vector3.INF
		if any_ring and not was_showing:
			# Never drawn where it last was (or at the world origin, for a
			# ring never placed) while the first ray waits for the next
			# physics frame: the feet are right for a grounded unit, and a
			# frame of a flier's ring at its feet is the lesser glitch.
			_last_cast_from = Vector3.INF
			for decal in [_ring, _turn_ring]:
				if decal and _owner.is_inside_tree():
					decal.global_position = _owner.global_position
		if not any_ring and _drop_line:
			_drop_line.visible = false
		set_physics_process(any_ring)

	if _owner.outline_mesh:
		_owner.outline_mesh.visible = show
		if show:
			var outline_material := _owner.outline_mesh.material_override as ShaderMaterial
			if outline_material:
				outline_material.set_shader_parameter("outline_color", state_color)


## Who this unit is to the party. PARTY is "a unit the player commands"
## (Unit.is_player_controlled, the same rule SelectionManager enforces);
## past that the existing hostility query decides. An allied faction that
## is not the player's reads NEUTRAL, deliberately: blue promises "yours
## to command", and an ally is not.
func _relation_color() -> Color:
	if _owner.is_player_controlled():
		return IndicatorPalette.PARTY
	if FactionRelations.is_hostile(_owner.faction, Unit.PLAYER_FACTION):
		return IndicatorPalette.ENEMY
	return IndicatorPalette.NEUTRAL


## Whether this unit's turn is live right now. Asked of its own encounter,
## not the focused one — a fight off screen still has a unit whose turn
## it is. ACTIVE only: between turns (TURN_ENDING/TURN_STARTING) the
## encounter's current_unit can already name the NEXT unit before its turn
## has begun, and the marker should not run ahead of the turn.
func _is_active_turn() -> bool:
	if not _owner.is_alive():
		return false
	var encounter: Encounter = _owner.encounter
	if encounter == null or encounter.phase != Encounter.Phase.ACTIVE:
		return false
	var current = encounter.current_unit
	return is_instance_valid(current) and current == _owner


## A party unit, in a fight, while someone outside the party acts. Read
## from current_unit rather than the phase, so the brief gap between two
## party turns does not flicker every party ring dim and back.
func _party_is_waiting() -> bool:
	if not _owner.is_player_controlled() or not _owner.in_combat():
		return false
	var current = _owner.encounter.current_unit
	return is_instance_valid(current) and not current.is_player_controlled()


## Keeps the rings on the ground under a moving unit, and pulses the turn
## marker. Only on while a ring is up (see update_highlight).
func _physics_process(delta: float) -> void:
	if _turn_ring and _turn_ring.visible:
		_pulse_time += delta
		var wave: float = 0.5 + 0.5 * cos(_pulse_time * TAU * TURN_PULSE_HZ)
		var pulse: Color = IndicatorPalette.ACTIVE_TURN
		pulse.a = lerpf(TURN_PULSE_MIN_ALPHA, 1.0, wave)
		_turn_ring.modulate = pulse
		_turn_ring.emission_energy = RING_EMISSION * pulse.a

	var from: Vector3 = _owner.global_position + Vector3.UP * RAY_START_HEIGHT
	if from.is_equal_approx(_last_cast_from):
		return
	_last_cast_from = from
	_place_ring(from)


func _place_ring(from: Vector3) -> void:
	var feet: Vector3 = _owner.global_position
	var ground: Vector3 = feet
	var hit: Dictionary = _ground_below(from)
	if not hit.is_empty():
		ground = hit.position
	for decal in [_ring, _turn_ring]:
		if decal:
			decal.global_position = ground

	if _drop_line == null:
		return
	var drop: float = feet.y - ground.y
	var airborne: bool = _owner.is_flying() or drop > DROP_LINE_MIN_HEIGHT
	_drop_line.visible = airborne and drop > 0.05 and not hit.is_empty()
	if _drop_line.visible:
		_drop_line.show_line(PackedVector3Array([feet, Vector3(feet.x, ground.y, feet.z)]), _drop_color)


## The first non-unit surface straight below `from`. Units share the
## world's physics layer, so they are re-cast past rather than masked —
## the same approach as GroundClickTarget._raycast_past_units, starting
## with this unit's own body already excluded. A handful of units stacked
## in one column (a flier over a crowd) is the most this ever loops.
func _ground_below(from: Vector3) -> Dictionary:
	var space: PhysicsDirectSpaceState3D = _owner.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		from, from + Vector3.DOWN * RAY_LENGTH, GROUND_COLLISION_MASK)
	var exclude: Array[RID] = [_owner.get_rid()]
	for i in 8:
		query.exclude = exclude
		var hit: Dictionary = space.intersect_ray(query)
		if hit.is_empty() or not (hit.collider is Unit):
			return hit
		exclude.append(hit.rid)
	return {}
