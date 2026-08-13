class_name Unit
extends CharacterBody3D

@export var strength: int = 10
@export var dexterity: int = 10
@export var intelligence: int = 10
@export var health: int = 10
@export var will: int = 10
@export var perception: int = 10

@export var maximum_hp: int = 10
@export var current_hp: int = 10
@export var maximum_fp: int = 10
@export var current_fp: int = 10

@export_group("Alignment")
## Two independent axes, each a plain signed integer — no enum, no
## string tag stored on the unit itself (DialogueChoice.alignment_name
## is authored per-CHOICE, this is the unit's own running total).
## Chaos-Neutral-Law on this one; see tendency below for Dark-Neutral-
## Light. Positive = Law, negative = Chaos, matching apply_alignment_tag.
@export var alignment: int = 0
## Dark-Neutral-Light. Positive = Light, negative = Dark.
@export var tendency: int = 0
## How far from 0 counts as "still neutral" on EITHER axis — kept wide
## relative to a single shift (see ALIGNMENT_SHIFT_AMOUNT) so leaving
## neutral takes a real pattern of consistent choices, not one line of
## dialogue. Tune freely; nothing else depends on the exact number.
const ALIGNMENT_NEUTRAL_THRESHOLD: int = 25
## Per-choice nudge applied by apply_alignment_tag — see DialogueChoice
## .resolve(), the only current caller.
const ALIGNMENT_SHIFT_AMOUNT: int = 10

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

## Skills this unit has actually trained live as real children here —
## never a slot for every skill that exists in the game, only the ones
## confirmed under this node. Private: nothing outside Unit should reach
## into this directly (see get_skills()/add_skill() below) — the
## original design's bug was exactly that, external code finding this by
## a hardcoded get_node("Skills") string path. Referencing Unit's own
## known child via $ here is the safe, ordinary case that pattern warns
## against, not a repeat of it.
@onready var _skills_container: Node = $Skills

## Off-canvas home for equipped Item nodes belonging to THIS unit while
## its party sheet isn't the one being shown — see get_equipped_items_home()
## and party_overview.gd's open_for(), which reparents equipped Items
## here (and back into an EquipSlot) on every unit switch, the same
## reparent-based idiom StashComponent/StashPanel already use. A Control
## parented under a 3D node still renders (Viewport-based, not
## CanvasItem-ancestor-based — see alignment_grid.gd/stash_component.gd's
## own note on this), so party_overview.gd is responsible for setting
## visible = false on anything reparented here and true again on the
## way back out.
@onready var _equipped_items_home: Node = $EquippedItems

@export_group("Movement")
@export var move: int = 5
## Real-time speed (world units/sec) while executing a move order. Distinct
## from `move`, which is the per-turn distance budget in combat.
@export var move_speed: float = 4.0
## This unit's rough collision radius — used for range calculations
## (see edge_distance_to and Ability.is_in_range: edge-to-edge, not
## center-to-center) and as the basis for avoidance clearance (see
## avoidance_margin below). Set to roughly match the actual collision
## shape.
@export var radius: float = 0.25
## Extra buffer added on top of radius for planning purposes only — the
## physical collision shape stays exactly radius, this just tells the
## planning simulation (see PathAvoidance.simulate_path) to route with a
## bit more separation than the bare minimum. Zero slack means any small
## imprecision eats directly into actual contact instead of a buffer
## absorbing it.
@export var avoidance_margin: float = 0.15
## This unit's body height for navigation purposes — NavigationGrid checks
## clearance all the way from this unit's reference cell up through
## height above it, not just the single cell the reference point sits in,
## so pathing won't route a tall unit somewhere its feet fit but its head
## doesn't (a low archway, or a flying unit tucked just under a platform).
## Matches the actual CapsuleShape3D's height in unit.tscn (unit.tscn
## only overrides radius, so the capsule sits at Godot's own default
## height of 2.0) — kept as a separate export rather than read off the
## collision shape directly since NavigationGrid only duck-types simple
## float properties off the Unit script, not scene-tree collision nodes.
@export var height: float = 2.0
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
## The altitude a flying unit's NEXT move targets — read/written by
## set_flight_altitude() (Ctrl-drag input, see movement_indicator.gd),
## read by UnitMovement.move_to() to decide where the flight path's Y
## actually goes. Meaningless while not flying; GrantFlightEffect
## initializes it to the unit's actual height the moment flight is
## granted, so it's never stale/unset by the time anything reads it.
@export var flight_target_altitude: float = 0.0
## Vertical descent speed (m/s) for the eased Tween in land() — see that
## method. Duration is distance/vertical_speed, clamped to
## [min_land_duration, max_land_duration], so a landing reads as a
## constant-ish speed rather than a fixed time: a unit hovering a half
## meter up doesn't take as long to land as one dropping from the flight
## ceiling. Matches GrantFlightEffect's takeoff pacing in spirit (same
## curve, same "controlled by velocity" feel) — that one lives on the
## effect resource since takeoff always starts from a single ability;
## landing fires from multiple places (voluntary Land, or getting
## knocked out mid-air), so its tuning lives here on Unit instead, one
## shared value for every caller.
@export var vertical_speed: float = 6.0
## Floor on land()'s eased duration — keeps a near-zero-height landing
## from reading as an instant snap.
@export var min_land_duration: float = 0.15
## Ceiling on land()'s eased duration. Deliberately NOT derived from
## NavigationGrid.FLIGHT_CEILING_HEIGHT or any other flight-system
## constant — Unit shouldn't need to know about, or stay in sync with,
## that value. Set generously high (well above what
## vertical_speed × any realistic descent produces) so it never engages
## during ordinary flight and every normal landing reads as true
## constant velocity; it only exists as a hard backstop against a
## pathological case — e.g. the land() raycast finding ground deep in a
## chasm — so a freak long descent can't stall the animation forever.
@export var max_land_duration: float = 4.0

@export_group("Combat")
@export var damage_reduction: int = 0
## Units with a different faction than the acting unit are valid attack
## targets when clicked during that unit's turn; same-faction clicks still
## select as normal (see _on_input_event / is_hostile_to).
@export var faction: StringName = &"player"
## Abilities this unit currently has available. abilities[0] is used as
## the default (see default_ability) when nothing's explicitly armed via
## AbilityManager — that's what makes click-to-attack keep working before
## a hotbar exists to actually choose between multiple abilities.
@export var abilities: Array[Ability] = []
## Player-assignable "Custom" hotbar section — fixed-size, null = empty
## slot. A slot holds a REFERENCE to one of this unit's OTHER abilities
## (from either Ability.Category), never a copy and never removed from
## its home section — see hotbar_slot.gd's drag-and-drop, which hands
## over the Ability resource itself rather than moving anything. Resize
## this default (add/remove null entries) per-unit in the Inspector for
## a unit that should have more or fewer than 6 — ability_hotbar.gd
## reads custom_slots.size() rather than assuming 6.
@export var custom_slots: Array[Ability] = [null, null, null, null, null, null]
## Which unit summoned this one, or null if it wasn't summoned at all —
## set by SummonEffect.apply() at creation time (occasionally hand-set
## in the Inspector too, for a scripted encounter that wants a boss to
## start the fight with pre-placed minions). Exported like every other
## per-unit relationship on this class, not a separate composable
## "summon tag" — there's no behavioral variation to plug in here, just
## one optional reference, so a bare field matches this rather than
## inventing a new mechanism (see _handle_death's use of this: summons
## don't outlive their summoner).
@export var summoned_by: Unit = null

@export_group("Interaction")
## Right-click verbs this unit can ever offer — filtered down to
## whichever ones are ACTUALLY valid right now by get_interactions()
## below, same "authored data vs. currently-true" split
## AbilityTargeting/PrerequisiteRule already use elsewhere in this
## project (AttackInteraction only shows on a hostile target,
## TalkInteraction only on a non-hostile one, ExamineInteraction always).
##
## Defaulted here, in the script, rather than hand-copied onto each of
## main.tscn's unit instances — every unit gets the same baseline verbs
## (unlike abilities, which genuinely differ per unit and so ARE authored
## per-instance), so a shared default means a newly placed unit can't
## forget to wire this up. A specific instance can still override it in
## the Inspector for something unusual (e.g. a unit with nothing to say).
@export var interactions: Array[InteractionOption] = [
	preload("res://interactions/attack.tres"),
	preload("res://interactions/talk.tres"),
	preload("res://interactions/examine.tres"),
]
## Root of this unit's conversation tree, or null if it has nothing
## authored yet — read by talk_interaction.gd, same per-unit-authored-
## Resource convention as abilities/interactions above (not a fixed list
## every unit gets automatically; most units will leave this unset).
@export var dialogue_root: DialogueNode = null

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
## Shown in the initiative/party portrait (see unit_portrait.gd) and
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

## Fires whenever visual_state changes — see that property's doc comment
## for why this exists and what owns it.
signal visual_state_changed(unit: Unit, state: VisualState)

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

## Owned and written by unit_animator.gd — NOT by any RefCounted
## component the way move_remaining/is_hovered are, since the animator
## is a scene-tree sibling node (wired via editor export), not something
## Unit creates in _ready(). Deliberately just two values, not one per
## situation (hit-while-standing, hit-while-down, casting, jumping...) —
## the STATE is "is this unit currently holding a status pose or not";
## WHICH clip/vfx/sfx plays for anything that happens on top of that is
## data on the StatusEffect resource itself (see posed_status and
## StatusEffect's Hit Reaction FX group), never a new hardcoded case.
##
## Exists on Unit, not just inside unit_animator.gd privately, so
## unit_vfx.gd/unit_sfx.gd (or anything else) can ask "is this unit
## currently posed" without independently reconstructing that tracking
## themselves — which is exactly how a real bug happened once already
## (see unit_animator.gd's VisualState doc comment): a unit hit while
## posed played its hit reaction and never returned to the pose,
## because the fallback that decided what to rest on didn't know a pose
## was being held at all. One authoritative value here, read by every
## reactive system, is what keeps that from happening again independently
## in each one.
enum VisualState { STANDING, POSED }

var visual_state: VisualState = VisualState.STANDING:
	set(value):
		if visual_state == value:
			return
		visual_state = value
		visual_state_changed.emit(self, value)

## Whichever StatusEffect is currently being visually held while
## visual_state == POSED — null otherwise. Set alongside visual_state,
## by the same owner (unit_animator.gd) — this is what lets a reactive
## system read StatusEffect.hit_reaction_vfx/hit_reaction_sfx for the
## CURRENTLY-held pose without needing its own copy of "which status,
## if any, is being held right now."
var posed_status: StatusEffect = null

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
var _stat_modifiers: UnitStatModifiers
var _equipment: UnitEquipment

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
	_stat_modifiers = UnitStatModifiers.new()
	_equipment = UnitEquipment.new(self)
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


func _on_mouse_entered() -> void:
	_selection.on_mouse_entered()


func _on_mouse_exited() -> void:
	_selection.on_mouse_exited()


## Left-clicking a unit while your own unit is both selected and the
## currently active one (PlayerInteractionState.get_active_unit() — the
## acting unit in combat, or the first selected unit out of combat) uses
## an ability against it instead of selecting it — whichever ability is
## currently armed via AbilityManager, or the active unit's
## default_ability() if nothing's explicitly armed (keeps click-to-attack
## working without an explicit hotbar pick, in or out of combat).
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
##
## Right-click has no handler here at all — ground_click_target.gd is the
## sole global right-click router (disarm-if-armed, else open a context
## menu for whatever's under the cursor via _get_hovered_interactable()),
## so every interactable (this unit included) only needs to implement
## get_interactions() below, not its own input_event wiring too.
func _on_input_event(_camera: Node, event: InputEvent, _position: Vector3, _normal: Vector3, _shape_idx: int) -> void:
	# Same reasoning as ground_click_target.gd's own guard — a live
	# conversation owns the screen, clicking a unit underneath it
	# shouldn't attack/select it.
	if DialogueManager.is_active():
		return

	if not event.is_action_pressed("left_click"):
		return

	var acting_unit: Unit = PlayerInteractionState.get_active_unit()
	if acting_unit and acting_unit != self and acting_unit in SelectionManager.selected_units:
		var ability: Ability = AbilityManager.armed_ability if AbilityManager.armed_ability else acting_unit.default_ability()
		var wants_ally: bool = ability and ability.targeting and ability.targeting.requires_ally_target()
		var hostile: bool = acting_unit.is_hostile_to(self)
		if ability and (wants_ally != hostile):
			acting_unit.use_ability(ability, self)
			return

	var additive: bool = Input.is_action_pressed("select_additive")
	SelectionManager.select(self, additive)


## Right-click verb list, filtered to whichever of `interactions` are
## actually valid for actor against this unit right now — see
## InteractionOption.is_available. Called fresh every time the context
## menu opens (InteractionMenu.open_for), never cached.
func get_interactions(actor: Unit) -> Array[InteractionOption]:
	var result: Array[InteractionOption] = []
	for option in interactions:
		if option.is_available(actor, self):
			result.append(option)
	return result


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
## avoidance_margin/arrival_tolerance/stuck_timeout all stay directly on
## Unit rather than moving into the component. Callers don't need to
## exclude other units from avoidance anymore (there used to be an
## extra_avoidance_exclusions param for this) — the shared grid already
## marks every OTHER unit's footprint occupied by the time this runs (see
## NavigationGrid), and a destination near another unit simply routes to
## the nearest valid cell outside that unit's own footprint, which is
## what you want when approaching a target to attack it too.
func move_to(destination: Vector3) -> bool:
	return _movement.move_to(destination)


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


## Whether any active status currently grants this unit flight — see
## FlightBehavior/StatusManager.grants_flight(). UnitMovement.move_to()
## checks this to switch NavigationGrid.find_path()'s traversal rule from
## grounded (requires solid support underfoot) to flying (requires only
## being within the flight altitude envelope).
func is_flying() -> bool:
	return _status_manager.grants_flight()


## Sets flight_target_altitude directly, clamped to the valid flight
## envelope (see NavigationGrid.FLIGHT_MIN_ALTITUDE/FLIGHT_CEILING_HEIGHT)
## — called every frame from movement_indicator.gd's Ctrl-drag altitude
## control while this unit is the active, flying unit. Doesn't move the
## unit itself; only changes where its NEXT move_to() call will aim for.
func set_flight_altitude(altitude: float) -> void:
	flight_target_altitude = clamp(
		altitude,
		NavigationGrid.FLIGHT_MIN_ALTITUDE,
		NavigationGrid.FLIGHT_CEILING_HEIGHT
	)


## Forces this unit out of the air by removing every status currently
## granting it flight — used by IncapacitateBehavior so Sleep/Stun/
## Paralysis (anything built from it) knocks a flying unit down instead
## of leaving it hovering, unreachable, indefinitely for the rest of the
## status's duration. Deliberately doesn't call land() itself: removing
## the status is what fires ForceLandOnExpireBehavior.on_remove() (see
## statuses/flying.tres), the exact same landing logic a voluntary Land
## cast already goes through — one landing implementation, not two.
func ground_if_flying() -> void:
	for effect in _status_manager.flight_granting_effects():
		remove_status(effect)


## Descends this unit straight down onto whatever solid ground is
## directly below it, eased via Tween over a duration scaled by descent
## distance (see vertical_speed above) rather than a fixed time or an
## instant teleport (same TRANS_SINE/EASE_IN_OUT curve GrantFlightEffect
## uses for takeoff, so the two read as one consistent motion language)
## — called by ForceLandOnExpireBehavior the instant the Flying status is
## removed, whether that's a voluntary Land ability, the status's own
## duration running out, or IncapacitateBehavior force-removing it
## (Sleep/Stun/Paralysis on a flying unit). Deliberately the same landing
## regardless of caller — a graceful descent even when knocked out isn't
## fully realistic, but a single shared animation is worth more than
## relitigating tone per call site; revisit only with a concrete reason.
##
## A physics raycast rather than a NavigationGrid lookup: landing needs
## the true physical surface directly beneath this exact XZ position, not
## the nearest VALID cell (which could be meters off to the side) — a
## raycast is the right tool for "what's physically underneath me,"
## independent of grid resolution. Excludes every unit (not just self)
## from the raycast since ground and unit collision share collision_layer
## 1 by default in this project (see indicator_base.gd) — otherwise
## landing directly above an ally would land ON them instead of the
## ground beneath them.
func land() -> void:
	var exclude: Array[RID] = []
	for node in get_tree().get_nodes_in_group("units"):
		if node is Unit:
			exclude.append(node.get_rid())

	var space_state := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(global_position, global_position + Vector3.DOWN * 200.0)
	query.exclude = exclude
	var result: Dictionary = space_state.intersect_ray(query)

	if result.is_empty():
		# Flew out over a genuine void with nothing below — left exactly
		# where it is rather than guessing at a fallback position. A
		# known limitation (see this project's flight-design notes), not
		# a crash.
		SystemLog.print("%s has nowhere to land." % LogFormat.unit_name(self))
		return

	var descent: float = absf(global_position.y - result.position.y)
	var duration: float = clampf(descent / vertical_speed, min_land_duration, max_land_duration)

	begin_busy()
	var tween: Tween = create_tween()
	tween.set_trans(Tween.TRANS_SINE)
	tween.set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(self, "global_position:y", result.position.y, duration)
	tween.finished.connect(end_busy)
	SystemLog.print("%s lands." % LogFormat.unit_name(self))


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


## String-keyed so skill_system's DefaultRule/AttributePrerequisite (and
## anything else that names an attribute generically off a .tres) can
## resolve one without needing a match/if-chain of their own — same role
## as Character.get_attribute_value() in the gurps project this was
## ported from. Kept as a thin alias over get_stat() rather than renamed,
## so skill_system's existing callers need no changes.
func get_attribute_value(attribute_name: String) -> int:
	return get_stat(attribute_name)


## Effective value of a named stat — base field plus every currently
## active modifier (status effects today, equipment later once it grants
## any — see stat_modifier() below). The base fields themselves
## (strength, damage_reduction, ...) are never mutated by a modifier
## anymore; each read recomputes fresh, the same "sum every active
## source at query time" shape incoming_attack_to_hit_modifier already
## uses for to-hit instead of mutating anything.
func get_stat(stat_name: String) -> int:
	var base: int = 0
	match stat_name:
		"ST": base = strength
		"DX": base = dexterity
		"IQ": base = intelligence
		"HT": base = health
		"Will": base = will
		"Per": base = perception
		"DR": base = damage_reduction
		"Move": base = move
	return base + stat_modifier(stat_name)


## Writes a new BASE value for a named stat — the get_stat() match in
## reverse. For the rare caller that needs to set a stat outright rather
## than modify it temporarily (SummonEffect's move_override, e.g.), not
## a general-purpose setter for modifiers — those go through
## StatModifierBehavior/stat_modifier() instead.
func set_stat_base(stat_name: String, value: int) -> void:
	match stat_name:
		"ST": strength = value
		"DX": dexterity = value
		"IQ": intelligence = value
		"HT": health = value
		"Will": will = value
		"Per": perception = value
		"DR": damage_reduction = value
		"Move": move = value


## Sum of every currently registered modifier to a named stat — see
## UnitStatModifiers. Source-agnostic: StatusManager is the only
## registrant today (see register_stat_modifier below), but this has no
## idea statuses exist, only that something registered a modifier.
func stat_modifier(stat_name: String) -> int:
	return _stat_modifiers.stat_modifier(stat_name)


## Registers/unregisters one StatModifierBehavior with this unit's stat
## system — called by StatusManager.apply()/remove() today, and by
## whatever wires up equipment later, each on its own equivalent of
## apply/remove. source is a display label for attribution (e.g. a
## StatusEffect's status_name) — see ActiveStatModifier for why it's
## passed in per-registration rather than read off the (shared) modifier
## resource. Thin forwarders rather than exposing _stat_modifiers
## directly, same reasoning as every other composed-helper forward on
## this class.
func register_stat_modifier(modifier: StatModifierBehavior, source: String) -> void:
	_stat_modifiers.register_modifier(modifier, source)


func unregister_stat_modifier(modifier: StatModifierBehavior) -> void:
	_stat_modifiers.unregister_modifier(modifier)


## Every currently active contribution to a named stat, with its source —
## see UnitStatModifiers.stat_modifier_sources.
func stat_modifier_sources(stat_name: String) -> Array[ActiveStatModifier]:
	return _stat_modifiers.stat_modifier_sources(stat_name)


## Which Item (if any) this unit currently has equipped in the named
## EquipSlot — see UnitEquipment.
func get_equipped_item(slot_key: String) -> Item:
	return _equipment.get_item(slot_key)


func equip_item(slot_key: String, item: Item) -> void:
	_equipment.equip(slot_key, item)


func unequip_item(slot_key: String) -> Item:
	return _equipment.unequip(slot_key)


## Where an equipped Item node lives while this unit's sheet isn't the
## one currently open — see _equipped_items_home's own header.
func get_equipped_items_home() -> Node:
	return _equipped_items_home


## -1/0/1 for Chaos/Neutral/Law — the only thing anything outside Unit
## should ever need to know to categorize the raw alignment int (see
## ALIGNMENT_NEUTRAL_THRESHOLD). party_overview.gd's 9-cell grid is the
## first caller; nothing about the category logic is UI-specific, so it
## lives here rather than being re-derived in the UI layer.
func alignment_category() -> int:
	if alignment < -ALIGNMENT_NEUTRAL_THRESHOLD:
		return -1
	if alignment > ALIGNMENT_NEUTRAL_THRESHOLD:
		return 1
	return 0


## -1/0/1 for Dark/Neutral/Light — same reasoning as alignment_category.
func tendency_category() -> int:
	if tendency < -ALIGNMENT_NEUTRAL_THRESHOLD:
		return -1
	if tendency > ALIGNMENT_NEUTRAL_THRESHOLD:
		return 1
	return 0


## Applies one authored DialogueChoice.alignment_name tag to this unit's
## running totals — the ONLY place that knows "Chaotic" means alignment
## goes down rather than up, so a dialogue choice never needs to touch
## these fields directly. Unrecognized tags (including "", and the old
## Good/Evil vocabulary this project no longer uses) are silently
## no-ops rather than errors — an author leaving alignment_name blank on
## a choice is the normal, common case, not a mistake.
func apply_alignment_tag(tag: String) -> void:
	match tag:
		"Lawful": alignment += ALIGNMENT_SHIFT_AMOUNT
		"Chaotic": alignment -= ALIGNMENT_SHIFT_AMOUNT
		"Light": tendency += ALIGNMENT_SHIFT_AMOUNT
		"Dark": tendency -= ALIGNMENT_SHIFT_AMOUNT


## Every SkillInstance this unit has actually trained. The one place
## that reads _skills_container's actual children — SkillCalculator and
## anything else that needs a unit's skills calls this instead of ever
## touching the container directly, so the internal "skills are children
## of a Skills node" detail stays exactly that, internal.
func get_skills() -> Array[SkillInstance]:
	var result: Array[SkillInstance] = []
	for child in _skills_container.get_children():
		if child is SkillInstance:
			result.append(child)
	return result


## Learns a new skill (or moves an already-existing SkillInstance under
## this unit, e.g. when reassigning one at runtime) — reparent rather
## than add_child so passing an instance that already belongs to another
## unit does the right thing instead of erroring.
func add_skill(skill_instance: SkillInstance) -> void:
	skill_instance.reparent(_skills_container)


func distance_to(other: Unit) -> float:
	return global_position.distance_to(other.global_position)


## Center-to-center distance minus both units' radii — how far apart their
## actual bodies are, not their positions. This is what any range check
## (melee or ranged — see Ability.is_in_range) should be measured-
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


## Removes this unit from combat and frees it without going through
## damage — used when a summon's tracking status expires (see
## DespawnOnExpireBehavior). Reuses the exact same cleanup as a real
## death (_handle_death + the died signal) since every system that needs
## to know "this unit is gone" — CombatManager's turn_order pruning,
## initiative UI, the animator/VFX death reactions — already listens to
## died; a summon leaving combat this way is exactly that, just not
## caused by damage, so it gets its own log line instead of "has died".
## current_hp is zeroed (not left as whatever it was) so is_alive()
## agrees with everything else — CombatManager._advance_turn(), notably,
## which decides whether to keep giving this unit turns purely off
## is_alive(), same as an ordinary death; without this, a summon
## expiring on its OWN turn would still get turn_started emitted for it
## a moment before its queue_free() actually takes effect.
func expire() -> void:
	SystemLog.print("%s fades away." % LogFormat.unit_name(self))
	current_hp = 0
	_handle_death()
	died.emit(self)


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

	if corpse_blocks_movement:
		# remove_from_group("units") above means NavigationGrid.
		# update_occupancy will never see this unit via the normal "units"
		# group loop again — a separate group is what lets a corpse that's
		# meant to keep blocking movement still get marked occupied on the
		# grid (see that function), instead of silently becoming
		# pathable-through the instant it dies even though it still
		# physically collides.
		add_to_group("blocking_corpses")
	else:
		collision_layer = 0
		collision_mask = 0

	# Summoned dependents don't outlive their summoner — expire(), not a
	# raw queue_free(), so each one still goes through this exact same
	# cleanup path (occupancy update, corpse handling, its own died
	# signal) and can itself cascade to whatever IT summoned in turn.
	# Scans "units" rather than a maintained back-reference list — same
	# idiom every other "find related units" query in this project
	# already uses (combat_ai.gd's nearest-hostile search, the AoE
	# effects), and get_nodes_in_group returns a fresh snapshot array, so
	# a dependent's own expire() call removing ITSELF from "units"
	# mid-loop can't disturb this iteration.
	for node in get_tree().get_nodes_in_group("units"):
		var dependent := node as Unit
		if dependent and dependent.summoned_by == self:
			dependent.expire()

	if death_cleanup_delay > 0.0:
		get_tree().create_timer(death_cleanup_delay).timeout.connect(queue_free)
	else:
		queue_free()
