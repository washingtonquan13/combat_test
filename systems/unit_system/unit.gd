class_name Unit
extends CharacterBody3D

@export_group("Identity")
## Which kind of unit this is — cascades display_name/portrait_texture/
## faction/the full stat block/damage_reduction/abilities/ai_behaviors/
## negotiable onto this instance the moment it's assigned, same "data
## resource separate from the presentation node" convention
## Item.gear_data already uses (see that file). Declared FIRST, ahead
## of every field it cascades into, because
## Godot deserializes a scene's properties in script-declaration order —
## the cascade has to fire before this instance's own explicit overrides
## (if any) are applied, so an override still wins. Not a hard lock: any
## cascaded field stays directly editable afterward, same as gear_data's
## icon/width/height. Also set on a live SUMMONED demon —
## SummonDemonEffect assigns owned_demon.species here so a summon goes
## through the same cascade as every other unit, then explicitly
## overrides faction/current_hp/current_fp afterward (a recruited demon
## fights for whoever fielded it, and re-summoning isn't free healing —
## see that file's own comment).
@export var definition: UnitDefinition = null:
	set(value):
		definition = value
		if definition:
			# A body is adopted in _enter_tree, so a definition arriving
			# after that point brings one nothing will ever read. It fails
			# SILENTLY — a bodiless unit still walks, fights and dies — so
			# it says so here instead. Assign the definition before
			# add_child(), the way debug_spawn_panel and PartyManager do.
			if _model_adopted and definition.model_scene and not Engine.is_editor_hint():
				push_warning(("Unit '%s': definition assigned after it entered the tree, " +
					"so its body was never adopted. Set definition before add_child().") % name)
			display_name = definition.display_name
			portrait_texture = definition.portrait_texture
			faction = definition.faction
			strength = definition.strength
			dexterity = definition.dexterity
			intelligence = definition.intelligence
			health = definition.health
			will = definition.will
			perception = definition.perception
			move = definition.move
			maximum_hp = definition.max_hp
			current_hp = definition.max_hp
			maximum_fp = definition.max_fp
			current_fp = definition.max_fp
			damage_reduction = definition.damage_reduction
			abilities = definition.abilities
			# Resolved, not raw: a species normally names an AiArchetype
			# and leaves ai_behaviors empty — see UnitDefinition.
			ai_behaviors = definition.resolved_ai_behaviors()
			ai_smartness = definition.resolved_ai_smartness()
			negotiable = definition.negotiable
			vision_cone_degrees = definition.vision_cone_degrees
			max_sight_range = definition.max_sight_range
			proximity_radius = definition.proximity_radius
			alignment = definition.alignment
			tendency = definition.tendency
			move_speed = definition.move_speed
			selected_color = definition.selected_color
			dialogue_options = definition.dialogue_options
## The name shown to the player — combat log, character sheet, dialogue,
## negotiation. Deliberately separate from this node's own scene-tree
## .name: that's Godot's own structural identifier (what a $NodePath
## resolves, what shows in the Scene dock), not a display string, and
## conflating the two meant renaming a unit for clarity, or one day
## localizing its name, had no way to happen without touching the scene
## tree itself. Left empty by default rather than required, so existing
## content keeps working unchanged — see get_display_name() below,
## which is what every player-facing consumer should call instead of
## reading .name (or this field) directly.
@export var display_name: String = ""

## Stable authored identity for area persistence — see AreaState. Empty
## means "not persistent," which is the correct default for most units
## (party members, summons, anything spawned rather than hand-placed);
## set this only on a hand-placed unit whose death should be remembered
## across a re-entry into its area (a goblinoid in test_arena, e.g.).
@export var persistent_id: StringName = &""

## State handed to this unit before its components existed, applied at
## the end of _ready(). WorldManager reconciles a world BEFORE it enters
## the tree (so a removed entity never enters at all), which is earlier
## than every component this state describes.
var _pending_state: Dictionary = {}

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

@export_group("Senses")
## Total width of this unit's forward vision, in degrees — 120 is a rough
## human field of view. Detection outside it fails regardless of distance
## or lighting (see DetectionManager), which is what makes approaching
## from behind mean something.
@export var vision_cone_degrees: float = 120.0
## Furthest this unit can notice anything at all. A hard cutoff before any
## rolling happens, so the detection scan can reject most pairs cheaply.
@export var max_sight_range: float = 18.0
## Close enough that facing stops mattering — someone at your shoulder is
## heard and felt, not seen. Without this a unit could stand directly
## behind another indefinitely, which reads as blindness rather than as
## stealth.
@export var proximity_radius: float = 2.5

@export_group("Alignment")
## Two independent axes, each a plain signed integer — no enum, no
## string tag stored on the unit itself (DialogueChoice.alignment_name
## is authored per-CHOICE, this is the unit's own running total).
## Chaos-Neutral-Law on this one; see tendency below for Dark-Neutral-
## Light. Positive = Law, negative = Chaos, matching apply_alignment_tag.
@export var alignment: int = 0
## Dark-Neutral-Light. Positive = Light, negative = Dark.
@export var tendency: int = 0

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
## physical collision shape stays exactly radius, this just tells
## NavigationGrid's own clearance queries (find_path/nearest_valid_point)
## to route with a bit more separation than the bare minimum. Zero slack
## means any small imprecision eats directly into actual contact instead
## of a buffer absorbing it.
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
## Ring radius (meters) a group move's followers get spread around the
## leader's own destination point (see ground_click_target.gd's
## free-roam move command) — larger than arrival_tolerance on purpose:
## that one means "reached an exact point," this means "landed
## somewhere in a loose cluster around the leader," not a precise spot.
@export var formation_spread_radius: float = 2.0
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
## The canonical "this is the player's own side" tag — named here so
## is_player_controlled() and anything else that cares "is this MY unit"
## (LogFormat's coloring, e.g.) reference one constant instead of
## independently retyping the literal &"player". NOT part of
## FactionRelations' relation matrix — that autoload treats "player" as
## an ordinary faction tag like any other; this is purely about who the
## player controls, a separate question from who's hostile to whom.
const PLAYER_FACTION: StringName = &"player"
## Abilities this unit currently has available. abilities[0] is used as
## the default (see default_ability) when nothing's explicitly armed via
## AbilityManager — that's what makes click-to-attack keep working before
## a hotbar exists to actually choose between multiple abilities.
@export var abilities: Array[Ability] = []
## Composable AI decision rules, tried in order — see AiBehavior. Empty
## (every unit today) falls back to CombatAI's original hardcoded
## nearest-hostile/default_ability baseline, so no existing content
## needs migrating.
@export var ai_behaviors: Array[AiBehavior] = []
## How many factors CombatAI's scorer weighs when choosing this
## unit's actions this turn -- see AiScorer's own header for the tier
## table. Cascades from UnitDefinition.ai_smartness (see that field);
## 2 (Tactical) is the default on both, so an unauthored unit is
## unaffected by this field's mere existence.
@export var ai_smartness: int = 2
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
## inventing a new mechanism (see UnitDeath.handle_death's use of this:
## summons don't outlive their summoner).
@export var summoned_by: Unit = null

@export_group("Demon")
## Which OwnedDemon roster entry this unit currently represents, or null
## for every unit that isn't a fielded demon (which is most of them) —
## set by SummonDemonEffect.apply() at summon time, same "bare optional
## reference, no behavioral variation to plug in" reasoning summoned_by
## above already uses for itself. This single nullable reference IS the
## "is this unit a demon" marker throughout the whole feature; nothing
## else checks a separate flag or scene type.
##
## A live Unit's own current_hp/current_fp are the source of truth WHILE
## it's summoned — this only gets synced back into owned_demon's own
## current_hp/current_fp at the moment it leaves the field (see
## DismissEffect), or read from when first fielding it (see
## SummonDemonEffect). UnitCombat.take_damage() checks this on a real
## death to permanently release the roster entry (see DemonRoster.release)
## — the one case where the live Unit's state is never synced back at all,
## since a demon reduced to 0 HP in actual combat is gone for good.
@export var owned_demon: OwnedDemon = null
## Whether right-click offers "Negotiate" on this unit at all (see
## NegotiateInteraction, and Unit.interactions' default array below,
## which includes it unconditionally — is_available() already double-
## gates on this flag plus combat/hostility, so a non-negotiable unit
## never shows the option regardless). Cascades from definition.negotiable
## as a default (see that field's setter) — a species that's naturally
## negotiable stops needing this retyped on every placement — but stays
## directly overridable per-instance afterward for a specific encounter
## that wants an exception, same "not a hard lock" spirit as every other
## cascaded field. False by default, same "off unless deliberately
## turned on" default corpse_blocks_movement/every other opt-in flag on
## this class uses.
@export var negotiable: bool = false

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
	preload("res://data/interactions/attack.tres"),
	preload("res://data/interactions/talk.tres"),
	preload("res://data/interactions/examine.tres"),
	preload("res://data/interactions/negotiate.tres"),
]
## Candidate entry points into this unit's conversation, evaluated in
## order — see DialogueRootOption and resolve_dialogue_root() below.
## Empty means nothing authored yet (most units will leave this unset),
## same per-unit-authored-Resource convention as abilities/interactions
## above. Was a single dialogue_root: DialogueNode field until an NPC
## needing more than one conversation over the life of the game (first
## meeting vs. quest-active vs. quest-resolved) exposed the limit — see
## dialogue_system_bg3_gap_analysis.md.
@export var dialogue_options: Array[DialogueRootOption] = []

@export_group("Death")
## Seconds between a unit's HP hitting 0 and its node actually being freed.
## 0 means immediate. Raise this if you want time for a death animation or
## ragdoll to play before the unit disappears — see UnitDeath.handle_death.
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

## Fired the moment an out-of-combat attack lands (hit OR miss — an
## attempt is still aggression, matching _maybe_trigger_combat's own
## reasoning) against a unit that was NOT hostile beforehand — the real
## provocation moment BG3 models as SetRelationTemporaryHostile.
## FactionRelations reacts to it directly (see
## UnitCombat._maybe_trigger_combat, the sole emitter today), but this is
## a real signal, not a private implementation detail: anything else that
## ever wants to react to "someone just started a fight with a former
## non-enemy" (a reputation system, a witness mechanic, a UI toast) has
## something to connect to. Never fires for a same-faction target — see
## FactionRelations.escalate_to_temporary_hostile's own no-op guard.
signal attacked_non_hostile_unit(attacker: Unit, target: Unit)

## result dict shape: { in_range, already_acted, hit, damage, to_hit,
## effects, ability }. target is typed loosely (not Unit) since some
## abilities target a point instead of a unit — see GroundPointTargeting.
signal ability_used(attacker: Unit, target, result: Dictionary)
signal took_damage(unit: Unit, amount: int)
signal healed(unit: Unit, amount: int)
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
## Whether THIS unit is the designated party leader/protagonist — see
## PartyManager, the sole owner of this designation. Computed, not
## stored, same reasoning is_selected/is_hovered forward rather than
## duplicate state: there's exactly one place this can ever be set.
var is_party_leader: bool:
	get: return PartyManager.is_leader(self)

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
var _alignment: UnitAlignment
var _skills: UnitSkills
var _death: UnitDeath
var _awareness: UnitAwareness

## Owns this unit's active status effects (Bleeding, Sleep, Prone, ...) —
## see status_manager.gd. Unit exposes the small forwarding API below
## (apply_status/remove_status/etc.) rather than external code reaching
## into this directly.
var _status_manager: StatusManager


## Mints an id for something that will CARRY it — a party member, whose
## record stores it and outlives every world they stand in.
##
## Deliberately not called for every unit that enters a world. An
## unauthored scene unit given an id here would look addressable and
## not be: rebuilding its world instantiates the scene again and mints a
## different one, so every AreaState entry written under the old id
## becomes garbage that can never match. An empty persistent_id already
## means "not persistent" throughout this project (see
## WorldManager._collect_persistent_nodes, which skips them), and that
## convention is the right one — an authored NPC persists because
## somebody gave it a name, not because it exists.
static func generate_persistent_id() -> StringName:
	_id_counter += 1
	# The counter alone restarts each session and would collide with an id
	# already saved; the suffix is what stops a fresh unit adopting somebody
	# else's history.
	return StringName("gen_%d_%04x" % [_id_counter, randi() % 65536])


static var _id_counter: int = 0


## Guards against re-adopting on every tree entry. Units are REPARENTED —
## WorldManager moves them between worlds — and _enter_tree fires again
## each time, which without this would free the body and build another.
var _model_adopted: bool = false


## Swaps in the body this unit's definition names, before any child of
## this scene has readied.
##
## _enter_tree is the only safe window, and it is safe for a precise
## reason: the scene's children already exist structurally, and none of
## them has run _ready yet. So UnitAnimator has not bound itself to the
## outgoing AnimationPlayer and UnitSelection has not cached the outgoing
## meshes — there is nothing to tear down, only something to replace.
## Same detached-window trick WorldManager.load_world() uses on a freshly
## instantiated world for the same kind of reason.
func _enter_tree() -> void:
	if _model_adopted:
		return
	_model_adopted = true
	if definition and definition.model_scene:
		_swap_model(definition.model_scene)
	# Bound either way. unit.tscn's own body is a CharacterModel too now,
	# so there is ONE path here rather than an authored case wired by
	# NodePath and a swapped case wired in code — which is what let the
	# two drift apart in the first place.
	_bind_model()


## The outgoing body takes its own parts with it.
##
## That is not tidiness. The outline mesh is SKINNED to the outgoing
## skeleton, so leaving it behind welds one creature's silhouette to
## another creature's bones, and the highlight ring is sized to a
## footprint that is about to stop existing. A body is all of its pieces
## or none of them.
func _swap_model(scene: PackedScene) -> void:
	var model: Node = scene.instantiate()
	if not (model is CharacterModel):
		push_warning("Unit '%s': model_scene '%s' is not a CharacterModel; keeping the authored body." % [
			name, scene.resource_path])
		model.queue_free()
		return

	for outgoing in [get_node_or_null("CharacterModel"), outline_mesh, highlight_mesh]:
		if is_instance_valid(outgoing):
			remove_child(outgoing)
			outgoing.queue_free()

	# Named, so anything still looking the old body up by name finds the
	# new one rather than nothing.
	model.name = "CharacterModel"
	add_child(model)


## Points this unit at the parts of whatever body it is now wearing.
##
## Runs for the authored body as well as a swapped one. Those meshes and
## the animator's player used to be wired by NodePath in unit.tscn,
## reaching across into the model subtree — which is exactly what could
## not survive a swap, and exactly what made the outline mesh a silhouette
## welded to one specific skeleton from outside it.
func _bind_model() -> void:
	var body := get_node_or_null("CharacterModel") as CharacterModel
	if body == null:
		return

	# Either may be null, and that is allowed — UnitSelection guards both.
	# A body that wants a selection ring or an outline declares one.
	outline_mesh = body.outline_mesh
	highlight_mesh = body.highlight_mesh

	radius = body.radius
	avoidance_margin = body.avoidance_margin
	height = body.height
	_wear_shape(body.collision_shape)

	var animator: Node = get_node_or_null("UnitAnimator")
	if animator and animator.has_method("adopt_model"):
		animator.adopt_model(body)


## Copies the body's authored shape onto the Unit's own direct-child
## CollisionShape3D, which is the only place Godot will honour it.
##
## Shipped together with the extent numbers above on purpose: a unit that
## PLANS as a dragon and COLLIDES as a demon is worse than one that does
## neither, because the planner routes around a body the physics does not
## have and nothing in the game reports the disagreement.
##
## The Shape3D itself is shared rather than duplicated. Nothing mutates a
## shape at runtime, and every unit wearing one body should be the same
## size — if that ever stops being true, this is the line to change.
## A named point on this unit's body, in world space — see
## CharacterModel.Anchor.
##
## Everything that needs to aim at part of a creature should ask here
## rather than adding an offset of its own. A unit with no body at all
## still answers, from the same proportions the body would have used, so
## no caller needs to handle a missing model.
func anchor(kind: CharacterModel.Anchor) -> Vector3:
	var body := get_node_or_null("CharacterModel") as CharacterModel
	if body:
		return body.anchor_position(kind)
	return global_position + Vector3(0.0, height * _anchor_fallback(kind), 0.0)


## Turn this unit's head toward `target`, if its body can. See
## CharacterModel.gaze_at — false simply means this body does not track,
## which is a normal answer and not worth reporting.
func gaze_at(target: Node3D) -> bool:
	var body := get_node_or_null("CharacterModel") as CharacterModel
	return body.gaze_at(target) if body else false


func stop_gazing() -> void:
	var body := get_node_or_null("CharacterModel") as CharacterModel
	if body:
		body.stop_gazing()


## What someone looking at THIS unit should aim at, or null if it has no
## body to aim at. A node rather than a point, so a gaze keeps following
## while its subject walks.
func gaze_point() -> Node3D:
	var body := get_node_or_null("CharacterModel") as CharacterModel
	return body.gaze_point() if body else null


func _anchor_fallback(kind: CharacterModel.Anchor) -> float:
	match kind:
		CharacterModel.Anchor.HEAD: return 0.85
		CharacterModel.Anchor.EYE: return 0.75
		CharacterModel.Anchor.CHEST: return 0.55
		CharacterModel.Anchor.GROUND: return 0.0
	return 0.0


func _wear_shape(template: CollisionShape3D) -> void:
	if template == null:
		return
	var own := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if own == null:
		return
	own.shape = template.shape
	own.transform = template.transform


func _ready() -> void:
	_status_manager = StatusManager.new(self)
	_action_state = UnitActionState.new(self)
	_facing = UnitFacing.new(self)
	_selection = UnitSelection.new(self)
	_movement = UnitMovement.new(self)
	_combat = UnitCombat.new(self)
	_stat_modifiers = UnitStatModifiers.new()
	_equipment = UnitEquipment.new(self)
	_alignment = UnitAlignment.new(self)
	_skills = UnitSkills.new(self)
	_death = UnitDeath.new(self)
	_awareness = UnitAwareness.new(self)
	# Relayed rather than replaced — external code (CombatManager's
	# end_turn/delay_turn deferral, notably) connects to unit.became_idle
	# directly and must keep working unchanged; the signal's actual
	# source of truth is now UnitActionState, but nothing outside Unit
	# needs to know that. Same reasoning for the four selection signals
	# below, relayed from UnitSelection.
	if not _pending_state.is_empty():
		_apply_pending_state()

	_apply_definition_skills()

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


## Releases _selection's DialogueManager connections whenever this unit
## stops being part of the live tree — not just on death (see
## handle_death()'s own call to the same teardown()). Without this, an
## ordinary world reload (WorldManager.load_world() freeing the outgoing
## world) leaked one UnitSelection per party member per reload: nothing
## else ever disconnected it, so DialogueManager's own strong Callable
## reference kept each one alive, silently calling update_highlight()
## against an already-freed Unit on the next conversation anywhere in the
## game — see UnitSelection.teardown()'s own comment for the full shape
## of the bug and why teardown() has to be idempotent because of this.
func _exit_tree() -> void:
	_selection.teardown()


func _on_mouse_entered() -> void:
	_selection.on_mouse_entered()


func _on_mouse_exited() -> void:
	_selection.on_mouse_exited()


## Left-clicking a unit while your own unit is both selected and the
## currently active one (PlayerInteractionState.get_active_unit() — the
## acting unit in combat, or the first selected unit out of combat) uses
## an ability against it instead of selecting it — see
## UnitCombat.resolve_click_ability() for which ability, if any, that
## turns out to be. Every other click falls through to normal selection
## — a safe no-op for non-player units regardless, since SelectionManager
## itself refuses anything that isn't is_player_controlled().
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
	# A debug spawn click claims the world entirely — a click landing on
	# an existing unit's own collision body while armed must not ALSO
	# select/attack that unit on the same click (Godot physics picking
	# and _unhandled_input both fire independently on one press — see
	# ground_click_target.gd's header). That file's debug-spawn branch is
	# what actually consumes this click.
	if PlayerInteractionState.is_debug_spawn_armed():
		return

	if not event.is_action_pressed("left_click"):
		return

	var acting_unit: Unit = PlayerInteractionState.get_active_unit()
	if acting_unit and acting_unit != self and acting_unit in SelectionManager.selected_units:
		var ability: Ability = _combat.resolve_click_ability(acting_unit)
		if ability:
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


## First dialogue_options entry whose prerequisite is satisfied (or has
## none at all), null if nothing currently applies. Takes actor rather
## than checking self — every other DialogueChoice.prerequisites check
## already evaluates against the PLAYER (see DialogueManager._show_node,
## which always passes participants.get("player")), so a root-selection
## prerequisite follows the same convention for consistency: "does the
## PLAYER'S state make this the right conversation," not the NPC's own.
## Called both by talk_interaction.gd's initial Talk click and by
## DialogueManager.resolve_root_id() for an in-conversation "return to
## hub" choice — the one shared resolver both need, so neither can ever
## disagree about which conversation phase is current.
func resolve_dialogue_root(actor: Unit) -> DialogueNode:
	for option in dialogue_options:
		if not option.prerequisite or option.prerequisite.is_satisfied(actor):
			return option.root
	return null


## Delegates to FactionRelations — see that autoload for the actual
## relation rules (a base faction-to-faction tier, plus any temporary-
## hostile escalation from a provoked attack — see
## UnitCombat._maybe_trigger_combat, the real trigger for that). This
## method itself no longer encodes any faction-specific logic at all;
## it used to hardcode the &"neutral" carve-out directly here, which is
## exactly why a real relation matrix replaced it — that carve-out only
## ever handled one case (a unit is Neutral to everyone), not a real
## per-faction-pair relationship.
func is_hostile_to(other: Unit) -> bool:
	return FactionRelations.is_hostile(faction, other.faction)


## Which fight this unit is currently in, or null. Set by Encounter as it
## adopts and releases units — never assigned from outside.
##
## The field that makes "is this unit under combat rules" a read rather
## than a global assumption. Everything that used to ask
## CombatManager.in_combat about a specific unit's turn economy asks here
## instead, which is what lets one unit fight while another walks around
## freely (see CombatManager's own header).
var encounter: Encounter = null


## Whether combat rules apply to THIS unit — a move budget, a spent attack
## action. Deliberately not the same question as CombatManager.in_combat,
## which asks what the PLAYER is looking at.
func in_combat() -> bool:
	return encounter != null and encounter.is_running


## Whether it is this unit's turn in whatever fight it is in.
func is_my_turn() -> bool:
	return encounter != null and encounter.current_unit == self


## What this unit currently knows about anyone else — see UnitAwareness.
## DetectionManager drives it; everything else only reads.
func awareness() -> UnitAwareness:
	return _awareness


## Whether this unit can be selected/commanded by the player at all.
## SelectionManager enforces this itself (see its select()/add()) so
## there's exactly one place this rule lives — no code path, including
## future ones, can put a non-player unit into a "selected" state.
## Interacting with an enemy (attacking, eventually talking to) stays a
## direct contextual action triggered by a click, not a persistent
## selection — see _on_input_event's attack routing.
func is_player_controlled() -> bool:
	return faction == PLAYER_FACTION


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


## The direction this unit's MODEL actually, visually faces — see
## UnitFacing.visual_forward() for why this differs from
## -global_transform.basis.z (Godot's own "forward") by
## facing_offset_degrees. Anything that needs to know which way a unit
## is really looking (dialogue_camera_rig.gd's shot framing, e.g.)
## should call this, not read basis.z directly.
func visual_forward() -> Vector3:
	return _facing.visual_forward()


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


## Pure route/cost query — see UnitMovement.plan_route's own doc comment.
## Exposed here so AiScorer can price out a candidate destination without
## actually issuing a move order (same read-only need movement_indicator.gd
## already has for its own preview, just reached via RoutePlanner.plan
## directly there since it doesn't need the flying-Y-override step this
## wraps).
func plan_route(raw_destination: Vector3, budget: float = INF) -> Dictionary:
	return _movement.plan_route(raw_destination, budget)


## Cancels the current move order in place, still spending whatever
## distance was actually covered (combat only).
func stop_moving() -> void:
	_movement.stop_moving()


## Immediate, raw stop — no signal, no budget spend. See UnitMovement.
## force_stop() and UnitDeath.handle_death(), its one caller.
func force_stop_movement() -> void:
	_movement.force_stop()


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
## Gives this unit the skills its definition lists, once the machinery
## that can hold them exists.
##
## Not part of the definition cascade, and it cannot be: a SkillInstance is
## a NODE that UnitSkills reparents, and UnitSkills is built in _ready —
## while the cascade runs the moment `definition` is assigned, usually on a
## unit that is not in the tree yet.
##
## Skipped entirely when the unit already has skills of its own. During the
## migration away from hand-placed party members, a scene can still author
## SkillInstance children directly (test_arena's wizard has three), and a
## definition listing the same ones would hand her a second copy of each
## rather than replacing them. The scene wins while it still has an
## opinion; when those nodes go, the definition is all that is left.
func _apply_definition_skills() -> void:
	if definition == null or definition.skills.is_empty():
		return

	var home: Node = get_node_or_null("Skills")
	if home == null or home.get_child_count() > 0:
		return

	for record in definition.skills:
		if record == null or record.skill == null:
			continue
		var instance := SkillInstance.new()
		instance.skill_data = record.skill
		instance.levels_purchased = record.levels_purchased
		# Parented before add_skill, which reparents it — the same order
		# PartyManager.spawn_member uses, and for the same reason.
		add_child(instance)
		add_skill(instance)


func reset_turn_actions() -> void:
	_action_state.reset_turn_actions(float(move))


## --- Status effects — thin forwarding API over _status_manager, see
## status_manager.gd for the actual tracking/dispatch logic. ---

func apply_status(effect: StatusEffect) -> void:
	_status_manager.apply(effect)


## voluntary forwarded straight to StatusManager.remove() — see that
## method's own header. LandEffect is the one caller that passes true.
func remove_status(effect: StatusEffect, voluntary: bool = false) -> void:
	_status_manager.remove(effect, voluntary)


func has_status(effect: StatusEffect) -> bool:
	return _status_manager.has(effect)


## Whether any active status currently grants this unit flight — see
## FlightBehavior/StatusManager.grants_flight(). UnitMovement.move_to()
## checks this to switch NavigationGrid.find_path()'s traversal rule from
## grounded (requires solid support underfoot) to flying (requires only
## being within the flight altitude envelope).
func is_flying() -> bool:
	return _status_manager.grants_flight()


func set_flight_altitude(altitude: float) -> void:
	_movement.set_flight_altitude(altitude)


func ground_if_flying() -> void:
	_movement.ground_if_flying()


## controlled=true (a voluntary Land action) never rolls fall damage,
## regardless of height — see UnitMovement.land()'s own header.
func land(controlled: bool = false) -> void:
	_movement.land(controlled)


## The list of this unit's active statuses currently granting it flight
## — see StatusManager.flight_granting_effects(). Exists so UnitMovement
## can drive ground_if_flying() without reaching into _status_manager
## directly (components talk to their owner, never to each other).
func flight_granting_statuses() -> Array[StatusEffect]:
	return _status_manager.flight_granting_effects()


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


## See UnitActionState.is_acting/can_be_commanded — a walking unit can
## still be told to walk somewhere else.
func is_acting() -> bool:
	return _action_state.is_acting()


func can_be_commanded() -> bool:
	return _action_state.can_be_commanded()


## Whether the PLAYER can direct this unit right now. The single answer
## to a question that used to have two.
##
## It was split between SelectionManager (out of combat) and
## CombatManager.current_unit (in combat), switched on a global
## in_combat flag — which cannot mean anything sensible once several
## fights can run in several worlds at once. Turn order binds a unit
## only while it is actually IN a fight, exactly as movement already
## treats it (see ground_click_target._command_move, the model this
## follows): a member standing outside a battle is commandable while it
## rages, and a combatant is not commandable off its own turn.
func is_commandable() -> bool:
	if not is_alive() or not is_player_controlled():
		return false
	if not can_be_commanded():
		return false
	if in_combat() and not is_my_turn():
		return false
	return true


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


## The name to actually show the player — display_name if one's been
## authored, the scene node's own name otherwise. This fallback (not a
## hard requirement) is what lets existing unit instances keep working
## unchanged the moment this field existed, rather than needing every
## placed unit edited in the same pass that added it.
func get_display_name() -> String:
	return display_name if display_name != "" else name


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
func get_equipped_item(slot_key: EquipSlot.Slot) -> Item:
	return _equipment.get_item(slot_key)


## Every slot currently holding an item — see UnitEquipment.equipped_slots().
func get_equipped_slots() -> Array:
	return _equipment.equipped_slots()


func equip_item(slot_key: EquipSlot.Slot, item: Item) -> void:
	_equipment.equip(slot_key, item)


func unequip_item(slot_key: EquipSlot.Slot) -> Item:
	return _equipment.unequip(slot_key)


## Where an equipped Item node lives while this unit's sheet isn't the
## one currently open — see _equipped_items_home's own header.
func get_equipped_items_home() -> Node:
	return _equipped_items_home


func alignment_category() -> int:
	return _alignment.alignment_category()


func tendency_category() -> int:
	return _alignment.tendency_category()


func apply_alignment_tag(tag: String) -> void:
	_alignment.apply_alignment_tag(tag)


func get_skills() -> Array[SkillInstance]:
	return _skills.get_skills()


func add_skill(skill_instance: SkillInstance) -> void:
	_skills.add_skill(skill_instance)


func distance_to(other: Unit) -> float:
	return global_position.distance_to(other.global_position)


## Center-to-center distance minus both units' radii — how far apart their
## actual bodies are, not their positions. This is what any range check
## (melee or ranged — see Ability.is_in_range) should be measured-
## against; two units can be "touching" while still having meaningfully
## distant global_positions once you account for size.
func edge_distance_to(other: Unit) -> float:
	return max(distance_to(other) - radius - other.radius, 0.0)


## Forwards to SuccessRoll — not UnitCombat, since nothing about GURPS'
## roll-under success resolution actually needs a Unit; both this and
## SkillCheckChoice's dialogue rolls just feed it a target number. Kept
## as a Unit method anyway (rather than callers reaching SuccessRoll
## directly) purely so neither existing caller needed to change when
## this moved out of UnitCombat.
func roll_vs(target_number: int) -> Dictionary:
	return SuccessRoll.roll_vs(target_number)


func attack_skill() -> int:
	return _combat.attack_skill()


func default_ability() -> Ability:
	return _combat.default_ability()


## ST-derived swing/thrust damage — see UnitCombat.roll_damage/
## describe_damage for the actual formula. bonus is the caller's own
## flat addition (an ability's authored bonus, or an equipped weapon's
## damage_bonus) — pass 0 for this unit's bare capability.
func roll_damage(damage_type: UnitCombat.DamageType, bonus: int) -> int:
	return _combat.roll_damage(damage_type, bonus)


func describe_damage(damage_type: UnitCombat.DamageType, bonus: int) -> String:
	return _combat.describe_damage(damage_type, bonus)


func max_damage(damage_type: UnitCombat.DamageType, bonus: int) -> int:
	return _combat.max_damage(damage_type, bonus)


## Expected value of roll_damage() without rolling — see UnitCombat.
## average_damage's own doc comment (AiScorer's reason for existing).
func average_damage(damage_type: UnitCombat.DamageType, bonus: int) -> float:
	return _combat.average_damage(damage_type, bonus)


## Also a coroutine now, same as UnitCombat.use_ability() — it has to
## be, to correctly propagate that method's own return value rather
## than returning whatever a coroutine call yields when not awaited.
## Every existing caller (click routing, CombatAI) already calls this
## fire-and-forget, never touching the return value, so none of them
## needed to change — only this forwarding line, which specifically
## tries to hand that value back to ITS OWN caller, did.
func use_ability(ability: Ability, target) -> Dictionary:
	return await _combat.use_ability(ability, target)


# --- Persistence -----------------------------------------------------
# The duck-typed save_state()/load_state() pair WorldManager already
# looks for when reconciling an area (see _reconcile_area_state, which
# found only StashComponent before this). AreaState recorded who DIED
# and what containers held; a unit remembered nothing, so an enemy you
# wounded and walked away from came back whole the moment its world was
# freed — visible in play, not only across saves.
#
# Awareness is deliberately NOT included. It is per-observer state keyed
# by other units, so writing it needs their ids too, and coming back
# unaware after a reload is the reasonable reading anyway.

func save_state() -> Dictionary:
	return {
		"hp": current_hp,
		"fp": current_fp,
		"transform": global_transform,
		"flight_altitude": flight_target_altitude,
		"move_remaining": move_remaining,
		"has_attacked": has_attacked,
		"statuses": _status_manager.save_state(),
	}


## Deferred when the components this describes do not exist yet — see
## _pending_state. Calling this on a freshly instantiated, not-yet-in-
## tree unit is the NORMAL case, not an edge one.
func load_state(state: Dictionary) -> void:
	_pending_state = state
	if _action_state != null:
		_apply_pending_state()


func _apply_pending_state() -> void:
	var state: Dictionary = _pending_state
	_pending_state = {}

	current_hp = int(state.get("hp", current_hp))
	current_fp = int(state.get("fp", current_fp))
	flight_target_altitude = float(state.get("flight_altitude", flight_target_altitude))
	move_remaining = float(state.get("move_remaining", move_remaining))
	has_attacked = bool(state.get("has_attacked", has_attacked))
	_status_manager.load_state(state.get("statuses", []))

	if state.has("transform"):
		global_transform = state["transform"]


func take_damage(amount: int) -> void:
	_combat.take_damage(amount)


## Restores amount HP, clamped at maximum_hp. Returns the amount
## ACTUALLY restored (may be less than amount once near/at maximum_hp)
## — see UnitCombat.heal().
func heal(amount: int) -> int:
	return _combat.heal(amount)


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


func expire() -> void:
	_death.expire()


## Death cleanup (group/selection/movement/physics teardown, summon
## cascade, queue_free) — see UnitDeath.handle_death(). Public: called
## both by expire() above and by UnitCombat.take_damage() when this
## unit's HP reaches 0 through an actual hit.
##
## _selection.teardown() lives here rather than inside
## UnitDeath.handle_death() itself — UnitDeath and UnitSelection stay
## unaware of each other, same as everywhere else in this file; Unit is
## the one place that already legitimately holds both.
func handle_death() -> void:
	_death.handle_death()
	_selection.teardown()
