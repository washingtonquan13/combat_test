class_name Unit
extends CharacterBody3D

@export_group("Identity")
## Which kind of unit this is — cascades display_name/portrait_texture/
## faction/the full stat block/abilities/ai_behaviors/
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
## overrides faction and its HP/FP pools afterward (a recruited demon
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
			_unit_stats().reset(definition.stats)
			abilities = definition.abilities
			natural_attacks = definition.natural_attacks
			body_plan = definition.body_plan
			injury_preset = definition.injury_preset
			missing_locations = definition.missing_locations
			injury_divisor = definition.injury_divisor
			# Resolved, not raw: a species normally names an AiArchetype
			# and leaves ai_behaviors empty — see UnitDefinition.
			ai_behaviors = definition.resolved_ai_behaviors()
			ai_smartness = definition.resolved_ai_smartness()
			negotiable = definition.negotiable
			vision_cone_degrees = definition.vision_cone_degrees
			max_sight_range = definition.max_sight_range
			proximity_radius = definition.proximity_radius
			dark_vision = definition.dark_vision
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

## The ability use under way, set from just before ability_use_started
## until just after ability_used — already decided, for presentation to
## read (see AbilityAction). Null between actions.
var current_action: AbilityAction = null

## Per-placement stat bases over the definition's — a hand-placed unit
## that should be quicker than its species (test_arena's Scared
## Townperson, DX 18). Declared after `definition` so it lands after the
## definition's own reset; ids are StatDefinition ids, same as
## UnitDefinition.stats.
@export var stat_overrides: Dictionary[StringName, int] = {}:
	set(value):
		stat_overrides = value
		if not stat_overrides.is_empty():
			_unit_stats().from_dict({"stats": stat_overrides})
			_unit_stats().fill_pools()

## Set once by UnitDeath.handle_death. Needed because a player-side unit
## can be alive below 0 HP, so HP alone no longer answers is_alive().
var has_died: bool = false

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
## Dark Vision (GURPS B47): sees through darkness, magical included. A
## Darkness cloud neither blocks this unit's sight nor Blinds it. Fog
## still does: that is not darkness.
@export var dark_vision: bool = false

@export_group("Alignment")
## Two independent axes, each a plain signed integer — no enum, no
## string tag stored on the unit itself (DialogueChoice.alignment_name
## is authored per-CHOICE, this is the unit's own running total).
## Chaos-Neutral-Law on this one; see tendency below for Dark-Neutral-
## Light. Positive = Law, negative = Chaos, matching apply_alignment_tag.
@export var alignment: int = 0
## Dark-Neutral-Light. Positive = Light, negative = Dark.
@export var tendency: int = 0

@export_group("Movement")
## Real-time speed (world units/sec) while executing a move order. Distinct
## from the Move stat, which is the per-turn distance budget in combat.
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
## Units with a different faction than the acting unit are valid attack
## targets when clicked during that unit's turn; same-faction clicks still
## select as normal (see ClickRouter.click_unit / is_hostile_to).
@export var faction: StringName = &"player"
## The canonical "this is the player's own side" tag — named here so
## is_player_controlled() and anything else that cares "is this MY unit"
## (LogFormat's coloring, e.g.) reference one constant instead of
## independently retyping the literal &"player". NOT part of
## FactionRelations' relation matrix — that autoload treats "player" as
## an ordinary faction tag like any other; this is purely about who the
## player controls, a separate question from who's hostile to whom.
const PLAYER_FACTION: StringName = &"player"
## The render layer every unit's body and held gear wear (and the Wall of
## Fire's volume), so a ground decal (Grease) can leave units out with its
## cull_mask instead of painting their feet.
const RENDER_LAYER: int = 2
## Physics layer 20, worn only by each unit's PickArea, so a mouse ray can
## look for "a unit under the cursor" without hitting walls or floors.
const PICK_LAYER: int = 1 << 19
## Below a third of its maximum, each pool puts its status on (GURPS
## B419 and B426: Move and Dodge halved); back at a third or more, it
## comes off. See _update_low_pool_statuses.
const LOW_POOL_STATUSES: Dictionary[StringName, StatusEffect] = {
	StatIds.HP: preload("res://data/statuses/bloodied.tres"),
	StatIds.FP: preload("res://data/statuses/exhausted.tres"),
}
## Abilities this unit currently has available. abilities[0] is used as
## the default (see default_ability) when nothing's explicitly armed via
## AbilityManager — that's what makes click-to-attack keep working before
## a hotbar exists to actually choose between multiple abilities.
##
## Read freely, but write through set_abilities/add_ability/remove_ability
## (or plain assignment, whose setter does the same): either way
## loadout_changed fires. An in-place append/erase on this array changes
## what the unit can use without telling anyone, and can write into the
## UnitDefinition the array came from — the definition setter hands over
## its own array, not a copy.
@export var abilities: Array[Ability] = []:
	set(value):
		abilities = value
		_queue_loadout_changed()
## This body's own attacks (claws, teeth) — see UnitDefinition.
## natural_attacks and combat_abilities(). Written like abilities: assign
## or set_natural_attacks, never in place.
@export var natural_attacks: Array[AttackRow] = []:
	set(value):
		natural_attacks = value
		_queue_loadout_changed()
## This body's anatomy and Injury Tolerance — see UnitDefinition.body_plan
## and injury_profile().
@export var body_plan: BodyPlan
@export var injury_preset: InjuryPreset
@export var missing_locations: Array[HitLocation] = []
@export var injury_divisor: float = 1.0
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
##
## Written like abilities: assign, set_custom_slots or set_custom_slot,
## never by index in place.
@export var custom_slots: Array[Ability] = [null, null, null, null, null, null]:
	set(value):
		custom_slots = value
		_queue_loadout_changed()
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
## A live Unit's own HP/FP pools are the source of truth WHILE
## it's summoned — this only gets synced back into owned_demon's own
## pools at the moment it leaves the field (see
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
## The anchor for this unit's ground ring (hover, selection, active turn).
## Its mesh only says how big the footprint is: UnitSelection reads a
## radius from it, clears it, and projects a ring decal onto whatever is
## underfoot instead (see unit_selection.gd's header). Its `visible` is
## the ring's on/off switch. Safe to leave unassigned — no ring is drawn.
@export var highlight_mesh: MeshInstance3D
## Optional full-body outline — a SEPARATE MeshInstance3D sharing the
## same mesh and skeleton as the character model, with the outline.gdshader
## material applied (see that file's header for the technique). Distinct
## from highlight_mesh (that one's a flat ring at the feet; this one
## traces the actual animated silhouette) — safe to leave unassigned,
## same as highlight_mesh.
@export var outline_mesh: MeshInstance3D
## No longer read by the ring or the outline: those take their hue from
## the unit's relation to the party (IndicatorPalette). Kept because it is
## still saved and restored per party member (PartyManager) and set in
## scenes, and removing an export a scene still sets is a scene edit.
@export var hover_color: Color = Color(1, 1, 1, 0.5)
## This unit's UI accent — portrait outline, dialogue speaker colour. Not
## the ring's colour any more (see hover_color).
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
## This unit beat an attack with its defense — `kind` is &"dodge",
## &"parry" or &"block" (UnitCombat.best_defense) — emitted at the
## attack's impact, so the answer shows when the blow arrives.
signal defended(unit: Unit, kind: StringName)
## A stat's own parts changed — its base, a status or gear modifier.
## Stats derived from it may have changed too.
signal stat_changed(unit: Unit, id: StringName)
## A toggle ability was switched on or off (UnitCombat.set_toggled) — the
## hotbar's lit borders.
signal toggles_changed(unit: Unit)
## Something was equipped or taken off — the attacks it offers changed
## (see combat_abilities()).
signal equipment_changed(unit: Unit)
## Anything about what this unit can use or how its weapons are shown
## changed: equipment, abilities, natural attacks, custom slots, the
## active weapon set, drawn or sheathed. Deferred and coalesced — fires
## once, at the end of the frame, however many changes landed in it, so
## state is consistent by the time anyone reads it. Never fires before
## the unit is ready: a listener reads the starting state when it
## connects. See _queue_loadout_changed.
signal loadout_changed(unit: Unit)
## A pool's current or maximum may have changed — HP bars, FP pips.
signal pool_changed(unit: Unit, id: StringName, current: int, maximum: int)
signal healed(unit: Unit, amount: int)
signal died(unit: Unit)
## Fired when this unit goes Downed and again when it stops being Downed
## (picked up, stabilized). Not fired on death — died covers that.
signal downed_changed(unit: Unit)
## Downed's two tracks moved — a roll, a hit, or the fight's end making
## the unit stable (DeathRollsBehavior). The overhead DownedTracker.
signal downed_tally_changed(unit: Unit)

## Fired when the current action's impact counts — the first
## notify_impact() during it, from an attack animation's Call Method
## Track (the frame a weapon connects) or a VFX sequence's
## ImpactSignalStep (a projectile arriving). Once per action: repeats,
## and calls with no action under way, are dropped. For presentation
## (UnitSfx's impact cue); the rules wait on AbilityAction itself.
signal impact_triggered()

## Fired when current_action's cast lets go (AbilityAction.released):
## the release key in the cast animation, or the sequence's end. UnitVfx
## starts the ability's cast_vfx here and lets go of a held flame, so the
## flame that was held is the one that flies.
signal cast_released(action: AbilityAction)

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
## The body leaving the ground (GrantFlightEffect) and arriving back on it
## (the end of UnitMovement.land's descent) — moments, for presentation.
## Whether the unit counts as flying is is_flying(), which changes at
## neither: it turns on before the climb and off before the descent.
signal took_off(unit: Unit)
signal touched_down(unit: Unit)
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
## Built on first use, not in _ready — the definition setter writes
## stats while the scene is still instantiating. See _unit_stats().
var _stats: UnitStats
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

	# avoidance_margin is a gap between bodies, not part of one, so it
	# stays as authored whatever size the body is worn at.
	avoidance_margin = body.avoidance_margin
	_wear_size(false)
	_fit_size_strength()
	wear_render_layer(body)

	var animator: Node = get_node_or_null("UnitAnimator")
	if animator and animator.has_method("adopt_model"):
		animator.adopt_model(body)


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


## This unit's animator, or null if it has no body.
##
## Named rather than reached for by node path at every call site — the
## cinematic system needs it and should not have to know what the node is
## called, the same reason anchor() exists rather than everyone searching
## for a FaceAnchor.
func animator() -> UnitAnimator:
	return get_node_or_null("UnitAnimator") as UnitAnimator


## Turn this unit's head toward `target`, if its body can. See
## CharacterModel.gaze_at — false simply means this body does not track,
## which is a normal answer and not worth reporting.
func gaze_at(target: Node3D) -> bool:
	var body := get_node_or_null("CharacterModel") as CharacterModel
	return body.gaze_at(target) if body else false


func stop_gazing(ease_seconds: float = 0.0) -> void:
	var body := get_node_or_null("CharacterModel") as CharacterModel
	if body:
		body.stop_gazing(ease_seconds)


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
		CharacterModel.Anchor.HAND: return 0.55
		CharacterModel.Anchor.MUZZLE: return 0.55
		CharacterModel.Anchor.GROUND: return 0.0
	return 0.0


## Puts node and everything visible under it on RENDER_LAYER alone.
static func wear_render_layer(node: Node) -> void:
	var visuals: Array[Node] = node.find_children("*", "VisualInstance3D", true, false)
	if node is VisualInstance3D:
		visuals.append(node)
	for visual in visuals:
		(visual as VisualInstance3D).layers = 1 << (RENDER_LAYER - 1)


## Seconds a body takes to grow or shrink to a new SM.
const SIZE_CHANGE_SECONDS: float = 0.8

## The scale the body is shown at now: its SM's size, or on the way there.
var worn_size: float = 1.0
var _size_tween: Tween
## Size's share of ST (stats.md): a body grown or shrunk from its own SM
## is that much stronger or weaker. Registered only while nonzero.
var _size_strength: StatModifierBehavior


## Wears this unit's SM: the body scaled whole (grown or shrunk to it over
## SIZE_CHANGE_SECONDS when animate, at once otherwise), and the extent
## the grid, the range checks, the collision and the pick area read with
## it - those at once, so nothing plans with a size the unit is leaving.
func _wear_size(animate: bool) -> void:
	var body := get_node_or_null("CharacterModel") as CharacterModel
	if body == null:
		return
	var size: float = SizeModifier.scale_for(floori(get_stat(StatIds.SM)), body.authored_size_modifier)
	radius = body.radius * size
	height = body.height * size
	_wear_shape(body.collision_shape, size)
	_fit_pick_area()
	if _size_tween:
		_size_tween.kill()
	if not animate or not is_inside_tree():
		_show_size(size, body)
		return
	_size_tween = create_tween().set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_size_tween.tween_method(_show_size.bind(body), worn_size, size, SIZE_CHANGE_SECONDS)


func _show_size(size: float, body: CharacterModel) -> void:
	if not is_instance_valid(body):
		return
	worn_size = size
	body.scale = Vector3.ONE * size
	if _selection:
		_selection.fit_ring(size)


## Sets Size's share of ST: ST before it, times how much longer this unit
## is at its SM than at its own base SM. Relative to the base, so a
## creature authored big (a dragon's ST 18 at SM +2) keeps its ST; only a
## change from it - Enlarge, Reduce - moves it. HP follows ST, and a pool
## over its new maximum is brought down to it.
func _fit_size_strength() -> void:
	var stats := _unit_stats()
	var ratio: float = SizeModifier.scale_for(floori(get_stat(StatIds.SM)), stats.get_base(StatIds.SM))
	var current: int = _size_strength.amount if _size_strength else 0
	var before_size: float = stats.get_unhalved(StatIds.ST) - current
	var amount: int = roundi(before_size * (ratio - 1.0))
	if amount == current:
		return
	if _size_strength:
		stats.remove_modifier(_size_strength, "Size")
	else:
		_size_strength = StatModifierBehavior.new()
		_size_strength.stat_name = StatIds.ST
	_size_strength.amount = amount
	if amount != 0:
		stats.add_modifier(_size_strength, "Size")
	stats.set_current(StatIds.HP, stats.get_current(StatIds.HP))


func _on_own_stat_changed(_unit: Unit, id: StringName) -> void:
	if id == StatIds.SM:
		_wear_size(true)
	if id == StatIds.SM or id == StatIds.ST:
		_fit_size_strength()


## Copies the body's authored shape onto the Unit's own direct-child
## CollisionShape3D, which is the only place Godot will honour it, at
## `size` times its authored size (a scaled copy; the authored shape is
## shared and never mutated).
##
## Shipped together with the extent numbers in _wear_size on purpose: a
## unit that PLANS as a dragon and COLLIDES as a demon is worse than one
## that does neither, because the planner routes around a body the
## physics does not have and nothing in the game reports the disagreement.
func _wear_shape(template: CollisionShape3D, size: float = 1.0) -> void:
	if template == null:
		return
	var own := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if own == null:
		return
	own.shape = template.shape if is_equal_approx(size, 1.0) else _scaled_shape(template.shape, size)
	own.transform = template.transform
	own.position *= size


## A copy of shape size times bigger. Scaled by its own measures, not the
## node's scale, which physics does not reliably honour on a shape.
static func _scaled_shape(shape: Shape3D, size: float) -> Shape3D:
	var scaled: Shape3D = shape.duplicate()
	if scaled is CapsuleShape3D or scaled is CylinderShape3D:
		scaled.radius *= size
		scaled.height *= size
	elif scaled is SphereShape3D:
		scaled.radius *= size
	elif scaled is BoxShape3D:
		scaled.size *= size
	else:
		push_warning("Unit: no way to scale a %s; worn at its authored size." % shape.get_class())
	return scaled


func _ready() -> void:
	_status_manager = StatusManager.new(self)
	_action_state = UnitActionState.new(self)
	_facing = UnitFacing.new(self)
	# A real child Node, not a RefCounted field like its neighbours — see
	# unit_selection.gd's header for why it moved and what the engine
	# gives it in exchange. Built in the same slot in the same order as
	# before, so nothing about WHEN it comes into being changes; the
	# add_child() runs its _enter_tree and _ready synchronously right
	# here, between them doing what the _selection.setup() call at the
	# bottom of this function used to. Safe at this point for a precise
	# reason: everything that setup read (highlight_mesh, outline_mesh)
	# is bound in _enter_tree (see _bind_model), long before any of this.
	#
	# Created from code rather than authored into unit.tscn so every unit
	# scene gains it without a scene edit, and so a unit assembled purely
	# in code still has one.
	_selection = UnitSelection.new(self)
	_selection.name = "Selection"
	add_child(_selection)
	_movement = UnitMovement.new(self)
	_combat = UnitCombat.new(self)
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
	_status_manager.status_applied.connect(func(_effect, _active): _on_flight_maybe_changed())
	_status_manager.status_removed.connect(func(_effect): _on_flight_maybe_changed())
	_status_manager.status_ticked.connect(func(effect, _active): status_ticked.emit(self, effect))
	pool_changed.connect(func(_unit, _id, _current, _maximum): _update_low_pool_statuses())
	_status_manager.status_applied.connect(func(_effect, _active): _update_low_pool_statuses())
	_status_manager.status_removed.connect(func(_effect): _update_low_pool_statuses())
	_update_low_pool_statuses()
	# The body's capsule (radius 0.25) is too thin to aim at, so hover comes
	# from a fatter PickArea cylinder the size of the selection ring. Physics
	# picking reports only the first hit, which is the cylinder, so the
	# body's own mouse_entered would never fire and is not connected. The
	# body stays input_ray_pickable all the same: ClickRouter reads that flag
	# as the unit's one "can be clicked" switch (see set_pickable). HOVER
	# ONLY here: clicking a unit belongs to ClickRouter, which raycasts for
	# itself and marks the event handled, so a click never reaches physics
	# picking at all. A unit deciding what a click on it means was one of
	# the eight places player intent used to live.
	add_to_group("units")
	stat_changed.connect(_on_own_stat_changed)
	# Every equipment_changed (equip, unequip, an item's own refresh in
	# UnitEquipment) is a loadout change too — one connection here, not a
	# second emit beside each of the three.
	equipment_changed.connect(func(_unit: Unit) -> void: _queue_loadout_changed())
	_apply_definition_equipment()

	input_ray_pickable = true
	_build_pick_area()
	pick_area.mouse_entered.connect(_on_mouse_entered)
	pick_area.mouse_exited.connect(_on_mouse_exited)


## The smallest a unit's PickArea gets, so a tiny creature can still be
## hovered and clicked.
const MIN_PICK_RADIUS: float = 0.3
const MIN_PICK_HEIGHT: float = 1.0


## The unit's click and hover target: an Area3D on PICK_LAYER that neither
## monitors nor is monitored, so it never touches movement or overlap
## queries. Built in code, not unit.tscn, so every unit gets the same one.
var pick_area: Area3D


func _build_pick_area() -> void:
	pick_area = Area3D.new()
	pick_area.name = "PickArea"
	pick_area.monitoring = false
	pick_area.monitorable = true
	pick_area.collision_layer = PICK_LAYER
	pick_area.collision_mask = 0
	pick_area.input_ray_pickable = true
	var shape := CollisionShape3D.new()
	shape.name = "Shape"
	shape.shape = CylinderShape3D.new()
	pick_area.add_child(shape)
	add_child(pick_area)
	_fit_pick_area()


## Sizes the PickArea's cylinder to the unit's radius and height: twice
## the radius, as the ring is, but never too small to point at - a pixie
## is a quarter of a man.
func _fit_pick_area() -> void:
	if pick_area == null:
		return
	var shape := pick_area.get_node("Shape") as CollisionShape3D
	var cylinder := shape.shape as CylinderShape3D
	cylinder.radius = maxf(radius * 2.0, MIN_PICK_RADIUS)
	cylinder.height = maxf(height, MIN_PICK_HEIGHT)
	shape.position = Vector3(0.0, cylinder.height * 0.5, 0.0)


## The Unit a PickArea belongs to, or null for anything else a ray hit.
static func from_pick_area(area: Object) -> Unit:
	var node := area as Node
	if node == null:
		return null
	return node.get_parent() as Unit


## Turns clicking and hovering this unit on or off together: the body's
## flag (ClickRouter's "can be clicked") and the PickArea's (hover).
func set_pickable(value: bool) -> void:
	input_ray_pickable = value
	if pick_area != null:
		pick_area.input_ray_pickable = value


## This used to be followed by an _exit_tree() whose entire body was
## _selection.teardown() — releasing the component's GameMode connection
## whenever the unit stopped being part of the live tree, because a
## RefCounted component connected to an autoload outlives its owner
## (the Callable holds a strong reference) and the next mode change
## anywhere in the game then ran update_highlight() against a freed Unit.
## An ordinary world reload leaked one per party member, before anything
## had died. UnitSelection is a child Node now, so it exits the tree with
## this unit and disconnects itself in its own _exit_tree — the engine
## does the bookkeeping a hand-written teardown() used to, and there is
## no longer a caller that can forget it.
func _on_mouse_entered() -> void:
	_selection.on_mouse_entered()


func _on_mouse_exited() -> void:
	_selection.on_mouse_exited()


## Which ability, if any, fires when actor clicks THIS unit — see
## UnitCombat.resolve_click_ability for the rule (the armed ability
## first, otherwise actor's default, routed by whether it wants an ally
## or an enemy). A plain forward so ClickRouter, which owns that click
## now, does not have to reach into another unit's private component.
##
## The click handling itself used to live here, on every unit, reached by
## per-object physics picking — which meant each unit carried its own
## copy of the player's targeting rules and its own guard about whether
## the player was even in control (it checked for a running conversation,
## and only that, so a click during a negotiation or a loot screen still
## went through). It lives in one place now.
func click_ability_for(actor: Unit) -> Ability:
	return _combat.resolve_click_ability(actor)


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
## none at all), null if nothing currently applies. Asked in c, the
## conversation the root is for: its "player" is the actor every
## prerequisite's default reads (see PrerequisiteRule.is_satisfied_in), so
## "does the PLAYER'S state make this the right conversation," not the
## NPC's own, and a rule that reads the conversation itself (who is
## present, say) sees its cast. Called both by talk_interaction.gd's
## initial Talk click, with the cast about to begin, and by
## LineChoice.resolve for an in-conversation "return to hub" choice, with
## the live conversation — the one shared resolver both need, so neither
## can ever disagree about which conversation phase is current.
func resolve_dialogue_root(c: Conversation) -> DialogueNode:
	for option in dialogue_options:
		if not option.prerequisite or option.prerequisite.is_satisfied_in(c):
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
##
## Also where weapons are drawn and put away: adopted into a fight (its
## start, a resume, joining one already running) draws; released from it
## (its end, fleeing it) sheathes. Encounter is the one place that adopts
## and releases, so this is the one place that sees every way in and out.
var encounter: Encounter = null:
	set(value):
		var was_fighting: bool = encounter != null
		encounter = value
		if (value != null) != was_fighting:
			set_weapons_sheathed(value == null)


## Whether combat rules apply to THIS unit — a move budget, a spent attack
## action. Deliberately not the same question as CombatManager.in_combat,
## which asks what the PLAYER is looking at.
func in_combat() -> bool:
	return encounter != null and encounter.is_running


## How far this unit may move right now. Out of combat movement is
## unmetered, so previews and AI must ask here rather than read
## move_remaining, which is 0 outside combat.
func move_budget() -> float:
	return move_remaining if in_combat() else INF


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
## selection — see ClickRouter.click_unit's attack routing.
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


func set_area_targeted(value: bool) -> void:
	_selection.set_area_targeted(value)


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
func move_to(destination: Vector3, ignore: Array = []) -> bool:
	return _movement.move_to(destination, ignore)


## Pure route/cost query — see UnitMovement.plan_route's own doc comment.
## Exposed here so AiScorer can price out a candidate destination without
## actually issuing a move order.
func plan_route(raw_destination: Vector3, budget: float = INF, ignore: Array = []) -> Dictionary:
	return _movement.plan_route(raw_destination, budget, ignore)


## The full route move_to(dest) would take, ladder journeys included —
## see UnitMovement.preview_route. What the movement preview draws.
func preview_route(dest: Vector3, ignore: Array = []) -> Dictionary:
	return _movement.preview_route(dest, ignore)


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


## On a ladder right now — part of a move, so is_moving() too.
func is_climbing() -> bool:
	return _movement.is_climbing()


## 1 climbing up, -1 down, 0 otherwise (see UnitMovement.climb_direction).
func climb_direction() -> int:
	return _movement.climb_direction()


func climb_speed() -> float:
	return _movement.climb_speed()


## The route this unit is walking right now, start to destination as it
## was planned, in preview_route()'s shape; empty while not walking.
func current_route() -> Dictionary:
	return _movement.current_route()


## Budget cost walked so far on the current route (display only; see
## UnitMovement.cost_walked).
func move_cost_walked() -> float:
	return _movement.cost_walked()


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
## Equips the items its definition lists, once UnitEquipment exists. Like
## skills, not part of the definition cascade (that runs before _ready).
## A slot already filled (a save, a scene) is left alone.
func _apply_definition_equipment() -> void:
	if definition == null:
		return
	for slot_key in definition.equipment:
		var item_def: ItemDefinition = definition.equipment[slot_key]
		if item_def != null and get_equipped_item(slot_key) == null:
			equip_item(slot_key, ItemInstance.new(item_def))
	# An archer with nothing for melee starts with its bow as the active set,
	# so it is the bow that comes out when the fight starts.
	if get_equipped_item(EquipSlot.Slot.MELEE_MAIN_HAND) == null \
			and get_equipped_item(EquipSlot.Slot.RANGED_MAIN_HAND) != null:
		set_active_weapon_set(AttackRow.Kind.RANGED, false)


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


## Meters this unit can cover in one turn: Basic Move, or Air Move while
## flying. A GURPS yard is taken as one meter of world.
func move_per_turn() -> float:
	return _move_per_turn(is_flying())


func _move_per_turn(flying: bool) -> float:
	return get_stat(StatIds.AIR_MOVE if flying else StatIds.MOVE)


func reset_turn_actions() -> void:
	_budget_flying = is_flying()
	_action_state.reset_turn_actions(move_per_turn())
	_combat.reset_defenses()


## Which Move move_remaining is measured in. Taking off or landing mid-turn
## keeps the share of the turn left, not the meters: half a turn walked
## leaves half a turn of Air Move.
var _budget_flying: bool = false


func _on_flight_maybe_changed() -> void:
	var flying: bool = is_flying()
	if flying == _budget_flying:
		return
	var was: float = _move_per_turn(_budget_flying)
	_budget_flying = flying
	if was > 0.0:
		move_remaining *= _move_per_turn(flying) / was


## Whether any of this unit's abilities can put it in the air.
func can_fly() -> bool:
	for ability in abilities:
		if ability:
			for effect in ability.effects:
				if effect is GrantFlightEffect:
					return true
	return false


## --- Status effects — thin forwarding API over _status_manager, see
## status_manager.gd for the actual tracking/dispatch logic. ---

func apply_status(effect: StatusEffect) -> void:
	_status_manager.apply(effect)


## The status on this unit that effect would counter and remove instead
## of landing (StatusEffect.counters), or null.
func status_countered_by(effect: StatusEffect) -> StatusEffect:
	return _status_manager.countered_by(effect)


## A status put on this unit by an ability or a surface, which it may
## resist (UnitCombat.resists). apply_status is for the ones the rules
## put on — Downed, Flying, a summon's timer — which always land.
## Returns whether it landed.
func inflict_status(effect: StatusEffect, source: Unit) -> bool:
	if _combat.resists(effect, source):
		return false
	apply_status(effect)
	return true


## A surface's status just landed on this unit as they got into it
## (StatusBehavior.on_contact).
func status_contact(effect: StatusEffect) -> void:
	_status_manager.contact(effect)


## Bloodied and Exhausted follow their pools, both ways, on every pool
## change — damage, healing, FP spent, a maximum moving. Every unit, not
## just the party. Never partway through a status change (see
## StatusManager.busy): one that removed a status while its modifiers
## were still going on would strand the rest on the unit. Any status
## change runs this again once it is whole.
func _update_low_pool_statuses() -> void:
	if _status_manager.busy > 0 or not is_alive():
		return
	for id in LOW_POOL_STATUSES:
		var effect: StatusEffect = LOW_POOL_STATUSES[id]
		var low: bool = get_pool(id) * 3 < floori(get_stat(id))
		if low == has_status(effect):
			continue
		if low:
			apply_status(effect)
			SystemLog.print("%s is %s." % [LogFormat.unit_name(self), effect.status_name])
		else:
			remove_status(effect)
			SystemLog.print("%s is no longer %s." % [LogFormat.unit_name(self), effect.status_name])


## voluntary forwarded straight to StatusManager.remove() — see that
## method's own header. LandEffect is the one caller that passes true.
func remove_status(effect: StatusEffect, voluntary: bool = false) -> void:
	_status_manager.remove(effect, voluntary)


func has_status(effect: StatusEffect) -> bool:
	return _status_manager.has(effect)


## Every status on this unit now, in the order they landed.
func active_statuses() -> Array[StatusEffect]:
	var out: Array[StatusEffect] = []
	for active in _status_manager.active:
		out.append(active.effect)
	return out


## 0 when the status isn't active.
func status_turns_remaining(effect: StatusEffect) -> int:
	return _status_manager.turns_remaining(effect)


## The status's live tally (ActiveStatus.tally); empty when not active.
func status_tally(effect: StatusEffect) -> Dictionary:
	return _status_manager.tally(effect)


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
	return not has_died and (get_pool(StatIds.HP) > 0 or uses_downed_rule())


## Party members and their owned demons fight on below 0 HP and go
## Downed instead of dying — everyone else (enemies, plain summons) dies
## at 0. See UnitCombat.take_damage.
func uses_downed_rule() -> bool:
	return is_player_controlled() and (summoned_by == null or owned_demon != null)


## Downed is a status (UnitCombat.downed_status) — having it is being
## Downed.
func is_downed() -> bool:
	return not has_died and has_status(UnitCombat.downed_status())


## Downed's two tracks — {"stable": n, "death": n}, each out of
## DeathRollsBehavior.TO_END. Empty when not Downed.
func downed_tally() -> Dictionary:
	return status_tally(UnitCombat.downed_status())


## Downed and done rolling — safe until the next hit, which makes it
## unstable again.
func is_stable() -> bool:
	return is_downed() and downed_tally().get("stable", 0) >= DeathRollsBehavior.TO_END


## One turn's roll while Downed — the SuccessRoll.roll_vs result.
func roll_while_downed() -> Dictionary:
	return _combat.roll_while_downed()


## Damage this unit can still take before it is dead — current HP for
## anyone who dies at 0, down to -5x HP for anyone on the downed rule.
func hp_to_death() -> int:
	return _combat.hp_to_death()


## Clears Downed, leaving HP where it is. Returns whether the unit was
## Downed at all.
func pick_up() -> bool:
	return _combat.pick_up()


## Death by any cause other than damage — Downed's third mark toward
## death (DeathRollsBehavior).
func die() -> void:
	_combat._die()


## Combat ended with this unit Downed: stable where it lies, HP
## untouched, until picked up or healed.
func stabilize() -> void:
	_combat.stabilize()


## The name to actually show the player — display_name if one's been
## authored, the scene node's own name otherwise. This fallback (not a
## hard requirement) is what lets existing unit instances keep working
## unchanged the moment this field existed, rather than needing every
## placed unit edited in the same pass that added it.
func get_display_name() -> String:
	return display_name if display_name != "" else name


## A stat's value with everything applied — formula, bought bonus,
## statuses, gear. id is a StatDefinition id (StatIds names the ones
## rules use); the list of stats is res://data/stats/, not this class.
## For a pool this is its MAXIMUM — get_pool() is the current value.
## Fractions are kept (Basic Speed 5.25): drop them with floori where a
## whole number is the rule.
func get_stat(id: StringName) -> float:
	return _unit_stats().get_value(id)


## get_stat before Bloodied's and Exhausted's halvings — see
## UnitStats.get_unhalved.
func get_stat_unhalved(id: StringName) -> float:
	return _unit_stats().get_unhalved(id)


## Alias for skill_system's DefaultRule/AttributePrerequisite, which name
## an attribute off a .tres.
func get_attribute_value(attribute_name: StringName) -> int:
	return floori(get_stat(attribute_name))


## Unmodified base — a primary's authored value, a derived stat's bought
## bonus. What chargen and the debug spawner write.
func get_base_stat(id: StringName) -> int:
	return _unit_stats().get_base(id)


func set_base_stat(id: StringName, value: int) -> void:
	_unit_stats().set_base(id, value)


## The value with no status or gear applied.
func get_unmodified_stat(id: StringName) -> float:
	return _unit_stats().get_unmodified(id)


## A pool's current value — HP, FP. Its maximum is get_stat(id).
func get_pool(id: StringName) -> int:
	return _unit_stats().get_current(id)


## Sets a pool, capped at its maximum, never floored (HP below 0 is
## Downed). Damage and healing go through take_damage()/heal(), which
## also run the death and Downed rules; this is the raw write.
func set_pool(id: StringName, value: int) -> void:
	_unit_stats().set_current(id, value)


func spend_pool(id: StringName, amount: int) -> void:
	_unit_stats().damage(id, amount)


func restore_pool(id: StringName, amount: int) -> void:
	_unit_stats().restore(id, amount)


func fill_pools() -> void:
	_unit_stats().fill_pools()


## Sum of every modifier currently on a stat.
func stat_modifier(id: StringName) -> int:
	return _unit_stats().modifier_total(id)


## Registers/unregisters one StatModifierBehavior — StatusManager on
## apply/remove, UnitEquipment on equip/unequip. source is a display
## label (a status_name, an item_name), passed per registration because
## the modifier resource is shared — see ActiveStatModifier. Unregister
## names the source too, so two sources sharing one modifier resource
## stay independent.
func register_stat_modifier(modifier: StatModifierBehavior, source: String) -> void:
	_unit_stats().add_modifier(modifier, source)


func unregister_stat_modifier(modifier: StatModifierBehavior, source: String) -> void:
	_unit_stats().remove_modifier(modifier, source)


## How a stat's value is reached, part by part — see UnitStats.breakdown.
func stat_breakdown(id: StringName) -> Array[Dictionary]:
	return _unit_stats().breakdown(id)


## The sources of every modifier currently on a stat.
func stat_modifier_sources(id: StringName) -> Array[String]:
	return _unit_stats().modifier_sources(id)


## Every stat base and pool current — see UnitStats.to_dict. The only way
## stats leave a unit.
func stats_to_dict() -> Dictionary:
	return _unit_stats().to_dict()


## Merges what the dict carries — see UnitStats.from_dict. The only way
## stats enter a unit.
func stats_from_dict(data: Dictionary) -> void:
	_unit_stats().from_dict(data)


func _unit_stats() -> UnitStats:
	if _stats == null:
		_stats = UnitStats.new(self)
		_stats.stat_changed.connect(func(id: StringName) -> void: stat_changed.emit(self, id))
		_stats.pool_changed.connect(func(id: StringName, current: int, maximum: int) -> void:
			pool_changed.emit(self, id, current, maximum))
	return _stats


var _injury_profile: InjuryProfile
var _injury_profile_key: Array = []


## How this unit takes injury: its body plan (human by default), its
## preset, then its missing locations. Rebuilt only when one of those
## changes, so DamageResolver can ask on every roll.
func injury_profile() -> InjuryProfile:
	var plan: BodyPlan = body_plan if body_plan else BodyPlan.human()
	var key: Array = [plan, injury_preset, injury_divisor]
	key.append_array(missing_locations)
	if _injury_profile == null or key != _injury_profile_key:
		_injury_profile = InjuryProfile.build(plan, injury_preset, missing_locations, injury_divisor)
		_injury_profile_key = key
	return _injury_profile


## Which ItemInstance (if any) this unit currently has equipped in the
## named EquipSlot — see UnitEquipment.
func get_equipped_item(slot_key: EquipSlot.Slot) -> ItemInstance:
	return _equipment.get_item(slot_key)


## Every slot currently holding an item — see UnitEquipment.equipped_slots().
func get_equipped_slots() -> Array:
	return _equipment.equipped_slots()


## See UnitEquipment.hands_allow().
func hands_allow(slot_key: EquipSlot.Slot, item: ItemInstance) -> bool:
	return _equipment.hands_allow(slot_key, item)


## Encumbrance — see UnitEquipment.encumbrance_level() and its siblings.
func worn_weight() -> float:
	return _equipment.worn_weight()


func basic_lift() -> float:
	return _equipment.basic_lift()


func encumbrance_level() -> int:
	return _equipment.encumbrance_level()


func weight_allows(slot_key: EquipSlot.Slot, item: ItemInstance) -> bool:
	return _equipment.weight_allows(slot_key, item)


func equip_item(slot_key: EquipSlot.Slot, item: ItemInstance) -> void:
	_equipment.equip(slot_key, item)
	equipment_changed.emit(self)


func unequip_item(slot_key: EquipSlot.Slot) -> ItemInstance:
	var item: ItemInstance = _equipment.unequip(slot_key)
	equipment_changed.emit(self)
	return item


# --- Loadout ---------------------------------------------------------
# What the unit can use and how its weapons are shown. Every change here
# ends in loadout_changed, which is the one signal the hotbar and the
# held/sheathed weapon models listen to.

## BG3-style weapon sets. MELEE is set I (MELEE_MAIN_HAND/MELEE_OFF_HAND),
## RANGED is set II (RANGED_MAIN_HAND/RANGED_OFF_HAND). Both sets' attacks
## stay in combat_abilities(); this says which one is in hand, which
## default_ability() attacks with, and which one using the other's attack
## swaps away from. Write through set_active_weapon_set.
var active_weapon_set: AttackRow.Kind = AttackRow.Kind.MELEE
## True: both sets on the back and hip, nothing in hand. Units start
## sheathed; joining a fight draws, leaving one sheathes (see encounter's
## setter), and swapping sets or using a weapon attack draws. Write
## through set_weapons_sheathed.
var weapons_sheathed: bool = true
var _loadout_queued: bool = false


## Makes kind the set in hand. Free — no action, no move. draw: also take
## the weapons out, which choosing a set means everywhere except restoring
## a saved one.
func set_active_weapon_set(kind: AttackRow.Kind, draw: bool = true) -> void:
	if kind != active_weapon_set:
		active_weapon_set = kind
		_queue_loadout_changed()
	if draw:
		set_weapons_sheathed(false)


## The other set, drawn. Free, like set_active_weapon_set.
func swap_weapon_set() -> void:
	var other: AttackRow.Kind = AttackRow.Kind.RANGED if active_weapon_set == AttackRow.Kind.MELEE else AttackRow.Kind.MELEE
	set_active_weapon_set(other)


func set_weapons_sheathed(value: bool) -> void:
	if value == weapons_sheathed:
		return
	weapons_sheathed = value
	_queue_loadout_changed()


## See UnitCombat.weapon_set_of().
func weapon_set_of(ability: Ability) -> int:
	return _combat.weapon_set_of(ability) if _combat else -1


func set_abilities(value: Array[Ability]) -> void:
	abilities = value


## Appends to a fresh copy, never in place — see abilities.
func add_ability(ability: Ability) -> void:
	var next: Array[Ability] = abilities.duplicate()
	next.append(ability)
	abilities = next


## Removes the first occurrence, from a fresh copy. Returns whether it
## was there.
func remove_ability(ability: Ability) -> bool:
	if not abilities.has(ability):
		return false
	var next: Array[Ability] = abilities.duplicate()
	next.erase(ability)
	abilities = next
	return true


func set_natural_attacks(value: Array[AttackRow]) -> void:
	natural_attacks = value


## Appends to a fresh copy, never in place — see natural_attacks.
func add_natural_attack(row: AttackRow) -> void:
	var next: Array[AttackRow] = natural_attacks.duplicate()
	next.append(row)
	natural_attacks = next


func set_custom_slots(value: Array[Ability]) -> void:
	custom_slots = value


## One custom hotbar slot; null empties it. An index past the end is
## refused, not grown into: the slot count is authored (see custom_slots).
func set_custom_slot(index: int, ability: Ability) -> void:
	if index < 0 or index >= custom_slots.size():
		push_warning("Unit '%s': no custom slot %d" % [name, index])
		return
	if custom_slots[index] == ability:
		return
	var next: Array[Ability] = custom_slots.duplicate()
	next[index] = ability
	custom_slots = next


## Coalesces every change in a frame into one loadout_changed at its end.
## Nothing before ready: exported values arriving while a scene loads are
## the starting state, not changes, and nothing is listening yet anyway.
func _queue_loadout_changed() -> void:
	if not is_node_ready() or _loadout_queued:
		return
	_loadout_queued = true
	_emit_loadout_changed.call_deferred()


func _emit_loadout_changed() -> void:
	_loadout_queued = false
	loadout_changed.emit(self)


## See UnitCombat.combat_abilities().
func combat_abilities() -> Array[Ability]:
	return _combat.combat_abilities()


## See UnitCombat.attack_rows().
func attack_rows(kind: AttackRow.Kind) -> Array[AttackRow]:
	return _combat.attack_rows(kind)


## See UnitCombat.attack_hits().
func attack_hits() -> int:
	return _combat.attack_hits()


## See UnitCombat.shots_left().
func shots_left(ability: Ability) -> int:
	return _combat.shots_left(ability)


## See UnitCombat.reload_all().
func reload_all() -> int:
	return _combat.reload_all()


## See UnitCombat.block_target().
func block_target() -> int:
	return _combat.block_target()


## See UnitCombat.dodge_target().
func dodge_target() -> int:
	return _combat.dodge_target()


## See UnitCombat.parry_target().
func parry_target(attacker: Unit = null) -> int:
	return _combat.parry_target(attacker)


## See UnitCombat.dodge_parts() and its siblings — the defenses'
## breakdowns for the character sheet's tooltips.
func dodge_parts() -> Array[Dictionary]:
	return _combat.dodge_parts()


func parry_parts(attacker: Unit = null) -> Array[Dictionary]:
	return _combat.parry_parts(attacker)


func block_parts() -> Array[Dictionary]:
	return _combat.block_parts()


## See UnitCombat.holds_shield().
func holds_shield() -> bool:
	return _combat.holds_shield()


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
## this moved out of UnitCombat. rng: see SuccessRoll.roll_vs.
func roll_vs(target_number: int, rng: RandomNumberGenerator = null) -> Dictionary:
	return SuccessRoll.roll_vs(target_number, rng)


func attack_skill() -> int:
	return _combat.attack_skill()


## See UnitCombat.hit_chance / to_hit_target / can_dodge.
func hit_chance(target, ability: Ability) -> float:
	return _combat.hit_chance(target, ability)


func to_hit_target(target, ability: Ability) -> int:
	return _combat.to_hit_target(target, ability)


func can_dodge() -> bool:
	return _combat.can_dodge()


func best_defense(attacker: Unit, ability: Ability) -> Dictionary:
	return _combat.best_defense(attacker, ability)


func spend_defense(kind: StringName) -> void:
	_combat.spend_defense(kind)


func status_land_chance(effect: StatusEffect, source: Unit) -> float:
	return _combat.status_land_chance(effect, source)


func default_ability() -> Ability:
	return _combat.default_ability()


## ST-derived swing/thrust damage — see UnitCombat.roll_damage/
## describe_damage for the actual formula. bonus is the caller's own
## flat addition (an ability's authored bonus, or an equipped weapon's
## damage_bonus) — pass 0 for this unit's bare capability.
func roll_damage(damage_type: UnitCombat.DamageType, bonus: int, st: int = 0) -> int:
	return _combat.roll_damage(damage_type, bonus, st)


func describe_damage(damage_type: UnitCombat.DamageType, bonus: int, st: int = 0) -> String:
	return _combat.describe_damage(damage_type, bonus, st)


func max_damage(damage_type: UnitCombat.DamageType, bonus: int, st: int = 0) -> int:
	return _combat.max_damage(damage_type, bonus, st)


## Expected value of roll_damage() without rolling — see UnitCombat.
## expected_damage's own doc comment (AiScorer's reason for existing).
func expected_damage(damage_type: UnitCombat.DamageType, bonus: int, target: Unit = null, wound_type: DamageResolver.WoundType = DamageResolver.WoundType.CRUSHING, armor_divisor: float = 1.0, location: HitLocation = null, st: int = 0) -> float:
	return _combat.expected_damage(damage_type, bonus, target, wound_type, armor_divisor, location, st)


## See UnitCombat's Toggles section.
func is_toggled(toggle: Ability) -> bool:
	return _combat.is_toggled(toggle)


func set_toggled(toggle: Ability, on: bool) -> void:
	_combat.set_toggled(toggle, on)


func aim() -> Ability:
	return _combat.aim()


func set_aim(toggle: Ability, notify: bool = true) -> void:
	_combat.set_aim(toggle, notify)


func hit_location_for(ability: Ability) -> HitLocation:
	return _combat.hit_location_for(ability)


func toggle_level(toggle: Ability) -> int:
	return _combat.toggle_level(toggle)


func set_toggle_level(toggle: Ability, level: int) -> void:
	_combat.set_toggle_level(toggle, level)


func deceptive_level() -> int:
	return _combat.deceptive_level()


func set_deceptive_level(level: int, notify: bool = true) -> void:
	_combat.set_deceptive_level(level, notify)


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
		"stats": stats_to_dict(),
		"transform": global_transform,
		"flight_altitude": flight_target_altitude,
		"move_remaining": move_remaining,
		"has_attacked": has_attacked,
		"parries": _combat.parries,
		"blocked": _combat.blocked,
		"statuses": _status_manager.save_state(),
		"active_weapon_set": active_weapon_set,
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

	stats_from_dict(state.get("stats", {}))
	flight_target_altitude = float(state.get("flight_altitude", flight_target_altitude))
	move_remaining = float(state.get("move_remaining", move_remaining))
	has_attacked = bool(state.get("has_attacked", has_attacked))
	_combat.parries = int(state.get("parries", 0))
	_combat.blocked = bool(state.get("blocked", false))
	_status_manager.load_state(state.get("statuses", []))
	# Restored sheathed: a state from before weapon sets has no key, and
	# drawing is the encounter's to decide, not the save's.
	if state.has("active_weapon_set"):
		set_active_weapon_set(clampi(int(state["active_weapon_set"]), 0, 1) as AttackRow.Kind, false)
	if is_node_ready():
		_update_low_pool_statuses()
	_budget_flying = is_flying()

	if state.has("transform"):
		global_transform = state["transform"]


## critical: a critical hit, which counts double against a Downed unit.
func take_damage(amount: int, critical: bool = false) -> void:
	_combat.take_damage(amount, critical)


## Restores amount HP, clamped at maximum HP. Returns the amount
## ACTUALLY restored (may be less than amount once near/at maximum)
## — see UnitCombat.heal().
func heal(amount: int) -> int:
	return _combat.heal(amount)


## Called by UnitCombat's take_damage() — routed through Unit rather
## than UnitCombat reaching into _status_manager directly, same
## component-talks-to-owner-only rule as UnitMovement's
## notify_movement_idle_check().
func notify_status_of_damage(amount: int, critical: bool = false) -> void:
	_status_manager.notify_damage_taken(amount, critical)


## Called by an attack animation's Call Method Track or a VFX sequence's
## ImpactSignalStep: lands current_action's impact (see AbilityAction).
## Public and directly callable (not routed through a
## component) since the callers here are external to Unit entirely
## (an AnimationPlayer track, a VfxStep), not another owned component.
func notify_impact() -> void:
	if current_action and current_action.impact():
		impact_triggered.emit()


func expire() -> void:
	_death.expire()


## Death cleanup (group/selection/movement/physics teardown, summon
## cascade, queue_free) — see UnitDeath.handle_death(). Public: called
## both by expire() above and by UnitCombat.take_damage() when this
## unit's HP reaches 0 through an actual hit.
##
## This used to also call _selection.teardown() — a dying unit releasing
## its own autoload connection early, because nothing else would. It does
## not need to any more: UnitSelection is a child Node, so the connection
## goes when the node does (queue_free, here or after
## death_cleanup_delay). The window in between is harmless — handle_death
## already deselects and clears the box hover, so a mode change during a
## corpse's death animation recomputes a highlight that is off, against a
## unit that is still perfectly valid.
func handle_death() -> void:
	_death.handle_death()
