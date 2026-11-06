extends Control
## The combat dock: the selected (or acting) unit's HP/FP globes, its
## move budget, a panel of ability slots and the End Turn button, laid out
## bottom-centre in dock.tscn.
##
## Panel rows:
##   PINNED   - the weapon set in hand (SetBox, swap with SwapButton or F),
##              that set's attacks, the other set's attacks dimmed (using
##              one swaps; the Unit does that), then the attack-option
##              toggles every unit has (UnitCombat.AIM_TOGGLES,
##              DECEPTIVE_ATTACK) as round slots.
##   PAGE     - everything else from unit.combat_abilities(), then
##              unit.custom_slots, COLUMNS to a row, as many rows as that
##              takes. `visible_rows` of them show at once (1-4, set by
##              dragging Grip); the wheel or the pager moves through them.
##
## Hotkeys 1-0 then Shift+1-0 go to the pinned attacks, then the visible
## page slots, in order. A key already bound to an InputMap action keeps
## that action.
##
## Which unit: the acting unit when a player turn starts in the world on
## screen, otherwise the first selected unit in that world (_in_view).
## Out of combat abilities still work - no turn economy applies there -
## and the dock is only dimmed.
##
## The slots are rebuilt from Unit.loadout_changed and nothing else; the
## other unit signals only refresh state (armed, on, disabled, pools).
##
## Visibility: Globes and BarColumn are shown while there is a unit to
## show. EndTurnHolder sits beside them but its button runs its own
## visibility (end_turn_button.gd).

const SLOT_SCENE: PackedScene = preload("res://ui/hotbar/dock_slot.tscn")
const COLUMNS: int = 10
const MAX_ROWS: int = 4
## Pixels of Grip drag per row.
const ROW_PITCH: float = 44.0

## Page rows shown at once. Static: a player preference, kept while the
## game runs (there is no settings file to keep it in yet).
static var visible_rows: int = 1

@export var dim_modulate: Color = Color(0.82, 0.82, 0.82, 0.8)

@onready var _globes: Control = %Globes
@onready var _hp_globe: TextureRect = %HpGlobe
@onready var _hp_label: Label = %HpLabel
@onready var _fp_globe: TextureRect = %FpGlobe
@onready var _fp_label: Label = %FpLabel
@onready var _bar_column: Control = %BarColumn
@onready var _move_box: Control = %MoveBox
@onready var _move_label: RichTextLabel = %MoveLabel
@onready var _move_bar: ProgressBar = %MoveBar
@onready var _grip: Control = %Grip
@onready var _set_numeral: Label = %SetNumeral
@onready var _set_icon_main: TextureRect = %SetIconMain
@onready var _set_icon_off: TextureRect = %SetIconOff
@onready var _swap_button: Button = %SwapButton
@onready var _attacks: HBoxContainer = %Attacks
@onready var _toggles: HBoxContainer = %Toggles
@onready var _page_grid: GridContainer = %PageGrid
@onready var _pager: Control = %Pager
@onready var _pager_sep: Control = %PagerSep
@onready var _page_up: Button = %PageUp
@onready var _page_down: Button = %PageDown
@onready var _page_label: Label = %PageLabel

var _current_unit: Unit = null
var _slots: Array[DockSlot] = []
var _attack_slots: Array[DockSlot] = []
var _page_slots: Array[DockSlot] = []
var _hotkey_slots: Array[DockSlot] = []
var _row_offset: int = 0
var _grip_start_y: float = 0.0
var _grip_start_rows: int = 1
var _grip_dragging: bool = false
var _default_globe_texture: Texture2D
## Whose pools the globes last showed: a new unit snaps the fill, the same
## unit's damage or healing drains/fills it.
var _globe_unit: Unit = null
var _fill_tweens: Dictionary = {}


func _ready() -> void:
	CombatManager.turn_started.connect(_on_turn_started)
	CombatManager.combat_ended.connect(_on_combat_ended)
	AbilityManager.ability_armed.connect(_on_ability_armed)
	SelectionManager.selection_changed.connect(_on_selection_changed)
	# The world on screen changing can take the displayed unit out of view
	# - see _in_view.
	WorldManager.world_focused.connect(_on_world_focused)

	_swap_button.pressed.connect(_swap_sets)
	_page_up.pressed.connect(_scroll.bind(-1))
	_page_down.pressed.connect(_scroll.bind(1))
	_grip.gui_input.connect(_on_grip_input)
	_default_globe_texture = _hp_globe.texture
	_set_shown(false)


func _set_shown(value: bool) -> void:
	_globes.visible = value
	_bar_column.visible = value


## Whether the player is looking at the world this unit stands in.
## CombatManager relays turn_started for every encounter, watched or not.
## No context at all (a headless harness) counts as in view, matching
## CombatManager._is_watched.
func _in_view(unit: Unit) -> bool:
	if not is_instance_valid(unit):
		return false
	var context: WorldContext = WorldManager.context()
	return context == null or context.contains(unit)


func _on_turn_started(unit: Unit) -> void:
	# Somebody else's fight, somewhere the player is not.
	if not _in_view(unit):
		return
	AbilityManager.disarm()
	_disconnect_current_unit()
	if not unit.is_player_controlled():
		_clear()
		_set_shown(false)
		return
	_show_unit(unit)


func _on_combat_ended(_winning_faction: StringName) -> void:
	AbilityManager.disarm()
	_disconnect_current_unit()
	_clear()
	_set_shown(false)
	# Fall back to whatever is selected now rather than sitting hidden
	# until the next selection change.
	_refresh_from_selection()


func _on_selection_changed(_selected_units: Array[Unit]) -> void:
	_refresh_from_selection()


## The first selected unit in this world, in or out of a fight. The same
## unit again is rebuilt without disarming: whatever changed its
## loadout while it was on the bar already said so through
## loadout_changed, but rebuilding is cheap and never shows stale slots.
func _refresh_from_selection() -> void:
	var unit: Unit = null
	for candidate in SelectionManager.selected_units:
		if _in_view(candidate):
			unit = candidate
			break
	if unit != null and unit == _current_unit:
		_rebuild(unit)
		return
	AbilityManager.disarm()
	_disconnect_current_unit()
	if not unit:
		_clear()
		_set_shown(false)
		return
	_show_unit(unit)


func _show_unit(unit: Unit) -> void:
	_connect_current_unit(unit)
	_row_offset = 0
	_rebuild(unit)
	_set_shown(true)


func _on_world_focused(_world: Node) -> void:
	if _current_unit != null and _in_view(_current_unit):
		return
	AbilityManager.disarm()
	_disconnect_current_unit()
	_clear()
	_set_shown(false)
	_refresh_from_selection()


func _connect_current_unit(unit: Unit) -> void:
	_current_unit = unit
	unit.loadout_changed.connect(_on_loadout_changed)
	unit.ability_used.connect(_on_ability_used)
	unit.toggles_changed.connect(_on_unit_changed)
	# A toggle cast is on while its status is (Ability.on_status), and the
	# status can end with no ability used: expiry, exhaustion.
	unit.status_applied.connect(_on_status_changed)
	unit.status_removed.connect(_on_status_changed)
	unit.pool_changed.connect(_on_pool_changed)
	unit.stat_changed.connect(_on_stat_changed)


func _disconnect_current_unit() -> void:
	var unit: Unit = _current_unit
	_current_unit = null
	if not (unit and is_instance_valid(unit)) or not unit.loadout_changed.is_connected(_on_loadout_changed):
		return
	unit.loadout_changed.disconnect(_on_loadout_changed)
	unit.ability_used.disconnect(_on_ability_used)
	unit.toggles_changed.disconnect(_on_unit_changed)
	unit.status_applied.disconnect(_on_status_changed)
	unit.status_removed.disconnect(_on_status_changed)
	unit.pool_changed.disconnect(_on_pool_changed)
	unit.stat_changed.disconnect(_on_stat_changed)


## An armed weapon attack the new loadout no longer offers is disarmed
## rather than left pointing at a weapon that was put away.
func _on_loadout_changed(unit: Unit) -> void:
	var armed: Ability = AbilityManager.armed_ability
	if armed and armed.effects.any(func(e): return e is GearDamageEffect) \
			and not armed in unit.combat_abilities():
		AbilityManager.disarm()
	_rebuild(unit)


func _on_ability_armed(_ability: Ability) -> void:
	_refresh_state()


func _on_ability_used(_attacker: Unit, _target, _result: Dictionary) -> void:
	# One use can make others unusable too (has_attacked).
	_refresh_state()


func _on_unit_changed(_unit: Unit) -> void:
	_refresh_state()


func _on_status_changed(_unit: Unit, _effect: StatusEffect) -> void:
	_refresh_state()


func _on_pool_changed(_unit: Unit, _id: StringName, _current: int, _maximum: int) -> void:
	_refresh_globes()


func _on_stat_changed(_unit: Unit, _id: StringName) -> void:
	_refresh_globes()


func _rebuild(unit: Unit) -> void:
	_clear()
	var active: int = unit.active_weapon_set
	var others: Array[Ability] = []
	var rest: Array[Ability] = []
	for ability in unit.combat_abilities():
		var weapon_set: int = unit.weapon_set_of(ability)
		if weapon_set == -1:
			rest.append(ability)
		elif weapon_set == active:
			_attack_slots.append(_add_slot(_attacks, unit, ability, DockSlot.Look.WEAPON))
		else:
			others.append(ability)
	for ability in others:
		_attack_slots.append(_add_slot(_attacks, unit, ability, DockSlot.Look.WEAPON, true))

	for toggle in UnitCombat.AIM_TOGGLES:
		_add_slot(_toggles, unit, toggle, DockSlot.Look.ROUND)
	_add_slot(_toggles, unit, UnitCombat.DECEPTIVE_ATTACK, DockSlot.Look.ROUND)

	for ability in rest:
		_page_slots.append(_add_slot(_page_grid, unit, ability, DockSlot.Look.PLAIN))
	for i in unit.custom_slots.size():
		_page_slots.append(_add_slot(_page_grid, unit, unit.custom_slots[i], DockSlot.Look.PLAIN, false, i))

	_refresh_weapon_set(unit)
	_apply_rows()
	_refresh_state()
	_refresh_globes()


func _add_slot(parent: Control, unit: Unit, ability: Ability, look: DockSlot.Look,
		other_set: bool = false, custom_index: int = -1) -> DockSlot:
	var slot: DockSlot = SLOT_SCENE.instantiate()
	# Before add_child: the slot's _ready() reads them.
	slot.unit = unit
	slot.ability = ability
	slot.look = look
	slot.other_set = other_set
	slot.custom_slot_index = custom_index
	parent.add_child(slot)
	_slots.append(slot)
	return slot


func _refresh_weapon_set(unit: Unit) -> void:
	var melee: bool = unit.active_weapon_set == AttackRow.Kind.MELEE
	_set_numeral.text = "I" if melee else "II"
	var main_item: ItemInstance = unit.get_equipped_item(
		EquipSlot.Slot.MELEE_MAIN_HAND if melee else EquipSlot.Slot.RANGED_MAIN_HAND)
	var off_item: ItemInstance = unit.get_equipped_item(
		EquipSlot.Slot.MELEE_OFF_HAND if melee else EquipSlot.Slot.RANGED_OFF_HAND)
	_set_icon_main.texture = main_item.definition.icon if main_item and main_item.definition else null
	_set_icon_off.texture = off_item.definition.icon if off_item and off_item.definition else null
	_set_icon_off.visible = _set_icon_off.texture != null


func _swap_sets() -> void:
	if _current_unit and is_instance_valid(_current_unit):
		_current_unit.swap_weapon_set()


func _refresh_state() -> void:
	for slot in _slots:
		if is_instance_valid(slot):
			slot.refresh_state()
	var dimmed: bool = _current_unit != null and not _current_unit.in_combat()
	var tint: Color = dim_modulate if dimmed else Color.WHITE
	_globes.modulate = tint
	_bar_column.modulate = tint


func _refresh_globes() -> void:
	var unit: Unit = _current_unit
	if not unit or not is_instance_valid(unit):
		return
	var portrait: Texture2D = unit.portrait_texture if unit.portrait_texture else _default_globe_texture
	if _hp_globe.texture != portrait:
		_hp_globe.texture = portrait
		_cover_square(_hp_globe.material, portrait)
	var hp: int = unit.get_pool(StatIds.HP)
	var hp_max: int = maxi(floori(unit.get_stat(StatIds.HP)), 1)
	_hp_label.text = "%d / %d" % [hp, hp_max]
	var snap: bool = unit != _globe_unit
	_globe_unit = unit
	_set_fill(_hp_globe, clampf(float(hp) / hp_max, 0.0, 1.0), snap)
	var fp: int = unit.get_pool(StatIds.FP)
	var fp_max: int = maxi(floori(unit.get_stat(StatIds.FP)), 1)
	_fp_label.text = str(fp)
	_set_fill(_fp_globe, clampf(float(fp) / fp_max, 0.0, 1.0), snap)
	_fp_globe.tooltip_text = "Fatigue Points %d / %d" % [fp, fp_max]
	_hp_globe.tooltip_text = "Hit Points %d / %d" % [hp, hp_max]


func _set_fill(globe: TextureRect, value: float, snap: bool) -> void:
	var material: ShaderMaterial = globe.material
	var old: Tween = _fill_tweens.get(globe)
	if old:
		old.kill()
	var from: float = material.get_shader_parameter("fill")
	if snap or is_equal_approx(from, value):
		material.set_shader_parameter("fill", value)
		return
	var tween: Tween = create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.tween_method(func(f: float) -> void: material.set_shader_parameter("fill", f),
			from, value, 0.45)
	_fill_tweens[globe] = tween


## Crops a texture to its centred square (a tall one nearer its top,
## where a portrait's face is) through globe.gdshader's uv_scale/offset.
static func _cover_square(material: ShaderMaterial, texture: Texture2D) -> void:
	var size: Vector2 = texture.get_size() if texture else Vector2.ONE
	var side: float = minf(size.x, size.y)
	var scale := Vector2(side / size.x, side / size.y)
	var offset := Vector2((1.0 - scale.x) * 0.5, (1.0 - scale.y) * 0.2)
	material.set_shader_parameter("uv_scale", scale)
	material.set_shader_parameter("uv_offset", offset)


## The move budget left this turn. Polled: move_remaining has no signal.
## It is charged only when a walk ends, so the cost walked so far is
## taken off here to drain the bar as the unit goes.
func _process(_delta: float) -> void:
	var unit: Unit = _current_unit
	var show_move: bool = _bar_column.visible and unit != null and is_instance_valid(unit) and unit.in_combat()
	_move_box.modulate.a = 1.0 if show_move else 0.0
	if not show_move:
		return
	var total: float = maxf(unit.move_per_turn(), 0.001)
	var left: float = clampf(unit.move_remaining - unit.move_cost_walked(), 0.0, total)
	_move_bar.value = left / total
	var text: String = "Move [color=#f2d48a]%s[/color] / %s m" % [_metres(left), _metres(total)]
	if _move_label.text != text:
		_move_label.text = text


static func _metres(value: float) -> String:
	var tenths: int = roundi(value * 10.0)
	return str(tenths / 10) if tenths % 10 == 0 else "%.1f" % (tenths / 10.0)


## Shows the page rows from _row_offset on, visible_rows of them, and
## renumbers the hotkeys to match.
func _apply_rows() -> void:
	var total_rows: int = maxi(ceili(float(_page_slots.size()) / COLUMNS), 1)
	var shown: int = mini(visible_rows, total_rows)
	var positions: int = total_rows - shown + 1
	_row_offset = clampi(_row_offset, 0, positions - 1)
	for i in _page_slots.size():
		var row: int = i / COLUMNS
		_page_slots[i].visible = row >= _row_offset and row < _row_offset + shown
	_page_grid.visible = not _page_slots.is_empty()
	_pager.visible = positions > 1
	_pager_sep.visible = _pager.visible
	_page_label.text = "%d/%d" % [_row_offset + 1, positions]
	_page_up.disabled = _row_offset == 0
	_page_down.disabled = _row_offset >= positions - 1
	_assign_hotkeys()


func _scroll(rows: int) -> void:
	_row_offset += rows
	_apply_rows()


func _assign_hotkeys() -> void:
	_hotkey_slots.clear()
	for slot in _attack_slots + _page_slots:
		if slot.visible:
			_hotkey_slots.append(slot)
	for slot in _slots:
		var index: int = _hotkey_slots.find(slot)
		slot.set_key_text(_key_name(index) if index >= 0 and index < 20 else "")


static func _key_name(index: int) -> String:
	var digit: String = str((index % 10 + 1) % 10)
	return digit if index < 10 else "⇧" + digit


func _on_grip_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_grip_dragging = event.pressed
		_grip_start_y = event.global_position.y
		_grip_start_rows = visible_rows
		_grip.accept_event()
	elif event is InputEventMouseMotion and _grip_dragging:
		var rows: int = clampi(_grip_start_rows + roundi((_grip_start_y - event.global_position.y) / ROW_PITCH), 1, MAX_ROWS)
		if rows != visible_rows:
			visible_rows = rows
			_apply_rows()
		_grip.accept_event()


## The wheel over the page rows pages them, before the camera can zoom.
## In _input because the slots are Buttons, which stop the wheel from
## reaching any parent's gui_input.
func _input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton and event.pressed and _page_grid.is_visible_in_tree()):
		return
	if event.button_index != MOUSE_BUTTON_WHEEL_UP and event.button_index != MOUSE_BUTTON_WHEEL_DOWN:
		return
	if not _page_grid.get_global_rect().grow(4.0).has_point(event.position):
		return
	if _pager.visible:
		_scroll(-1 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1)
	get_viewport().set_input_as_handled()


func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	if not _bar_column.is_visible_in_tree() or not _current_unit:
		return
	if event.ctrl_pressed or event.alt_pressed or event.meta_pressed:
		return
	if _bound_elsewhere(event):
		return
	var key: Key = event.physical_keycode
	if key == KEY_F and not event.shift_pressed:
		_swap_sets()
		get_viewport().set_input_as_handled()
		return
	if key < KEY_0 or key > KEY_9:
		return
	var index: int = (key - KEY_1) if key != KEY_0 else 9
	if event.shift_pressed:
		index += 10
	if index < _hotkey_slots.size():
		_hotkey_slots[index].activate()
		get_viewport().set_input_as_handled()


## Whether this exact key is already an InputMap action (the debug
## harness has 1 and 2); that binding wins.
static func _bound_elsewhere(event: InputEvent) -> bool:
	for action in InputMap.get_actions():
		if not String(action).begins_with("ui_") and InputMap.event_is_action(event, action, true):
			return true
	return false


func _clear() -> void:
	for slot in _slots:
		if is_instance_valid(slot):
			slot.get_parent().remove_child(slot)
			slot.queue_free()
	_slots.clear()
	_attack_slots.clear()
	_page_slots.clear()
	_hotkey_slots.clear()
