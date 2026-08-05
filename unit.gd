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
## How quickly this unit turns to face a new direction — used for
## following the movement path and for tracking an aimed target while an
## ability is armed (see face_direction/face_point). Higher = snappier,
## lower = more of a visible turn lag.
@export var rotation_speed: float = 10.0
## Some imported character rigs face a different default direction than
## Godot's own forward convention (-Z) — if the character visibly faces
## sideways or backwards relative to where it's actually moving/aiming,
## adjust this rather than the rotation math itself.
@export var facing_offset_degrees: float = 0.0
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
## Optional full-body outline — a SEPARATE MeshInstance3D sharing the
## same mesh and skeleton as the character model, with the outline.gdshader
## material applied (see that file's header for the technique). Distinct
## from highlight_mesh (that one's a flat ring at the feet; this one
## traces the actual animated silhouette) — safe to leave unassigned,
## same as highlight_mesh.
@export var outline_mesh: MeshInstance3D
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

## Fires the INSTANT an ability use is confirmed to happen (past all
## rejection checks — busy, already-acted, out of range), BEFORE to-hit
## is even rolled. This is what animation/VFX should react to for
## STARTING to play (a swing animation, a projectile launching) — they
## shouldn't wait for the final outcome, since a projectile needs to
## fly before anyone knows whether it'll be ruled a hit. Distinct from
## ability_used (below), which still carries the final result but may
## now fire meaningfully later — see waits_for_impact.
signal ability_use_started(attacker: Unit, target, ability: Ability)

## result dict shape: { in_range, already_acted, hit, damage, to_hit,
## effects, ability }. target is typed loosely (not Unit) since some
## abilities target a point instead of a unit — see GroundPointTargeting.
signal ability_used(attacker: Unit, target, result: Dictionary)
signal took_damage(unit: Unit, amount: int)
signal died(unit: Unit)

## Fired by an attack animation's Call Method Track (at the frame a
## weapon actually connects) or a VFX sequence's ImpactSignalStep
## (typically right after a projectile arrives) — the signal
## UnitCombat.use_ability() waits on before applying an ability's
## effects, when that ability has waits_for_impact set. See
## notify_impact() below, which is what animation tracks/VFX steps
## should actually call.
signal impact_triggered()

## Relayed from _status_manager (see status_manager.gd) — same
## relay-not-replace convention as the selection signals below. Consumed
## by unit_vfx.gd/unit_sfx.gd to play StatusEffect's apply/tick/remove
## VFX/SFX; nothing about Unit itself knows what those look or sound like.
signal status_applied(unit: Unit, effect: StatusEffect)
signal status_removed(unit: Unit, effect: StatusEffect)
signal status_ticked(unit: Unit, effect: StatusEffect)

signal movement_started(unit: Unit)
signal movement_finished(unit: Unit)
## Fired the instant this unit has nothing left in flight — no move in
## progress, no async ability effect (e.g. Jump's arc animation) still
## running. This is what CombatManager waits on before actually ending a
## turn that was requested while the unit was still mid-action, instead
## of either cutting the action off or silently dropping the request.
signal became_idle()

## is_hovered/is_selected forward to _selection (see UnitSelection) —
## same computed-property pattern as move_remaining/has_attacked
## forwarding to _action_state, safe here for the same reason: neither
## is @export, so nothing needs to read them before _selection exists.
var is_hovered: bool:
	get: return _selection.is_hovered
var is_selected: bool:
	get: return _selection.is_selected

## --- Turn action budget (combat) ---
## Both properties forward to _action_state (see UnitActionState) —
## every existing reader/writer of unit.move_remaining/unit.has_attacked
## keeps working completely unchanged; only the storage moved.
var move_remaining: float:
	get: return _action_state.move_remaining
	set(value): _action_state.move_remaining = value

var has_attacked: bool:
	get: return _action_state.has_attacked
	set(value): _action_state.has_attacked = value

var _action_state: UnitActionState
var _facing: UnitFacing
var _selection: UnitSelection
var _movement: UnitMovement
var _combat: UnitCombat

## Owns this unit's active status effects (Bleeding, Sleep, Prone, ...) —
## see status_manager.gd. Unit exposes the small forwarding API below
## (apply_status/remove_status/etc.) rather than external code reaching
## into this directly.
var _status_manager: StatusManager


func _ready() -> void:
	_status_manager = StatusManager.new(self)
	_action_state = UnitActionState.new(self)
	_facing = UnitFacing.new(self)
	_selection = UnitSelection.new(self)
	_movement = UnitMovement.new(self)
	_combat = UnitCombat.new(self)
	# Relayed rather than replaced — external code (CombatManager's
	# end_turn/delay_turn deferral, notably) connects to unit.became_idle
	# directly and must keep working unchanged; the signal's actual
	# source of truth is now UnitActionState, but nothing outside Unit
	# needs to know that. Same reasoning for the four selection signals
	# below, relayed from UnitSelection.
	_action_state.became_idle.connect(func(): became_idle.emit())
	_selection.hover_started.connect(func(): hover_started.emit(self))
	_selection.hover_ended.connect(func(): hover_ended.emit(self))
	_selection.selected.connect(func(): selected.emit(self))
	_selection.deselected.connect(func(): deselected.emit(self))
	_status_manager.status_applied.connect(func(effect, _active): status_applied.emit(self, effect))
	_status_manager.status_removed.connect(func(effect): status_removed.emit(self, effect))
	_status_manager.status_ticked.connect(func(effect, _active): status_ticked.emit(self, effect))
	# CollisionObject3D (CharacterBody3D's base) already provides
	# mouse_entered/mouse_exited/input_event signals once this is on and
	# Project Settings > Physics > Common > Enable Object Picking is on
	# (it is by default).
	add_to_group("units")

	input_ray_pickable = true
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)
	input_event.connect(_on_input_event)

	_selection.setup()
	_movement.setup_avoidance()


func _on_mouse_entered() -> void:
	_selection.on_mouse_entered()


func _on_mouse_exited() -> void:
	_selection.on_mouse_exited()


## During combat, left-clicking a unit while your own unit is both
## selected and the acting unit (CombatManager.current_unit) uses an
## ability against it instead of selecting it — whichever ability is
## currently armed via AbilityManager, or the acting unit's
## default_ability() if nothing's explicitly armed (keeps click-to-attack
## working before a hotbar exists to choose between abilities).
##
## Which clicks count depends on that ability's own targeting: an
## ordinary (non-ally) ability only fires on a HOSTILE click, same as
## always; one with AbilityTargeting.requires_ally set (a heal, a buff)
## only fires on a click on the SAME faction instead — see
## AbilityTargeting.requires_ally_target's doc comment for why this is a
## flag there rather than a separate targeting subclass. Resolving
## `ability` before checking hostility (rather than after, like before
## this) is what makes that possible — the routing decision now depends
## on which ability would actually be used, not a fixed rule.
##
## Every other click falls through to normal selection — which is a safe
## no-op for non-player units regardless, since SelectionManager itself
## refuses anything that isn't is_player_controlled().
func _on_input_event(_camera: Node, event: InputEvent, _position: Vector3, _normal: Vector3, _shape_idx: int) -> void:
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return

	if CombatManager.in_combat:
		var acting_unit: Unit = CombatManager.current_unit
		if acting_unit and acting_unit != self and acting_unit in SelectionManager.selected_units:
			var ability: Ability = AbilityManager.armed_ability if AbilityManager.armed_ability else acting_unit.default_ability()
			var wants_ally: bool = ability and ability.targeting and ability.targeting.requires_ally_target()
			var hostile: bool = acting_unit.is_hostile_to(self)
			if ability and (wants_ally != hostile):
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
	_selection.set_selected(value)


## Called by a drag-select box while it's overlapping this unit, purely as
## a visual preview — does not touch is_selected or SelectionManager.
func set_box_hover(value: bool) -> void:
	_selection.set_box_hover(value)


func _physics_process(delta: float) -> void:
	_movement.physics_process(delta)


## Delegates to UnitFacing — see that file for why the exports
## (rotation_speed, facing_offset_degrees) stay directly on Unit while
## only the methods that use them moved into the component. Shared by
## movement-follow-path (below) and aim-while-armed tracking (see the
## standalone aim-facing script) — a single rotation implementation
## everything calls into, rather than duplicating the yaw math per
## caller.
func face_direction(direction: Vector3, delta: float) -> void:
	_facing.face_direction(direction, delta)


func face_point(point: Vector3, delta: float) -> void:
	_facing.face_point(point, delta)


## Instantly snaps to face a direction, no smoothing — used where a
## gradual turn would look wrong, e.g. facing your target the instant an
## attack resolves rather than still turning mid-swing (see use_ability).
func snap_face_direction(direction: Vector3) -> void:
	_facing.snap_face_direction(direction)


func snap_face_point(point: Vector3) -> void:
	_facing.snap_face_point(point)


## Delegates to UnitMovement — see that file for the deterministic
## plan-then-execute rationale in full, and for why move_speed/radius/
## avoidance_margin/arrival_tolerance/stuck_timeout/nav_agent all stay
## directly on Unit rather than moving into the component.
func move_to(destination: Vector3, extra_avoidance_exclusions: Array = []) -> bool:
	return _movement.move_to(destination, extra_avoidance_exclusions)


## Cancels the current move order in place, still spending whatever
## distance was actually covered (combat only).
func stop_moving() -> void:
	_movement.stop_moving()


func is_moving() -> bool:
	return _movement.is_moving()


## Whether this unit has anything currently in flight — movement, or any
## async ability effect that's bracketed itself with begin_busy(). This
## is what CombatManager checks before ending a turn, and what move_to/
## use_ability check before starting something new (so a jump animation
## and a move order can't both be running at once, or so a second
## ability can't fire mid-way through the first one's async effect).
func is_busy() -> bool:
	return _action_state.is_busy()


## Call when starting an async action (an ability's animation, etc.) that
## CombatManager should wait for before letting the turn end. Must be
## paired with a later end_busy() call once that action actually finishes.
func begin_busy() -> void:
	_action_state.begin_busy()


func end_busy() -> void:
	_action_state.end_busy()


## Called by UnitMovement whenever movement stops — is_busy()'s answer
## may have changed as a result (is_moving() just flipped to false), but
## UnitActionState has no way to learn that on its own (is_moving() is
## polled, not pushed), so this explicitly tells it to re-check.
## Deliberately routed through Unit rather than UnitMovement reaching
## into _action_state directly — components talk to their owner, never
## to each other, keeping the composition pattern consistent regardless
## of which two subsystems happen to need to coordinate.
func notify_movement_idle_check() -> void:
	_action_state.check_idle()


## --- Combat ---

## Called by CombatManager when this unit's turn begins. Refills the move
## budget from the `move` stat and clears the attack flag.
func reset_turn_actions() -> void:
	_action_state.reset_turn_actions(float(move))


## --- Status effects — thin forwarding API over _status_manager, see
## status_manager.gd for the actual tracking/dispatch logic. ---

func apply_status(effect: StatusEffect) -> void:
	_status_manager.apply(effect)


func remove_status(effect: StatusEffect) -> void:
	_status_manager.remove(effect)


func has_status(effect: StatusEffect) -> bool:
	return _status_manager.has(effect)


## Called by CombatManager right after reset_turn_actions() each time
## this unit's turn starts — fires every active status's on_turn_start
## (damage-over-time ticks, etc.) and ticks duration down.
func tick_statuses() -> void:
	_status_manager.tick_turn_start()


## Whether any active status prevents this unit from acting at all this
## turn (Sleep, Stun, ...) — checked directly by move_to()/use_ability(),
## not just advisory.
func status_prevents_turn() -> bool:
	return _status_manager.prevents_turn()


## Whether this unit is currently free to take a NEW action at all — not
## already busy with something in flight, and not prevented by an active
## status effect. This is the single thing move_to()/use_ability() check
## before doing anything, and the same thing
## PlayerInteractionState.get_active_unit() delegates to for its own
## unit-intrinsic half of "can the player currently act."
##
## Deliberately does NOT know about whose turn it is, who's
## player-controlled, or anything about combat/UI state — those are
## PlayerInteractionState's job, layered on TOP of this, not folded into
## it. An AI unit's own move_to()/use_ability() calls must never be
## blocked by "is this the player's currently active unit" — that
## question doesn't even apply to them — so this predicate only ever
## reasons about the unit itself.
func can_act() -> bool:
	return _action_state.can_act()


## Sum of every active status's to-hit modifier against an incoming
## attack, from this unit being the DEFENDER — see
## StatusBehavior.modify_incoming_attack_to_hit.
func incoming_attack_to_hit_modifier(attacker: Unit, ability: Ability) -> int:
	return _status_manager.incoming_attack_to_hit_modifier(attacker, ability)


## Sum of every active status's to-hit modifier to an OUTGOING attack,
## from this unit being the ATTACKER — see
## StatusBehavior.modify_outgoing_attack_to_hit.
func outgoing_attack_to_hit_modifier(target, ability: Ability) -> int:
	return _status_manager.outgoing_attack_to_hit_modifier(target, ability)


## Whether this unit could cover `distance` this turn without exceeding
## its move budget. Not used internally by move_to() anymore (which
## clamps rather than rejects) — kept as a query helper for anything that
## wants to check reachability before committing to an order.
func can_move(distance: float) -> bool:
	return _action_state.can_move(distance)


## Deducts distance already moved from the remaining budget this turn.
## Clamped so overshoot (e.g. rounding) can't push it negative.
func spend_move(distance: float) -> void:
	_action_state.spend_move(distance)


func has_move_remaining() -> bool:
	return _action_state.has_move_remaining()


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


## Delegates to UnitCombat — see that file for why the stat exports
## (strength, dexterity, current_hp, damage_reduction, abilities, ...)
## stay directly on Unit while the logic that resolves against them
## moved into the component.
func roll_vs(target_number: int) -> Dictionary:
	return _combat.roll_vs(target_number)


func attack_skill() -> int:
	return _combat.attack_skill()


func default_ability() -> Ability:
	return _combat.default_ability()


## Also a coroutine now, same as UnitCombat.use_ability() — it has to
## be, to correctly propagate that method's own return value rather
## than returning whatever a coroutine call yields when not awaited.
## Every existing caller (click routing, CombatAI) already calls this
## fire-and-forget, never touching the return value, so none of them
## needed to change — only this forwarding line, which specifically
## tries to hand that value back to ITS OWN caller, did.
func use_ability(ability: Ability, target) -> Dictionary:
	return await _combat.use_ability(ability, target)


func take_damage(amount: int) -> void:
	_combat.take_damage(amount)


## Called by UnitCombat's take_damage() — routed through Unit rather
## than UnitCombat reaching into _status_manager directly, same
## component-talks-to-owner-only rule as UnitMovement's
## notify_movement_idle_check().
func notify_status_of_damage(amount: int) -> void:
	_status_manager.notify_damage_taken(amount)


## Called by an attack animation's Call Method Track or a VFX sequence's
## ImpactSignalStep — see impact_triggered's doc comment for the full
## explanation. Public and directly callable (not routed through a
## component) since the callers here are external to Unit entirely
## (an AnimationPlayer track, a VfxStep), not another owned component.
func notify_impact() -> void:
	impact_triggered.emit()


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
	# collision). force_stop(), not stop_moving() — this is an immediate,
	# raw halt with no movement_finished signal and no budget spend; a
	# dying unit isn't "completing" a move, it's being silenced.
	_movement.force_stop()
	set_physics_process(false)

	if not corpse_blocks_movement:
		collision_layer = 0
		collision_mask = 0

	if death_cleanup_delay > 0.0:
		get_tree().create_timer(death_cleanup_delay).timeout.connect(queue_free)
	else:
		queue_free()
