extends AiTestCase
## The party you start the game with can actually be seen.
##
## Written because it was NOT true and nothing noticed. `unit.tscn` used to
## carry a body of its own; once every unit started getting its body from
## `UnitDefinition.model_scene`, the four companions hand-placed in
## test_arena.tscn — which set their stats inline and name no definition at
## all — began spawning with no mesh, no skeleton and no animation player.
##
## The whole suite stayed green. A bodiless unit walks, fights, takes
## damage and dies exactly like any other; the only thing wrong with it is
## that you cannot see it, and nothing was asking.
##
## So this asserts through the SCENE TREE — a real MeshInstance3D that is
## really visible — rather than through anything a manager reports. This
## project has shipped a 32/32 green UI suite over invisible panels before.
##
## The goblins are the control. They are authored in the same scene with
## real definitions, so they must pass even on the day the companions fail;
## if they ever fail together, the harness is broken rather than the party.

const HOME := &"test_arena"

var _host: Control
var _saved_host: Control = null
var _saved_attention: Array[Node] = []
var _snapshot: Dictionary = {}


func run() -> void:
	if not _install_synthetic_host():
		check("SETUP: synthetic world host installed", false)
		_restore()
		return

	_snapshot_globals()

	# THE STARTING party, which means the bootstrap path — and reaching it
	# requires an empty slate. test_arena only lays out its four authored
	# companions when WorldManager.is_restoring_party() is false, and that
	# is false only when both the roster and the live members are empty.
	# Earlier suites leave records behind, so without this the area rebuilds
	# whatever they left and this suite quietly measures somebody else's
	# party instead of the one the game starts with.
	PartyManager.clear_members()
	PartyManager.load_state({})

	WorldManager.load_area(HOME)
	await get_tree().process_frame

	var area: AreaDefinition = WorldManager.current_area()
	if area == null or area.id != HOME:
		check("SETUP: the starting area loaded", false,
			"looking at %s" % ("nothing" if area == null else String(area.id)))
		_restore()
		return

	var party: Array[Unit] = []
	for member in PartyManager.members:
		if is_instance_valid(member):
			party.append(member)

	check("SETUP: the starting party exists",
		party.size() >= 4, "%d member(s)" % party.size())

	# The control. Authored in the same scene, but through definitions.
	var enemy: Unit = _find_by_id(&"test_arena_hobgoblin")
	check("CONTROL: an authored enemy has a visible body",
		enemy != null and _visible_mesh_under(enemy) != null,
		"the hobgoblin has no body either — the harness is wrong, not the party")

	var faceless: Array[String] = []
	for member in party:
		if _visible_mesh_under(member) == null:
			faceless.append(member.get_display_name())

	check("every starting party member has a body you can see",
		faceless.is_empty(),
		"invisible: %s — they name no UnitDefinition, so nothing gave them one" % ", ".join(faceless))

	# Separately, because a body arriving with no animation library is a
	# different failure from no body at all, and reads very differently in
	# the game: one is an invisible unit, the other is a T-posed one.
	var mute: Array[String] = []
	for member in party:
		var body := member.get_node_or_null("CharacterModel") as CharacterModel
		var player: AnimationPlayer = body.resolve_animation_player() if body else null
		if player == null or player.get_animation_list().is_empty():
			mute.append(member.get_display_name())

	check("and an animation library to move it with",
		mute.is_empty(), "no clips: %s" % ", ".join(mute))

	_the_companions_kept_who_they_are(party)
	_restore()


## The migration guard for moving the party out of the scene.
##
## These four used to be hand-placed nodes carrying alignment, tendency,
## move_speed, selected_color, a conversation and three trained skills as
## inline properties and child nodes. All of that now lives in
## data/companions/*.tres, and none of it is visible in a body check — a
## companion could come back correctly rendered and completely characterless.
func _the_companions_kept_who_they_are(party: Array[Unit]) -> void:
	var wizard: Unit = _member_named(party, "Tiefling Wizard")
	var ranger: Unit = _member_named(party, "Elf Ranger")
	if wizard == null or ranger == null:
		check("SETUP: the wizard and the ranger are both here", false,
			"the party is not who it should be")
		return

	check("the wizard is still as chaotic as she was authored",
		wizard.alignment == -100 and wizard.tendency == 100,
		"alignment %d, tendency %d — the overworld spin is derived from this" % [
			wizard.alignment, wizard.tendency])

	var levels: Dictionary = {}
	for instance in wizard.get_skills():
		if instance.skill_data:
			levels[instance.skill_data.resource_path.get_file()] = instance.levels_purchased
	check("and kept all three skills she trained",
		levels.size() == 3, "%d skill(s): %s" % [levels.size(), str(levels)])
	check("including the one she put seven levels into",
		levels.get("insight.tres", 0) == 7,
		"insight at %d" % levels.get("insight.tres", 0))

	check("and everyone still walks at the speed they were given",
		is_equal_approx(wizard.move_speed, 5.0),
		"%.2f" % wizard.move_speed)

	check("and the ranger can still be talked to",
		not ranger.dialogue_options.is_empty(),
		"her conversation went missing with her node")


func _member_named(party: Array[Unit], display: String) -> Unit:
	for member in party:
		if member.get_display_name() == display:
			return member
	return null


func _find_by_id(id: StringName) -> Unit:
	for node in get_tree().get_nodes_in_group("units"):
		if node is Unit and (node as Unit).persistent_id == id:
			return node
	return null


## A MeshInstance3D that is actually rendering, found anywhere under the
## unit. Deliberately not "does it have a CharacterModel" — a model node
## that failed to bring a mesh would pass that and still be invisible.
func _visible_mesh_under(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null \
			and (node as MeshInstance3D).is_visible_in_tree():
		return node
	for child in node.get_children():
		var found: MeshInstance3D = _visible_mesh_under(child)
		if found:
			return found
	return null


func _install_synthetic_host() -> bool:
	_saved_host = WorldManager._world_host
	_saved_attention = WorldManager._attention_nodes.duplicate()
	_host = Control.new()
	_root.add_child(_host)
	WorldManager.register_world_host(_host)
	var none: Array[Node] = []
	WorldManager.register_attention_nodes(none)
	return WorldManager.can_travel()


func _snapshot_globals() -> void:
	_snapshot = {
		"flags": FlagManager.save_state(),
		"party": PartyManager.save_state(),
	}


func _restore() -> void:
	WorldManager.discard_worlds()
	if not _snapshot.is_empty():
		FlagManager.load_state(_snapshot["flags"])
		PartyManager.load_state(_snapshot["party"])
	while PartyManager.groups.size() > 1:
		PartyManager.groups[0].absorb(PartyManager.groups[1])
		PartyManager.groups.remove_at(1)
	if not PartyManager.groups.is_empty():
		PartyManager.active_group = PartyManager.groups[0]
	WorldManager._world_host = _saved_host
	WorldManager._attention_nodes = _saved_attention
	if is_instance_valid(_host):
		_host.queue_free()
