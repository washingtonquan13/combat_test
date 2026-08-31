extends HBoxContainer
## Builds and keeps the initiative order row in sync with
## CombatManager.turn_order. HBoxContainer is exactly the right node for
## this level (unlike a single portrait's internal layers — see
## unit_portrait.gd) since here you genuinely want automatic side-by-side
## flow layout for however many combatants are in the row.
##
## Scene setup: attach this script to an HBoxContainer anywhere in your
## combat UI. Assign portrait_scene to unit_portrait.tscn (a Button root
## with unit_portrait.gd attached, exposing a `unit` property and
## set_highlighted()) — shared with party_panel.gd, not turn-order-specific
## despite living in this file's own vocabulary.
##
## Resyncs on every turn_started rather than trying to special-case each
## kind of change (a delay_turn reorder, a death, a normal advance) —
## turn_started already fires after all of those, so reading
## CombatManager.turn_order fresh each time and reordering children to
## match it is simpler and can't drift out of sync with whatever actually
## changed it.

@export var portrait_scene: PackedScene
## Applied to every portrait regardless of how many are in the row —
## this row's own "don't overpower the rest of the UI" baseline size,
## independent of the dynamic crowding shrink below. 0.75 = 25% smaller
## than a portrait's own authored size (see unit_portrait.tscn), the
## size it'd otherwise render at with only a handful of combatants (too
## few to ever trigger the width-based shrink on its own).
@export var base_scale: float = 0.75
## The row's own target width cap — as combatants are added beyond what
## fits at each portrait's authored size, every portrait shrinks UNIFORMLY
## (both axes by the same factor, see unit_portrait.gd's set_fit_scale/
## _fit_scale) so the whole row still fits within this width instead of
## running off-screen for a large combat, without ever distorting an
## individual portrait's aspect ratio. Combines multiplicatively with
## base_scale above — never scales UP past base_scale itself, only
## shrinks further from there to make room for a crowded row.
@export var max_total_width: float = 800.0

var _slots: Dictionary = {}  # Unit -> Control (the instanced portrait)


func _ready() -> void:
	CombatManager.combat_started.connect(_on_combat_started)
	CombatManager.turn_started.connect(_on_turn_started)
	CombatManager.combat_ended.connect(_on_combat_ended)
	CombatManager.unit_joined_combat.connect(_on_unit_joined_combat)
	# Which fight this row is about changes when the SELECTION changes,
	# not only when a fight starts — commanding a party member who is not
	# in the battle should not leave somebody else's initiative order on
	# screen, and with a split party that order can belong to another
	# world entirely.
	SelectionManager.selection_changed.connect(_on_selection_changed)


## The fight the COMMANDED unit is in, or null when it is not in one.
##
## Unit.encounter, not CombatManager.turn_order: the latter is the
## FOCUSED encounter's order, which has nothing to do with whoever the
## player is actually directing. Reads the selection rather than
## PlayerInteractionState.get_active_unit() on purpose — during an enemy
## turn there is no commandable unit, but the player is still watching
## that fight and the row should stay.
func _commanded_encounter() -> Encounter:
	# A SELECTION is an opinion: if the player has picked somebody, this
	# row is about their fight, and about nothing if they are not in one.
	# That is what keeps commanding a straggler mid-battle from leaving
	# somebody else's initiative order on screen.
	if not SelectionManager.selected_units.is_empty():
		for unit in SelectionManager.selected_units:
			if is_instance_valid(unit) and unit.encounter and unit.encounter.is_running:
				return unit.encounter
		return null

	# NO selection is no opinion, which is not the same thing. Travelling
	# clears the selection, so a group that walks into a fight and joins it
	# had nothing selected and no row appeared until the player clicked
	# somebody — with a battle already running in front of them.
	return _party_fight_on_screen()


## A running fight in the world on screen that the party is actually in.
## Deliberately not "any fight here": a brawl between two NPC factions
## the player is watching is not their initiative order.
func _party_fight_on_screen() -> Encounter:
	var context: WorldContext = WorldManager.context()
	for unit in PartyManager.members:
		if not is_instance_valid(unit) or unit.encounter == null:
			continue
		if not unit.encounter.is_running:
			continue
		if context and not context.contains(unit):
			continue
		return unit.encounter
	return null


## turn_order, minus anyone already freed, as a PLAIN array.
##
## turn_order can hold a combatant freed but not yet pruned — a death
## and the fight's own bookkeeping need not land in the same frame. Two
## hazards follow, and both are errors at the CALL rather than something
## a guard inside could catch: _add_slot takes a typed Unit, which
## rejects a freed object before its body runs, and TypedArray.has()
## rejects one outright. Reported from play as a crash while clicking
## quickly during a fight.
##
## Plain Array, not Array[Unit], on purpose: the point is to stop the
## static Unit type travelling with these values into calls that will
## re-validate it.
func _live_turn_order(encounter: Encounter) -> Array:
	var live: Array = []
	for unit in encounter.turn_order:
		if is_instance_valid(unit):
			live.append(unit)
	return live


func _refresh() -> void:
	var encounter: Encounter = _commanded_encounter()
	if encounter == null:
		_clear_all()
		visible = false
		return

	var live: Array = _live_turn_order(encounter)

	for unit in _slots.keys():
		if is_instance_valid(unit) and live.has(unit):
			continue
		var stale: Control = _slots[unit]
		_slots.erase(unit)
		if is_instance_valid(stale):
			stale.queue_free()

	for unit in live:
		if not _slots.has(unit):
			_add_slot(unit)

	visible = true
	_sync_order()
	_update_highlight()


func _on_selection_changed(_selected_units: Array[Unit]) -> void:
	_refresh()


func _on_combat_started(_turn_order: Array[Unit]) -> void:
	_refresh()


func _on_turn_started(_unit: Unit) -> void:
	_refresh()


func _on_combat_ended(_winning_faction: StringName) -> void:
	_clear_all()


## A unit joining a fight already in progress (a summon, most likely —
## see CombatManager.unit_joined_combat) — _add_slot() alone would just
## append its portrait to the end of the row regardless of where it
## actually landed in turn_order, so _sync_order() runs right after to
## place it correctly immediately rather than leaving it visually
## misordered until whatever the next natural turn_started happens to be.
## A full refresh, not just a slot. Somebody joining can be the moment
## this row becomes relevant at all — a group walking into a fight makes
## it the party's fight — and adding one portrait to a row that is not
## being shown changes nothing.
func _on_unit_joined_combat(_unit: Unit) -> void:
	_refresh()


func _add_slot(unit: Unit) -> void:
	if not portrait_scene:
		return

	var slot: Control = portrait_scene.instantiate()
	# unit must be assigned BEFORE add_child — add_child triggers the
	# slot's _ready() synchronously, and unit_portrait.gd's
	# _ready() reads unit immediately (portrait texture, signal hookups).
	# Setting it after add_child means _ready() already ran and bailed
	# out on a still-null unit by the time this line executes.
	slot.unit = unit
	add_child(slot)
	_slots[unit] = slot

	if not unit.died.is_connected(_on_unit_died):
		unit.died.connect(_on_unit_died)

	_update_fit_scale()


## Removes the slot the instant its unit dies, rather than waiting for
## the next turn boundary — CombatManager doesn't actually filter a dead
## unit out of turn_order until its next _advance_turn(), which could be
## a full round away if the death happened on someone else's turn, so
## relying on that alone would leave a dead unit's portrait sitting in
## the row for a while after the fact.
func _on_unit_died(unit: Unit) -> void:
	if unit not in _slots:
		return
	var slot: Control = _slots[unit]
	if is_instance_valid(slot):
		slot.queue_free()
	_slots.erase(unit)
	_update_fit_scale()


## Computes one shared scale factor from however many portraits are
## currently in the row and applies it to all of them — a single number
## for the whole row rather than per-portrait, since they need to shrink
## TOGETHER to stay the same size as each other, not independently.
## Accounts for HBoxContainer's own inter-child separation, not just raw
## portrait width, so max_total_width is actually respected rather than
## slightly overshot once separation adds up across many combatants.
func _update_fit_scale() -> void:
	var count: int = _slots.size()
	if count == 0:
		return

	var any_slot: Control = _slots.values()[0]
	if not is_instance_valid(any_slot):
		return

	var base_width: float = any_slot.get_base_min_size().x
	if base_width <= 0.0:
		return

	var separation: float = get_theme_constant("separation")
	var natural_total_width: float = base_width * count + separation * max(count - 1, 0)
	var crowding_scale: float = min(1.0, max_total_width / natural_total_width)
	var scale: float = base_scale * crowding_scale

	for unit in _slots:
		var slot: Control = _slots[unit]
		if is_instance_valid(slot):
			slot.set_fit_scale(scale)


func _sync_order() -> void:
	var encounter: Encounter = _commanded_encounter()
	if encounter == null:
		return
	for i in encounter.turn_order.size():
		var unit: Unit = encounter.turn_order[i]
		if is_instance_valid(unit) and unit in _slots:
			move_child(_slots[unit], i)


func _update_highlight() -> void:
	for unit in _slots:
		var slot: Control = _slots[unit]
		if not is_instance_valid(slot) or not is_instance_valid(unit):
			continue
		var encounter: Encounter = _commanded_encounter()
		slot.set_highlighted(encounter != null and unit == encounter.current_unit)


func _clear_all() -> void:
	for unit in _slots:
		var slot: Control = _slots[unit]
		if is_instance_valid(slot):
			slot.queue_free()
	_slots.clear()
