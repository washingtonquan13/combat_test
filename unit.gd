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

@export var reach: float = 1.0
@onready var thrust: Die = $Thrust
@onready var swing: Die = $Swing
@onready var damage: Die = $Damage

@export var move: int = 5
## Real-time speed (world units/sec) while executing a move order. Distinct
## from `move`, which is the per-turn distance budget in combat.
@export var move_speed: float = 4.0
## This unit's rough collision radius — used both for avoidance (how much
## berth other units give it) and for reach calculations (is_in_reach
## measures edge-to-edge distance, not center-to-center, so this matters
## for melee range too). Set to roughly match the actual collision shape.
@export var radius: float = 0.5
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

signal hover_started(unit: Unit)
signal hover_ended(unit: Unit)
signal selected(unit: Unit)
signal deselected(unit: Unit)

## result dict shape: { in_reach, hit, damage, to_hit, raw_damage }
signal attacked(attacker: Unit, target: Unit, result: Dictionary)
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
	nav_agent.radius = radius
	nav_agent.avoidance_enabled = true
	nav_agent.target_desired_distance = arrival_tolerance
	nav_agent.velocity_computed.connect(_on_velocity_computed)


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
## selected and the acting unit (CombatManager.current_unit) attacks it
## instead of selecting it. Every other click falls through to normal
## selection — which is a safe no-op for non-player units regardless,
## since SelectionManager itself refuses anything that isn't
## is_player_controlled(). Clicking an enemy outside of a valid attack
## context does nothing, exactly as intended.
func _on_input_event(_camera: Node, event: InputEvent, _position: Vector3, _normal: Vector3, _shape_idx: int) -> void:
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return

	if CombatManager.in_combat:
		var acting_unit: Unit = CombatManager.current_unit
		if acting_unit and acting_unit != self and acting_unit.is_hostile_to(self) \
				and acting_unit in SelectionManager.selected_units:
			acting_unit.attack(self, acting_unit.swing)
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

	if nav_agent.is_navigation_finished():
		_finish_move()
		return

	# Last-resort safety net — see stuck_timeout's doc comment. With
	# avoidance handling the common case (units blocking each other),
	# this should mostly only catch genuinely unreachable destinations.
	if global_position.distance_to(_last_progress_position) < 0.05:
		_stuck_timer += delta
		if _stuck_timer >= stuck_timeout:
			_finish_move()
			return
	else:
		_stuck_timer = 0.0
		_last_progress_position = global_position

	var next_point: Vector3 = nav_agent.get_next_path_position()
	var direction: Vector3 = next_point - global_position
	direction.y = 0.0
	direction = direction.normalized()

	# Hand the desired velocity to the avoidance simulation rather than
	# moving immediately — other avoidance-enabled units (moving or idle)
	# get factored in, and velocity_computed reports back the adjusted
	# "safe" velocity, which is what actually drives move_and_slide().
	nav_agent.velocity = direction * move_speed


func _on_velocity_computed(safe_velocity: Vector3) -> void:
	if not _moving:
		return
	velocity = safe_velocity
	move_and_slide()


## Orders this unit toward destination along the nav mesh. Out of combat
## this always succeeds and walks the full distance. In combat: only
## CombatManager.current_unit may move at all. If destination is farther
## than move_remaining, the unit still moves — it just stops once its
## budget runs out (clamped along the straight line to destination, see
## _clamp_to_move_budget) instead of the whole order being rejected.
## Clicking past your movement range and having the unit walk as far as
## it can is normal CRPG UX; silently refusing the click is not. Returns
## false only if the order is rejected outright: already moving, not your
## turn, or no budget left at all.
func move_to(destination: Vector3) -> bool:
	if _moving:
		return false

	if CombatManager.in_combat:
		if CombatManager.current_unit != self:
			return false
		if not has_move_remaining():
			return false
		destination = _clamp_to_move_budget(destination)

	_move_start_position = global_position
	_stuck_timer = 0.0
	_last_progress_position = global_position
	nav_agent.target_position = destination
	_moving = true
	movement_started.emit(self)
	return true


## Clamps destination to the farthest point reachable with move_remaining,
## along the straight line toward it in the ground plane — same
## straight-line approximation used everywhere else here (is_in_reach,
## can_move), not an actual path-length calculation. Distance is measured
## in XZ only, matching how _physics_process actually drives movement
## (its direction vector also has Y zeroed): the unit's own origin rarely
## sits exactly at ground level, so a 3D distance here would burn part of
## the move budget on a vertical offset that covers no real ground
## distance, landing the clamped point short of where the budget should
## actually reach.
func _clamp_to_move_budget(destination: Vector3) -> Vector3:
	var to_dest: Vector3 = destination - global_position
	to_dest.y = 0.0
	var distance: float = to_dest.length()
	if distance <= move_remaining or distance <= 0.001:
		return destination
	var clamped: Vector3 = global_position + (to_dest / distance) * move_remaining
	clamped.y = destination.y
	return clamped


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
	nav_agent.velocity = Vector3.ZERO
	if CombatManager.in_combat:
		# Beeline distance from where the move started to where it ended —
		# not the length of the path actually walked. Avoidance can take a
		# winding route around other units, but since only this net
		# displacement is charged, that detour costs nothing extra against
		# move_remaining. (This isn't a special case for avoidance — it's
		# just what this line always did; it's worth calling out now that
		# detours are an expected, common thing.)
		var traveled: float = _move_start_position.distance_to(global_position)
		spend_move(traveled)
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
## actual bodies are, not their positions. This is what reach should be
## measured against; two units can be "touching" while still having
## meaningfully distant global_positions once you account for size.
func edge_distance_to(other: Unit) -> float:
	return max(distance_to(other) - radius - other.radius, 0.0)


func is_in_reach(target: Unit) -> bool:
	return edge_distance_to(target) <= reach


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


## Placeholder melee skill — just DX for now. Swap in a real skill lookup
## later (weapon skill, etc.) without touching attack()'s call site.
func attack_skill() -> int:
	return dexterity


## Resolves one melee attack against target using weapon_die (pass in
## self.thrust or self.swing). No defense roll — DR is the only mitigation.
## One attack per turn (see has_attacked/reset_turn_actions) — a miss still
## spends it, same as the swing itself being the spent action, not the hit.
## Returns a result dict for logging/UI:
## { in_reach, already_attacked, hit, damage, to_hit, raw_damage }
func attack(target: Unit, weapon_die: Die) -> Dictionary:
	var result := {
		"attacker": self,
		"target": target,
		"in_reach": is_in_reach(target),
		"already_attacked": has_attacked,
		"hit": false,
		"damage": 0,
	}

	if has_attacked:
		return result

	if not result.in_reach:
		return result

	has_attacked = true

	var to_hit := roll_vs(attack_skill())
	result["to_hit"] = to_hit
	if not to_hit.success:
		attacked.emit(self, target, result)
		return result

	result["hit"] = true

	var raw_damage: int = weapon_die.roll()
	var applied: int = max(raw_damage - target.damage_reduction, 0)
	result["raw_damage"] = raw_damage
	result["damage"] = applied

	target.take_damage(applied)

	attacked.emit(self, target, result)
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

	# Stop participating in pathfinding/avoidance entirely — a corpse
	# shouldn't keep steering other units around it via RVO predictions,
	# and shouldn't itself keep trying to move.
	_moving = false
	velocity = Vector3.ZERO
	nav_agent.velocity = Vector3.ZERO
	nav_agent.avoidance_enabled = false
	set_physics_process(false)

	if not corpse_blocks_movement:
		collision_layer = 0
		collision_mask = 0

	if death_cleanup_delay > 0.0:
		get_tree().create_timer(death_cleanup_delay).timeout.connect(queue_free)
	else:
		queue_free()
