extends HBoxContainer
## Builds and keeps the initiative order row in sync with
## CombatManager.turn_order. HBoxContainer is exactly the right node for
## this level (unlike a single portrait's internal layers — see
## initiative_portrait.gd) since here you genuinely want automatic
## side-by-side flow layout for however many combatants are in the row.
##
## Scene setup: attach this script to an HBoxContainer anywhere in your
## combat UI. Assign portrait_scene to the PortraitSlot scene (a Control
## root with initiative_portrait.gd attached, exposing a `unit` property
## and set_highlighted()).
##
## Resyncs on every turn_started rather than trying to special-case each
## kind of change (a delay_turn reorder, a death, a normal advance) —
## turn_started already fires after all of those, so reading
## CombatManager.turn_order fresh each time and reordering children to
## match it is simpler and can't drift out of sync with whatever actually
## changed it.

@export var portrait_scene: PackedScene
## The row's own target width cap — as combatants are added beyond what
## fits at each portrait's authored size, every portrait shrinks UNIFORMLY
## (both axes by the same factor, see initiative_portrait.gd's
## set_fit_scale/_fit_scale) so the whole row still fits within this
## width instead of running off-screen for a large combat, without ever
## distorting an individual portrait's aspect ratio. Never scales UP past
## 1.0 — a small combat still shows portraits at their normal authored
## size, this only ever shrinks to make room.
@export var max_total_width: float = 800.0

var _slots: Dictionary = {}  # Unit -> Control (the instanced portrait)


func _ready() -> void:
	CombatManager.combat_started.connect(_on_combat_started)
	CombatManager.turn_started.connect(_on_turn_started)
	CombatManager.combat_ended.connect(_on_combat_ended)
	CombatManager.unit_joined_combat.connect(_on_unit_joined_combat)


func _on_combat_started(turn_order: Array[Unit]) -> void:
	_clear_all()
	for unit in turn_order:
		_add_slot(unit)
	_sync_order()


func _on_turn_started(_unit: Unit) -> void:
	_sync_order()
	_update_highlight()


func _on_combat_ended(_winning_faction: StringName) -> void:
	_clear_all()


## A unit joining a fight already in progress (a summon, most likely —
## see CombatManager.unit_joined_combat) — _add_slot() alone would just
## append its portrait to the end of the row regardless of where it
## actually landed in turn_order, so _sync_order() runs right after to
## place it correctly immediately rather than leaving it visually
## misordered until whatever the next natural turn_started happens to be.
func _on_unit_joined_combat(unit: Unit) -> void:
	_add_slot(unit)
	_sync_order()


func _add_slot(unit: Unit) -> void:
	if not portrait_scene:
		return

	var slot: Control = portrait_scene.instantiate()
	# unit must be assigned BEFORE add_child — add_child triggers the
	# slot's _ready() synchronously, and initiative_portrait.gd's
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
	var scale: float = min(1.0, max_total_width / natural_total_width)

	for unit in _slots:
		var slot: Control = _slots[unit]
		if is_instance_valid(slot):
			slot.set_fit_scale(scale)


func _sync_order() -> void:
	for i in CombatManager.turn_order.size():
		var unit: Unit = CombatManager.turn_order[i]
		if unit in _slots:
			move_child(_slots[unit], i)


func _update_highlight() -> void:
	for unit in _slots:
		var slot: Control = _slots[unit]
		if not is_instance_valid(slot):
			continue
		slot.set_highlighted(unit == CombatManager.current_unit)


func _clear_all() -> void:
	for unit in _slots:
		var slot: Control = _slots[unit]
		if is_instance_valid(slot):
			slot.queue_free()
	_slots.clear()
