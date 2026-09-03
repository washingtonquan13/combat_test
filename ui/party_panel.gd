class_name PartyPanel
extends VBoxContainer
## Left-edge party display — always visible in and out of combat, no
## CombatManager gating at all. One row per core party member (a
## player-faction unit that wasn't itself summoned): that member's own
## portrait, followed by a small overlapping "hand of cards" fan of
## portrait chips for whatever it currently has summoned — inspired by
## BG3's action-economy fan next to each portrait. Replaces an earlier
## version that gave each summoner a separate text-labeled row below the
## core list ("Kael's summons — 3"); that Button's text-driven width
## could exceed the panel's own narrow column and spill out sideways,
## which is exactly the "too much horizontal real estate" this fan
## design fixes — a fan only grows by (chip width - overlap) per
## additional summon, not a full new row's worth of width, and there's
## no text at all left to overflow.
##
## Renders from live PartyManager.members when a world spawns the party
## (every world except the overworld today), and from PartyManager.roster
## — plain PartyMemberData, no live Unit at all — when it doesn't (see
## _on_world_loaded()). unit_portrait.gd's own data export is what makes
## a single portrait component serve both cases.
##
## Scene setup: VBoxContainer root placed directly under CanvasLayer,
## left-anchored — same convention AbilityHotbar/InitiativeRow already
## use (script attached straight to a Control in main.tscn, no wrapper
## scene). One child: CoreContainer (VBoxContainer, empty — populated at
## runtime with one HBoxContainer row per core unit). Assign slot_scene
## to unit_portrait.tscn — the same shared portrait/click-to-select
## component initiative_row.gd uses, instanced directly with no wrapper
## scene around it, for BOTH the core portrait and every summon chip in
## its fan.
##
## Lives inside PartyRail — a bare full-rect Control, SIBLING of
## TacticalUI (see MainRoot.tscn) — rather than inside TacticalUI itself.
## PartyRail, not this node, is what UIStack.register_party_rail()
## receives and toggles: the rest of the tactical HUD (initiative row,
## hotbar, end-turn button, system log) goes down whenever any open
## UIScreen sets hides_hud, but the party rail only goes down when that
## screen does NOT also set keeps_party_visible — see UIStack's own
## _any_screen_hides_party_rail(). DialogueOverlay sets hides_hud=true
## AND keeps_party_visible=true in MainRoot.tscn, so a conversation
## blanks the rest of the HUD while this panel stays visible and
## clickable.
##
## THIS PANEL'S OWN `visible` IS NOT WHAT UIStack TOGGLES. This node
## already drives its own visible flag independently — see
## _update_visibility() below, hidden whenever the party has no rows at
## all. If UIStack wrote to THIS node's visible instead of PartyRail's,
## that would be two independent owners of one flag: a conversation
## ending could force this panel back on even if the party happened to
## be empty at that instant, or the emptiness check could stomp
## whatever UIStack had just set. Toggling an ANCESTOR (PartyRail)
## instead means is_visible_in_tree() is correctly the AND of both
## reasons — the same relationship TacticalUI already has to everything
## nested inside it, just narrowed to this one child via its own wrapper
## rather than applying to the whole HUD.

@export var slot_scene: PackedScene
## Uniform size multiplier for a core member's own portrait, relative to
## its authored size in unit_portrait.tscn (Vector2(80, 100)) — 0.52
## lands right at the approved mockup's 52px-tall portrait for this rail.
## Kept as its own export (rather than the old bare 0.5 literal in
## _add_core_slot/_add_data_slot) so the rail's portrait size can be
## tuned live in the inspector the same way summon_chip_scale already is.
@export var core_portrait_scale: float = 0.52
## Uniform size multiplier for summon chips relative to their authored
## size in unit_portrait.tscn — deliberately smaller than the core
## portrait's own core_portrait_scale (see _add_core_slot) so a fan of
## chips reads as subordinate to the party member that owns it,
## card-hand style.
@export var summon_chip_scale: float = 0.35
## How many pixels each summon chip overlaps the previous one by, via
## negative separation on the fan HBoxContainer — Godot's own container
## layout does the actual overlapping/repacking, both when a chip is
## added and when one is removed, so nothing here ever repositions chips
## by hand. Tune this and summon_chip_scale live in the inspector to get
## the fan reading right — both are just starting points.
@export var summon_fan_overlap: int = 18

@onready var _core_container: VBoxContainer = $CoreContainer

## Keyed by Unit for a spawned world, or by PartyMemberData for a world
## that deliberately doesn't spawn the party (the overworld — see
## PartyManager.roster/WorldManager.spawns_party()). Untyped Dictionary,
## so both key shapes coexist without incident; a given row is always
## exactly one or the other, never both, since a world either spawns the
## party or it doesn't.
var _core_rows: Dictionary = {}  # (Unit | PartyMemberData) -> HBoxContainer
var _summon_fans: Dictionary = {}  # Unit (summoner) -> HBoxContainer (its fan, inside its own row) -- live units only
var _summon_chips: Dictionary = {}  # Unit (summon) -> the unit_portrait Button instance in its summoner's fan


## Reactive to PartyManager's own membership signals rather than a one-
## shot post-boot scan — the panel used to assume its units already
## existed in the same scene by the time a single deferred frame elapsed
## (true back when MainRoot pre-instanced the arena at edit time), which
## stopped holding the moment WorldManager made worlds load asynchronously
## at runtime, well after this panel's own _ready(). PartyManager is the
## single authoritative roster (see that file's own header) and every
## real path that should produce a portrait already calls add_member() —
## the initial bootstrap, a world reload's spawn_party(), and both debug
## spawn tools — so listening to it directly loses no case and closes the
## exact "two independently-drifting mechanisms" gap register_core_unit()
## used to paper over for just the debug-spawn path.
func _ready() -> void:
	visible = false
	PartyManager.member_added.connect(_on_member_added)
	PartyManager.member_removed.connect(_on_member_removed)
	PartyManager.leader_changed.connect(_on_leader_changed)
	WorldManager.world_loading.connect(_on_world_loading)
	WorldManager.world_loaded.connect(_on_world_loaded)
	# Re-entering a world that stayed loaded emits world_focused and NOT
	# world_loaded (nothing was loaded), and a focus switch is exactly when
	# "who is here" changes — so the panel has to listen for both.
	WorldManager.world_focused.connect(_on_world_focused)
	# A fight elsewhere reaching one of our units is the other thing that
	# changes how a row should read — see CombatManager's Attention section.
	CombatManager.attention_changed.connect(_mark_absent_members)
	# The speaking marker — see _on_dialogue_line_shown(). Disconnected in
	# _exit_tree(): this project has a recorded bug class where a widget
	# that connects itself to an AUTOLOAD's signal outlives its own owner,
	# because nothing ever tears the connection down (see
	# refcounted_component_autoload_signal_leak in project memory). No
	# dialogue_started listener needed: it fires before the first line, and
	# every row is already keyed by Unit/PartyMemberData by the time any
	# line_shown reaches _set_speaking_unit() below.
	DialogueManager.line_shown.connect(_on_dialogue_line_shown)
	DialogueManager.dialogue_ended.connect(_on_dialogue_ended)
	# Deferred, same reasoning as before: safe even if this panel is ever
	# constructed after members already exist (e.g. a future scene that
	# doesn't boot through MainRoot at all).
	_rebuild_core.call_deferred()


## See the connect calls in _ready(): a Node that outlives being removed
## from the tree (queue_free's deferred window) would otherwise still be
## a live listener on DialogueManager's signals, and a freed node reached
## through a signal callback is exactly the crash this disconnect exists
## to prevent.
func _exit_tree() -> void:
	if DialogueManager.line_shown.is_connected(_on_dialogue_line_shown):
		DialogueManager.line_shown.disconnect(_on_dialogue_line_shown)
	if DialogueManager.dialogue_ended.is_connected(_on_dialogue_ended):
		DialogueManager.dialogue_ended.disconnect(_on_dialogue_ended)


## Moves the speaking marker (see unit_portrait.gd's set_speaking) to
## whoever's line just showed. DialogueManager.participants maps a
## speaker token ("player"/"npc"/...) to a Unit — resolved fresh per line
## rather than cached, since who "npc" even IS can change conversation to
## conversation. A token with no live Unit (an echo line — see
## DialogueManager.record_line) or a speaker who isn't a party member
## both resolve to null here, which correctly clears every marker instead
## of leaving a stale one lit.
func _on_dialogue_line_shown(_text: String, speaker_token: String) -> void:
	_set_speaking_unit(DialogueManager.participants.get(speaker_token))


## Conversation over — nobody in the party is "speaking" anymore.
func _on_dialogue_ended() -> void:
	_set_speaking_unit(null)


func _set_speaking_unit(speaker) -> void:
	for key in _core_rows:
		var row: Control = _core_rows[key]
		if not is_instance_valid(row) or row.get_child_count() == 0:
			continue
		var portrait: Node = row.get_child(0)
		if portrait.has_method("set_speaking"):
			portrait.set_speaking(speaker != null and key == speaker)


## Every member of every group, in whichever form each group is in.
##
## Was "every live Unit", which silently emptied the panel the moment
## the party could split: a group left behind in another world is still
## a member but produces no member_added (it was never removed), and the
## abstract branch below only ran when NOBODY was embodied. So a split
## party showed nothing at all — and with nothing to click, no way back
## to the half you left.
func _rebuild_core() -> void:
	for entry in PartyManager.everyone():
		if entry is Unit:
			_add_core_slot(entry)
		else:
			_add_data_slot(entry)
	_sort_rows()
	_update_visibility()
	_mark_absent_members()


## Reconciles the rows against PartyManager.everyone() without tearing
## down the ones already right — a full rebuild would destroy each
## summoner's live fan of chips, which nothing would rebuild.
func _sync_rows() -> void:
	var wanted: Array = PartyManager.everyone()

	for key in _core_rows.keys():
		if not wanted.has(key):
			_drop_row(key)

	for entry in wanted:
		if entry in _core_rows:
			continue
		if entry is Unit:
			_add_core_slot(entry)
		else:
			_add_data_slot(entry)

	_sort_rows()
	_update_visibility()
	_mark_absent_members()


## Untyped key: a row is keyed by a Unit or by a PartyMemberData, and
## _remove_core_slot only accepts the first.
func _drop_row(key) -> void:
	if key not in _core_rows:
		return
	var row: Control = _core_rows[key]
	if is_instance_valid(row):
		row.queue_free()
	_core_rows.erase(key)
	_summon_fans.erase(key)


func _on_world_focused(_world: Node) -> void:
	# Not just a re-marking: a focus switch changes which groups are
	# embodied and which are abstract, so rows appear and disappear.
	_sync_rows()


## Dims the members who are standing in some other world. With the party
## together this does nothing at all, which is the normal case — it is the
## readout for a party that has been split up, so the player can see where
## everyone is rather than having to remember.
func _mark_absent_members() -> void:
	var context: WorldContext = WorldManager.context()
	var area: AreaDefinition = WorldManager.current_area()
	for key in _core_rows:
		if not (key is Unit) or not is_instance_valid(key):
			# A record row: whether it is "elsewhere" is a question about
			# its GROUP, since it has no node to locate.
			_mark_record_row(key, area)
			continue
		var row: Node = _core_rows[key]
		if not is_instance_valid(row) or row.get_child_count() == 0:
			continue
		var portrait: Node = row.get_child(0)
		if not portrait.has_method("set_elsewhere"):
			continue
		var elsewhere: bool = context != null and not context.contains(key)
		portrait.set_elsewhere(elsewhere,
			elsewhere and CombatManager.unit_awaiting_attention(key))


func _on_member_added(unit: Unit) -> void:
	_add_core_slot(unit)
	_sort_rows()
	_update_visibility()


func _on_member_removed(unit: Unit) -> void:
	_remove_core_slot(unit)
	_update_visibility()


func _on_leader_changed(_unit: Unit) -> void:
	_sort_rows()


## Fires after a load_world() call fully resolves — including, if the new
## world spawns the party, after every member_added it triggered along
## the way (see WorldManager.load_world()'s own ordering: spawn_party()
## runs, THEN world_loaded emits). So members being non-empty here means
## _on_member_added already built real rows and this has nothing to do;
## members being empty and roster non-empty means the new world opted out
## of spawning (spawns_party() -> false, the overworld) and this is the
## ONLY signal telling the panel to render data-only rows instead.
## Ignores `reason`: the rows describe who is in the party and what world
## they landed in, which is the same question however the world got here.
func _on_world_loaded(_world: Node, _reason: WorldManager.Entry) -> void:
	_sync_rows()


## PartyManager.clear_members() deliberately emits no per-unit signals
## (see that method's own header — nothing needs to react to an
## incremental teardown, since every listener is about to see a whole new
## world instead) — this is what tells the panel to actually let go of
## its own rows before their Units are freed, rather than relying on a
## signal that was never going to fire. Fired at the very start of
## load_world(), before the outgoing world is freed, so every row here is
## still valid at the moment this runs.
func _on_world_loading(_scene: PackedScene) -> void:
	for row in _core_rows.values():
		if is_instance_valid(row):
			row.queue_free()
	_core_rows.clear()
	_summon_fans.clear()
	_summon_chips.clear()
	_update_visibility()


## Moves the leader's row (if any) to the front — the same leader-first
## ordering _rebuild_core() used to only apply via a full sort, now done
## incrementally via move_child() so an add/leader-change never has to
## rebuild every row (which would destroy each summoner's live fan of
## chips built by _register_summon()). Checks PartyManager.leader (a live
## Unit) first; when nothing is spawned (rendering from roster instead —
## see _on_world_loaded), falls back to whichever PartyMemberData record
## has is_leader set, since PartyManager.leader is null the whole time
## the party isn't spawned as real Units at all.
func _sort_rows() -> void:
	var leader: Unit = PartyManager.leader
	if leader and leader in _core_rows:
		_core_container.move_child(_core_rows[leader], 0)
		return

	for record in PartyManager.roster:
		if record.is_leader and record in _core_rows:
			_core_container.move_child(_core_rows[record], 0)
			return


func _add_core_slot(unit: Unit) -> void:
	if not slot_scene or unit in _core_rows:
		return

	var row := HBoxContainer.new()
	_core_container.add_child(row)

	var portrait: Button = slot_scene.instantiate()
	# unit must be assigned BEFORE add_child — add_child triggers the
	# slot's _ready() synchronously, and unit_portrait.gd's _ready()
	# reads unit immediately (portrait texture, signal hookups). Same
	# requirement initiative_row.gd's own _add_slot already follows.
	portrait.unit = unit
	portrait.group = PartyManager.group_of(unit)
	row.add_child(portrait)
	portrait.set_fit_scale(core_portrait_scale)

	var fan := HBoxContainer.new()
	fan.add_theme_constant_override("separation", -summon_fan_overlap)
	row.add_child(fan)

	_core_rows[unit] = row
	_summon_fans[unit] = fan

	if not unit.ability_used.is_connected(_on_core_unit_ability_used):
		unit.ability_used.connect(_on_core_unit_ability_used)


## Data-only counterpart to _add_core_slot() — a portrait rendered from a
## captured PartyMemberData record instead of a live Unit (see
## _on_world_loaded). No summon fan: nothing can be summoned by a unit
## that doesn't currently exist as a real Unit at all.
func _add_data_slot(record: PartyMemberData) -> void:
	if not slot_scene or record in _core_rows:
		return

	var row := HBoxContainer.new()
	_core_container.add_child(row)

	var portrait: Button = slot_scene.instantiate()
	portrait.data = record
	# The route back to a member with no Unit anywhere to click.
	portrait.group = _group_holding(record)
	row.add_child(portrait)
	portrait.set_fit_scale(core_portrait_scale)

	_core_rows[record] = row


## A core unit's own death is not listened to directly — every unit that
## can ever reach _core_rows is (or was) a PartyManager member, and
## PartyManager already connects its own death handler
## (see PartyManager.add_member -> _on_member_died -> remove_member(),
## which emits member_removed) — so _on_member_removed above already
## covers this case. A second direct unit.died listener here would just
## be the same "two independently-drifting mechanisms" problem this whole
## fix exists to close, one signal earlier.
func _remove_core_slot(unit: Unit) -> void:
	if unit not in _core_rows:
		return
	var row: Control = _core_rows[unit]
	if is_instance_valid(row):
		row.queue_free()
	_core_rows.erase(unit)
	_summon_fans.erase(unit)


## Detects a new summon the same way this project already communicates
## "an ability just did something interesting" — checking the
## ability_used result dict rather than adding a dedicated signal.
## SummonEffect.apply() already returns {"summoned": summon}; nothing
## else in this project's effects use that key, so this is unambiguous.
## Fires identically in and out of combat, since ability_used already
## does — no separate out-of-combat handling needed.
func _on_core_unit_ability_used(attacker: Unit, _target, result: Dictionary) -> void:
	# "summoned" is a per-EFFECT key (see SummonEffect.apply), not a
	# top-level one — use_ability() nests every effect's own result
	# dictionary inside result["effects"], it never merges them up a
	# level. Checking result.has("summoned") directly never matched
	# anything, which is why summons weren't appearing.
	for effect_result in result.get("effects", []):
		if not effect_result.has("summoned"):
			continue
		var summon: Unit = effect_result["summoned"]
		if summon and summon.is_player_controlled():
			_register_summon(attacker, summon)


func _register_summon(summoner: Unit, summon: Unit) -> void:
	if not slot_scene or summon in _summon_chips:
		return
	var fan: HBoxContainer = _summon_fans.get(summoner)
	if not fan:
		return

	var chip: Button = slot_scene.instantiate()
	chip.unit = summon
	fan.add_child(chip)
	chip.set_fit_scale(summon_chip_scale)

	_summon_chips[summon] = chip
	summon.died.connect(_on_summon_died, CONNECT_ONE_SHOT)


## Frees just this one summon's own chip — the fan HBoxContainer it lived
## in repacks the remaining chips automatically (that's the point of
## negative separation instead of manually-positioned chips: removal is
## exactly as free as insertion was). No group bookkeeping to refresh
## since nothing here is counted or labeled anymore — the fan's actual
## child count IS the visible count.
func _on_summon_died(summon: Unit) -> void:
	var chip: Control = _summon_chips.get(summon)
	if chip and is_instance_valid(chip):
		chip.queue_free()
	_summon_chips.erase(summon)


func _update_visibility() -> void:
	visible = not _core_rows.is_empty()


func _mark_record_row(key, area: AreaDefinition) -> void:
	var row: Node = _core_rows.get(key)
	if not is_instance_valid(row) or row.get_child_count() == 0:
		return
	var portrait: Node = row.get_child(0)
	if not portrait.has_method("set_elsewhere"):
		return
	var group: PartyGroup = portrait.group
	# Derived: a record can sit in a group whose live members have since
	# walked elsewhere, and the remembered area would then dim the wrong row.
	portrait.set_elsewhere(area == null or group == null
		or group.current_area_id() != area.id)


## Which group currently holds this record. Records live in exactly one
## group, so the first match is the answer.
func _group_holding(record: PartyMemberData) -> PartyGroup:
	for group in PartyManager.groups:
		if group.records.has(record):
			return group
	return null
