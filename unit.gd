class_name Unit
extends CharacterBody3D

@export var strength: int = 10
@export var dexterity: int = 10
@export var intelligence: int = 10
@export var health: int = 10

@export var maximum_hp: int = 10
@export var current_hp: int = 10
@export var maximum_fp: int = 10
@export var current_fp: int = 10

## No longer referenced by combat resolution — Ability resources (see
## ability.gd) carry their own damage dice now, so a given ability isn't
## tied to whichever fixed die a unit happens to have. Left in place
## rather than removed since a future weapon system (weapon choice is
## already on the project's to-do list) is a plausible reason to want a
## unit's base weapon dice again, at which point an Ability could pull
## from these instead of (or in addition to) its own embedded dice.
@onready var thrust: Die = $Thrust
@onready var swing: Die = $Swing
@onready var damage: Die = $Damage

@export var move: int = 5
## Real-time speed (world units/sec) while executing a move order. Distinct
## from `move`, which is the per-turn distance budget in combat.
@export var move_speed: float = 4.0
## This unit's rough collision radius — used for range calculations
## (see edge_distance_to and Ability.is_in_range: edge-to-edge, not
## center-to-center) and as the basis for avoidance clearance (see
## avoidance_margin below). Set to roughly match the actual collision
## shape.
@export var radius: float = 0.5
## Extra buffer added on top of radius for planning purposes only — the
## physical collision shape stays exactly radius, this just tells the
## planning simulation (see PathAvoidance.simulate_path) to route with a
## bit more separation than the bare minimum. Zero slack means any small
## imprecision eats directly into actual contact instead of a buffer
## absorbing it.
@export var avoidance_margin: float = 0.15
## How close (meters) to a move's destination counts as "arrived" —
## NavigationAgent3D defaults this to 1.0m, which is often larger than
## reach itself, so a unit can report movement finished while still up to
## a meter short of the standoff point CombatAI aimed for. Kept small and
## explicit so "arrived" actually means arrived.
@export var arrival_tolerance: float = 0.15
## If a move makes no meaningful progress for this many seconds — e.g. a
## nav target that's genuinely unreachable — the move is abandoned instead
## of hanging the turn forever. Avoidance (below) should make this rare in
## practice; it's now a last-resort safety net rather than the main fix.
@export var stuck_timeout: float = 1.5
@onready var nav_agent: NavigationAgent3D = $NavigationAgent3D

@export var damage_reduction: int = 0

@export_group("Combat")
## Units with a different faction than the acting unit are valid attack
## targets when clicked during that unit's turn; same-faction clicks still
## select as normal (see _on_input_event / is_hostile_to).
@export var faction: StringName = &"player"
## Abilities this unit currently has available. abilities[0] is used as
## the default (see default_ability) when nothing's explicitly armed via
## AbilityManager — that's what makes click-to-attack keep working before
## a hotbar exists to actually choose between multiple abilities.
@export var abilities: Array[Ability] = []

@export_group("Death")
## Seconds between a unit's HP hitting 0 and its node actually being freed.
## 0 means immediate. Raise this if you want time for a death animation or
## ragdoll to play before the unit disappears — see _handle_death.
@export var death_cleanup_delay: float = 0.0
## Whether a dead unit's collision shape keeps blocking other units'
## movement (e.g. as terrain-like debris) or is cleared so the space opens
## back up immediately. Avoidance participation is turned off either way.
@export var corpse_blocks_movement: bool = false

@export_group("Selection")
## Optional visual child (e.g. a flat ring or decal MeshInstance3D at the
## unit's feet) used to show hover/selection state. Safe to leave
## unassigned — highlighting is just skipped if there's no mesh.
@export var highlight_mesh: MeshInstance3D
@export var hover_color: Color = Color(1, 1, 1, 0.5)
@export var selected_color: Color = Color(1, 0.85, 0.2, 0.9)

@export_group("UI")
## Shown in the initiative order portrait (see initiative_portrait.gd) and
## anywhere else in UI that wants a picture for this unit. Optional —
## leave unset and assign the TextureRect's texture directly in the
## editor instead, if you'd rather not route it through Unit.
@export var portrait_texture: Texture2D

signal hover_started(unit: Unit)
signal hover_ended(unit: Unit)
signal selected(unit: Unit)
signal deselected(unit: Unit)

## result dict shape: { in_range, already_acted, hit, damage, to_hit,
## raw_damage, ability }
signal ability_used(attacker: Unit, target: Unit, result: Dictionary)
signal took_damage(unit: Unit, amount: int)
signal died(unit: Unit)

signal movement_started(unit: Unit)
signal movement_finished(unit: Unit)

var is_hovered: bool = false
var is_selected: bool = false

## --- Turn action budget (combat) ---
## Reset by CombatManager at the start of this unit's turn. move_remaining
## counts down as movement code (not part of this file) calls spend_move().
## has_attacked gates attack() to once per turn.
var move_remaining: float = 0.0
var has_attacked: bool = false

var _moving: bool = false
var _move_start_position: Vector3 = Vector3.ZERO
var _stuck_timer: float = 0.0
var _last_progress_position: Vector3 = Vector3.ZERO
## The exact route this unit is currently walking, and which point in it
## is next. This is planned ONCE, in full, before movement starts (see
## move_to / PathAvoidance.simulate_path) — nothing about avoidance is
## decided live while walking; _physics_process just follows these fixed
## points. That's what makes the move's exact arrival point and distance
## known in advance rather than discovered after the fact.
var _current_path: PackedVector3Array = PackedVector3Array()
var _path_index: int = 0
## The planned path's exact total length, computed once when the plan is
## made. Spent as this turn's move budget on a normal completion — see
## _finish_move — rather than re-measuring distance walked, since a
## precomputed, deterministically-followed path is authoritative by
## construction: there's no live deviation left that measuring could
## catch that the plan didn't already account for.
var _planned_distance: float = 0.0

## True while a drag-select box is currently overlapping this unit. Kept
## separate from is_hovered (real mouse-over) and is_selected (committed
## selection) so drag-select can preview without actually selecting until
## the drag finishes.
var _box_hovered: bool = false

var _highlight_material: StandardMaterial3D


func _ready() -> void:
	# CollisionObject3D (CharacterBody3D's base) already provides
	# mouse_entered/mouse_exited/input_event signals once this is on and
	# Project Settings > Physics > Common > Enable Object Picking is on
	# (it is by default).
	add_to_group("units")

	input_ray_pickable = true
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)
	input_event.connect(_on_input_event)

	_setup_highlight()
	_setup_avoidance()


func _setup_avoidance() -> void:
	nav_agent.radius = radius + avoidance_margin
	# Real-time RVO steering is intentionally OFF — see move_to()'s doc
	# comment for why. nav_agent is kept only for get_navigation_map()
	# and closest-point queries (used by PathAvoidance); it no longer
	# drives how this unit actually moves.
	nav_agent.avoidance_enabled = false


func _setup_highlight() -> void:
	if not highlight_mesh:
		return
	# Give this unit its own material instance so its ring can change
	# color independently of any siblings sharing the same base mesh.
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_highlight_material = mat
	highlight_mesh.material_override = mat
	highlight_mesh.visible = false


func _on_mouse_entered() -> void:
	is_hovered = true
	hover_started.emit(self)
	_update_highlight()


func _on_mouse_exited() -> void:
	is_hovered = false
	hover_ended.emit(self)
	_update_highlight()


## During combat, left-clicking an enemy unit while your own unit is both
## selected and the acting unit (CombatManager.current_unit) uses an
## ability against it instead of selecting it — whichever ability is
## currently armed via AbilityManager, or the acting unit's
## default_ability() if nothing's explicitly armed (keeps click-to-attack
## working before a hotbar exists to choose between abilities). Every
## other click falls through to normal selection — which is a safe no-op
## for non-player units regardless, since SelectionManager itself refuses
## anything that isn't is_player_controlled(). Clicking an enemy outside
## of a valid attack context does nothing, exactly as intended.
func _on_input_event(_camera: Node, event: InputEvent, _position: Vector3, _normal: Vector3, _shape_idx: int) -> void:
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return

	if CombatManager.in_combat:
		var acting_unit: Unit = CombatManager.current_unit
		if acting_unit and acting_unit != self and acting_unit.is_hostile_to(self) \
				and acting_unit in SelectionManager.selected_units:
			var ability: Ability = AbilityManager.armed_ability if AbilityManager.armed_ability else acting_unit.default_ability()
			if ability:
				acting_unit.use_ability(ability, self)
			return

	var additive: bool = event.shift_pressed
	SelectionManager.select(self, additive)


func is_hostile_to(other: Unit) -> bool:
	return faction != other.faction


## Whether this unit can be selected/commanded by the player at all.
## SelectionManager enforces this itself (see its select()/add()) so
## there's exactly one place this rule lives — no code path, including
## future ones, can put a non-player unit into a "selected" state.
## Interacting with an enemy (attacking, eventually talking to) stays a
## direct contextual action triggered by a click, not a persistent
## selection — see _on_input_event's attack routing.
func is_player_controlled() -> bool:
	return faction == &"player"


## Selection state is owned by SelectionManager — call
## SelectionManager.select()/deselect() rather than this directly, so the
## manager's selected_units list and this unit's state never drift apart.
func set_selected(value: bool) -> void:
	if is_selected == value:
		return
	is_selected = value
	if value:
		selected.emit(self)
	else:
		deselected.emit(self)
	_update_highlight()


## Called by a drag-select box while it's overlapping this unit, purely as
## a visual preview — does not touch is_selected or SelectionManager.
func set_box_hover(value: bool) -> void:
	if _box_hovered == value:
		return
	_box_hovered = value
	_update_highlight()


func _update_highlight() -> void:
	if not highlight_mesh:
		return
	if is_selected:
		highlight_mesh.visible = true
		_highlight_material.albedo_color = selected_color
	elif is_hovered or _box_hovered:
		highlight_mesh.visible = true
		_highlight_material.albedo_color = hover_color
	else:
		highlight_mesh.visible = false


func _physics_process(delta: float) -> void:
	if not _moving:
		return

	# Skip past any waypoints already within arrival_tolerance — matters
	# most right after a simulated step lands very close to the next
	# waypoint, so the unit doesn't stall trying to "arrive" at a point
	# behind or barely past its current position.
	while _path_index < _current_path.size():
		var to_waypoint: Vector3 = _current_path[_path_index] - global_position
		to_waypoint.y = 0.0
		if to_waypoint.length() > arrival_tolerance:
			break
		_path_index += 1

	if _path_index >= _current_path.size():
		_finish_move()
		return

	# Last-resort safety net — see stuck_timeout's doc comment. The path
	# being followed here was already planned to fit (see
	# PathAvoidance.simulate_path), so in normal circumstances this
	# should never trigger; it exists for genuinely unexpected physical
	# obstruction (e.g. physics collision response deviating from the
	# plan) rather than as the primary mechanism for anything.
	if global_position.distance_to(_last_progress_position) < 0.05:
		_stuck_timer += delta
		if _stuck_timer >= stuck_timeout:
			_finish_move()
			return
	else:
		_stuck_timer = 0.0
		_last_progress_position = global_position

	var to_target: Vector3 = _current_path[_path_index] - global_position
	to_target.y = 0.0
	var direction: Vector3 = to_target.normalized()

	velocity = direction * move_speed
	move_and_slide()


## Orders this unit toward destination. The ENTIRE route is planned once,
## up front — real navmesh path (walls) run through
## PathAvoidance.simulate_path (other units, budget truncation) — before
## any movement starts, then walked exactly as planned with no avoidance
## decisions made live. This is a deliberate choice, not an optimization:
## reactive avoidance (Godot's RVO, or an earlier version of this system
## that steered live every physics frame) cannot guarantee an exact
## arrival point or exact budget consumption, because it doesn't know
## what it's going to do until it's already doing it. Planning once
## up front — with the SAME deterministic function the movement indicator
## previews with — means the preview IS the plan IS what happens: no gap
## between what's shown and what occurs. Out of combat, budget is
## effectively unlimited (the unit just walks the full route). In
## combat: only CombatManager.current_unit may move, and the plan is
## truncated at exactly move_remaining — see PathAvoidance.simulate_path.
## extra_avoidance_exclusions lets a caller (e.g. CombatAI approaching its
## own attack target) leave specific units out of the plan's avoidance —
## you don't want to route around the very unit you're trying to reach.
func move_to(destination: Vector3, extra_avoidance_exclusions: Array = []) -> bool:
	if _moving:
		return false

	var budget: float = INF

	if CombatManager.in_combat:
		if CombatManager.current_unit != self:
			return false
		if not has_move_remaining():
			return false
		budget = move_remaining

	var excluded: Array = [self]
	excluded.append_array(extra_avoidance_exclusions)
	var obstacles: Dictionary = PathAvoidance.gather_obstacles(get_tree(), excluded)
	var map_rid: RID = nav_agent.get_navigation_map()
	var clearance: float = radius + avoidance_margin

	var safe_destination: Vector3 = PathAvoidance.clear_goal(
		destination, obstacles.positions, obstacles.radii, clearance, map_rid
	)

	var waypoints: PackedVector3Array = NavigationServer3D.map_get_path(map_rid, global_position, safe_destination, true)
	if waypoints.size() < 2:
		return false

	var planned_path: PackedVector3Array = PathAvoidance.simulate_path(
		waypoints, move_speed, budget,
		obstacles.positions, obstacles.radii, clearance, avoidance_margin, arrival_tolerance, map_rid
	)

	if planned_path.size() < 2:
		return false

	_current_path = planned_path
	_path_index = 1
	_planned_distance = PathAvoidance.path_length(planned_path)
	_move_start_position = global_position
	_stuck_timer = 0.0
	_last_progress_position = global_position
	_moving = true
	movement_started.emit(self)
	return true


## Cancels the current move order in place, still spending whatever
## distance was actually covered (combat only).
func stop_moving() -> void:
	if not _moving:
		return
	_finish_move()


func is_moving() -> bool:
	return _moving


func _finish_move() -> void:
	_moving = false
	velocity = Vector3.ZERO

	if CombatManager.in_combat:
		# The plan completed fully (walked every point) → charge its
		# exact known length, not a re-measurement — that length IS what
		# was walked, by construction, since nothing deviated from it.
		# Cut short instead (stuck_timeout, or a manual stop_moving()
		# mid-route) → fall back to actually-measured displacement, since
		# in that abnormal case the plan and reality genuinely diverged.
		var completed_fully: bool = _path_index >= _current_path.size()
		var traveled: float = _planned_distance if completed_fully else _move_start_position.distance_to(global_position)
		spend_move(traveled)

	_current_path = PackedVector3Array()
	_path_index = 0
	_planned_distance = 0.0
	movement_finished.emit(self)


## --- Combat ---

## Called by CombatManager when this unit's turn begins. Refills the move
## budget from the `move` stat and clears the attack flag.
func reset_turn_actions() -> void:
	move_remaining = float(move)
	has_attacked = false


## Whether this unit could cover `distance` this turn without exceeding
## its move budget. Not used internally by move_to() anymore (which
## clamps rather than rejects) — kept as a query helper for anything that
## wants to check reachability before committing to an order.
func can_move(distance: float) -> bool:
	return distance <= move_remaining + 0.001


## Deducts distance already moved from the remaining budget this turn.
## Clamped so overshoot (e.g. rounding) can't push it negative.
func spend_move(distance: float) -> void:
	move_remaining = max(move_remaining - distance, 0.0)


func has_move_remaining() -> bool:
	return move_remaining > 0.0


func is_alive() -> bool:
	return current_hp > 0


func distance_to(other: Unit) -> float:
	return global_position.distance_to(other.global_position)


## Center-to-center distance minus both units' radii — how far apart their
## actual bodies are, not their positions. This is what any range check
## (melee or ranged — see Ability.is_in_range) should be measured
## against; two units can be "touching" while still having meaningfully
## distant global_positions once you account for size.
func edge_distance_to(other: Unit) -> float:
	return max(distance_to(other) - radius - other.radius, 0.0)


## GURPS-style roll-under: 3d6 <= target_number succeeds. Lower rolls are
## always better, and margin is how far under (positive = comfortable pass).
func roll_vs(target_number: int) -> Dictionary:
	var roll: int = randi_range(1, 6) + randi_range(1, 6) + randi_range(1, 6)
	return {
		"roll": roll,
		"target": target_number,
		"success": roll <= target_number,
		"margin": target_number - roll,
	}


## Placeholder melee/ranged skill — just DX for now. Swap in a real skill
## lookup later (weapon skill, ability-specific skill, etc.) without
## touching use_ability()'s call site.
func attack_skill() -> int:
	return dexterity


## abilities[0], or null if this unit has none equipped. Used as the
## fallback when nothing's explicitly armed via AbilityManager — see that
## autoload's doc comment.
func default_ability() -> Ability:
	return abilities[0] if not abilities.is_empty() else null


## Resolves using ability against target. Range/LoS rules and damage
## dice come entirely from the Ability resource — this method just
## enforces turn state (the once-per-turn attack action) and rolls
## to-hit/damage, same shape regardless of what kind of ability it is.
## A miss still spends the action if the ability uses one, same as
## before: the attempt itself is what's spent, not the hit.
## Returns a result dict for logging/UI:
## { in_range, already_acted, hit, damage, to_hit, raw_damage, ability }
func use_ability(ability: Ability, target: Unit) -> Dictionary:
	var result := {
		"attacker": self,
		"target": target,
		"ability": ability,
		"in_range": ability.is_in_range(self, target),
		"already_acted": ability.uses_attack_action and has_attacked,
		"hit": false,
		"damage": 0,
	}

	if result.already_acted:
		return result

	if not result.in_range:
		return result

	if ability.uses_attack_action:
		has_attacked = true

	var to_hit := roll_vs(attack_skill())
	result["to_hit"] = to_hit
	if not to_hit.success:
		ability_used.emit(self, target, result)
		return result

	result["hit"] = true

	var raw_damage: int = ability.roll_damage()
	var applied: int = max(raw_damage - target.damage_reduction, 0)
	result["raw_damage"] = raw_damage
	result["damage"] = applied

	target.take_damage(applied)

	ability_used.emit(self, target, result)
	return result


func take_damage(amount: int) -> void:
	if amount <= 0:
		return
	current_hp = max(current_hp - amount, 0)
	took_damage.emit(self, amount)
	if current_hp == 0:
		died.emit(self)
		_handle_death()


## Strips a dead unit out of every system that would otherwise keep
## treating it as a live participant, then frees the node (after
## death_cleanup_delay, if set). remove_from_group happens first and
## immediately — anything that queries the "units" group (CombatAI's
## targeting, drag-select) stops seeing this unit the instant it dies,
## regardless of how long the actual node sticks around for a death
## animation.
func _handle_death() -> void:
	remove_from_group("units")
	input_ray_pickable = false

	if is_selected:
		SelectionManager.deselect(self)
	set_box_hover(false)

	# Stop moving entirely — a corpse shouldn't keep trying to walk
	# anywhere. It's also already excluded from PathAvoidance's obstacle
	# gathering by the remove_from_group("units") call above, so other
	# units won't detour around it either (matches corpse_blocks_movement
	# below, which controls whether it still blocks via physical
	# collision).
	_moving = false
	velocity = Vector3.ZERO
	_current_path = PackedVector3Array()
	_path_index = 0
	set_physics_process(false)

	if not corpse_blocks_movement:
		collision_layer = 0
		collision_mask = 0

	if death_cleanup_delay > 0.0:
		get_tree().create_timer(death_cleanup_delay).timeout.connect(queue_free)
	else:
		queue_free()
