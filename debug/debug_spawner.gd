extends Node
## Autoload singleton. Register as "DebugSpawner" under Project > Project
## Settings > AutoLoad.
##
## Tracks which UnitDefinition + faction is currently "armed" for the
## debug spawn panel's click-to-place flow (see debug_spawn_panel.gd) —
## same "arm now, resolve on the next click" shape as AbilityManager,
## deliberately kept fully separate from it: a debug spawn has no
## caster, no turn-economy cost, and must work whether or not combat is
## even running, none of which AbilityManager's model assumes.
##
## Debug-only by construction, not by a guard here — armed_definition
## can only ever be set by DebugSpawnPanel, itself gated end-to-end on
## OS.is_debug_build(). Nothing here re-checks that, same as
## AbilityManager doesn't re-check who's allowed to arm it.
##
## Claims its click by PUSHING a SpawningIntent onto the world's
## ClickRouter (see arm()/disarm() below and debug/spawning_intent.gd,
## which carries the full reasoning for why this is not its own
## _input()). The router derives player intent from one place; a debug
## tool wanting the next click says so by pushing an intent, and the
## router's own aiming/move behaviour is simply outranked while it is
## there. Nothing in systems/ names this file.

signal armed_changed(definition: UnitDefinition, faction: StringName)

var armed_definition: UnitDefinition = null
var armed_faction: StringName = &"enemy"


## The pushed intent, built once and reused: pushing the SAME object
## every time is what lets pop_intent find it again, and the router
## refuses a duplicate push outright.
var _intent: SpawningIntent = null


## Arms definition/faction and pushes the spawn intent onto the world's
## click router (see ClickRouter.push_intent) so the next left/right
## click resolves the spawn instead of a normal move/select. Warns and
## does nothing (stays unarmed) if no router exists yet in the tree —
## only possible if something arms this before MainRoot/the world has
## loaded.
func arm(definition: UnitDefinition, faction: StringName) -> void:
	var router: Node = get_tree().get_first_node_in_group(&"click_router")
	if not router:
		push_warning("DebugSpawner.arm() called before a click_router exists in the tree.")
		armed_changed.emit(null, faction)
		return

	# Re-arming while armed must not leave a second copy pushed: the
	# survivor would swallow every click for the rest of the session with
	# a null definition. (push_intent refuses a duplicate of the same
	# object anyway — this keeps the arm/disarm pairing honest regardless.)
	if armed_definition != null:
		disarm()
	armed_definition = definition
	armed_faction = faction
	if _intent == null:
		_intent = SpawningIntent.new(self)
	router.push_intent(_intent)
	armed_changed.emit(definition, faction)


func disarm() -> void:
	if armed_definition == null:
		return
	var router: Node = get_tree().get_first_node_in_group(&"click_router")
	if router and _intent:
		router.pop_intent(_intent)
	armed_definition = null
	armed_changed.emit(null, armed_faction)


## Spawns the currently armed UnitDefinition at ground_point, joining
## active combat if one's running (CombatManager.add_unit_to_combat
## no-ops out of combat). See SummonDemonEffect.apply() for the pattern
## this simplifies from. Disarms first — see SpawningIntent's own header
## for why a miss stays armed while a landed spawn does not. Called by
## SpawningIntent, hence public.
func spawn_at(ground_point: Vector3) -> void:
	var definition: UnitDefinition = armed_definition
	var faction: StringName = armed_faction
	disarm()

	var spawned: Unit = definition.unit_scene.instantiate()
	# .definition's cascade sets faction = definition.faction as part of
	# the same assignment — the override below must come AFTER, or the
	# panel's chosen faction gets silently overwritten back to the
	# species default the instant .definition is assigned.
	spawned.definition = definition
	spawned.faction = faction
	if faction == &"enemy":
		# hover_color/selected_color aren't part of the .definition cascade
		# (see UnitDefinition's header) and default to Unit's own
		# yellow-gold — correct for a friendly spawn (every player-faction
		# unit in main.tscn leaves these unset too), wrong for a hostile
		# one. Every hand-authored hostile uses exactly this red, so match
		# it here instead of leaving debug spawns looking friendly.
		spawned.hover_color = Color(1, 0, 0, 0.501961)
		spawned.selected_color = Color(1, 0, 0, 0.627451)
	WorldManager.spawn_parent().add_child(spawned)
	spawned.global_position = ground_point

	# Whatever fight is running where it was spawned, if any. Passed
	# nothing, this used to fall back to the fight on screen and enrol a
	# freshly spawned unit in a battle in a completely different area.
	CombatManager.add_unit_to_combat(
		spawned, null, CombatManager.running_encounter_in_world_of(spawned))

	if faction == &"player":
		# party_panel.gd listens to PartyManager.member_added directly and
		# picks this up on its own — no separate registration call needed
		# (that used to be true, back when the panel only ever scanned
		# once at boot; not anymore, see that file's own _ready() header).
		PartyManager.add_member(spawned)
