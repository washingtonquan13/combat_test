class_name DockSlot
extends BaseButton
## One slot on the combat dock (dock.gd). A BaseButton for clicks and the
## disabled state, drawn in layers rather than by the button itself:
##   Face  - slot_icon.gdshader: a backdrop lit in Ability.icon_color and
##           the icon on it (an ability's glyph recoloured, or a weapon's
##           picture as it is), greyed for the other set or disabled;
##   Frame - the border, one of the styleboxes below per state;
##   then the labels and badges.
## A drag-and-drop SOURCE whenever it holds an
## ability, and a drop TARGET only when it mirrors one of
## unit.custom_slots (is_custom_slot).
##
## The drag payload is the Ability resource itself: the same Ability can
## sit in its home slot and in a custom slot at once, so there is no
## single place to move it from.
##
## Three looks, from `look`, the frames authored as styleboxes in
## dock_slot.tscn:
##   PLAIN  - spells, utility, custom slots (square, thin border);
##   WEAPON - an attack bound to a weapon set's row (bronze frame, the
##            row's damage type in TagLabel); `other_set` dims it and
##            shows SwapBadge, using it swaps sets (the Unit does that);
##   ROUND  - an attack option toggle (aim, Deceptive Attack): a gold ring
##            while on, LevelBadge for its penalty or level.
##
## A toggle (Ability.is_toggle) is switched rather than armed. A leveled
## one (max_level) steps its level on a left click while on, and a right
## click switches it off keeping the level. A toggle cast (on_status,
## Fly) shows ToggleBorder's running line while its status is on.

enum Look { PLAIN, WEAPON, ROUND }

@export var style_plain: StyleBox
@export var style_weapon: StyleBox
@export var style_armed: StyleBox
@export var style_round: StyleBox
@export var style_round_lit: StyleBox
@export var style_empty: StyleBox
## The Face's saturation and brightness for an attack from the set not
## in hand, while disabled, and while hovered.
@export var other_set_saturation: float = 0.35
@export var other_set_brightness: float = 0.55
@export var disabled_saturation: float = 0.0
@export var disabled_brightness: float = 0.45
@export var hover_brightness: float = 1.2
## The Frame's modulate for an attack from the set not in hand.
@export var other_set_frame_modulate: Color = Color(1, 1, 1, 0.5)
## LevelBadge's modulate while its toggle is off.
@export var level_off_modulate: Color = Color(1, 1, 1, 0.45)

var ability: Ability = null
var unit: Unit = null
var look: Look = Look.PLAIN
var other_set: bool = false
## Index into unit.custom_slots this slot mirrors, or -1. Set before
## add_child, like every field above.
var custom_slot_index: int = -1
var is_custom_slot: bool:
	get: return custom_slot_index >= 0

var _icon_texture: Texture2D = null

@onready var _face: ColorRect = $Face
@onready var _face_material: ShaderMaterial = $Face.material
@onready var _frame: Panel = $Frame
@onready var _name_label: Label = $NameLabel
@onready var _toggle_border: CanvasItem = $ToggleBorder
@onready var _key_label: Label = $KeyLabel
@onready var _tag_label: Label = $TagLabel
@onready var _swap_badge: Label = $SwapBadge
@onready var _level_badge: Label = $LevelBadge

const WOUND_TAGS: Dictionary = {
	DamageResolver.WoundType.CRUSHING: "cr",
	DamageResolver.WoundType.CUTTING: "cut",
	DamageResolver.WoundType.IMPALING: "imp",
	DamageResolver.WoundType.SMALL_PIERCING: "pi-",
	DamageResolver.WoundType.PIERCING: "pi",
	DamageResolver.WoundType.LARGE_PIERCING: "pi+",
	DamageResolver.WoundType.HUGE_PIERCING: "pi++",
	DamageResolver.WoundType.BURNING: "burn",
	DamageResolver.WoundType.CORROSION: "cor",
	DamageResolver.WoundType.TOXIC: "tox",
}


func _ready() -> void:
	_apply_ability()
	pressed.connect(activate)
	gui_input.connect(_on_gui_input)
	mouse_entered.connect(_refresh_face)
	mouse_exited.connect(_refresh_face)


## The hotkey shown in the corner ("1", "⇧3"), or "" for none.
func set_key_text(value: String) -> void:
	_key_label.text = value
	_key_label.visible = value != ""


func set_ability(value: Ability) -> void:
	ability = value
	if is_custom_slot and unit and custom_slot_index < unit.custom_slots.size():
		unit.set_custom_slot(custom_slot_index, value)
	_apply_ability()
	refresh_state()


func _apply_ability() -> void:
	var item_icon: Texture2D = _item_icon()
	_icon_texture = item_icon if item_icon else (ability.icon if ability else null)
	_face_material.set_shader_parameter("icon_tex", _icon_texture)
	_face_material.set_shader_parameter("has_icon", _icon_texture != null)
	# A weapon's picture is colour art; an ability's icon is a glyph.
	_face_material.set_shader_parameter("glyph", item_icon == null)
	_face_material.set_shader_parameter("tint", ability.icon_color if ability else Color(0.3, 0.27, 0.22))
	_face_material.set_shader_parameter("round", look == Look.ROUND)
	_name_label.visible = ability != null and _icon_texture == null
	_name_label.text = ability.ability_name if ability else ""
	tooltip_text = _build_tooltip()
	var row: AttackRow = _row()
	_tag_label.visible = look == Look.WEAPON and row != null
	if _tag_label.visible:
		_tag_label.text = WOUND_TAGS.get(row.wound_type, "")
	_swap_badge.visible = other_set
	_frame.modulate = other_set_frame_modulate if other_set else Color.WHITE
	_refresh_face()


## A weapon attack shows the weapon that makes it; anything else, or a
## natural attack, its own icon (null here).
func _item_icon() -> Texture2D:
	if not ability:
		return null
	var row: AttackRow = _row()
	if row and unit:
		for slot in UnitCombat.HAND_SLOTS:
			var item: ItemInstance = unit.get_equipped_item(slot)
			if item and item.definition and item.definition.icon and item.attacks().has(row):
				return item.definition.icon
	return null


## The Face's grey and brightness from disabled / other set / hover.
func _refresh_face() -> void:
	var saturation: float = 1.0
	var brightness: float = 1.0
	if disabled:
		saturation = disabled_saturation
		brightness = disabled_brightness
	elif other_set:
		saturation = other_set_saturation
		brightness = other_set_brightness
	if ability and not disabled and is_hovered():
		brightness *= hover_brightness
	_face_material.set_shader_parameter("saturation", saturation)
	_face_material.set_shader_parameter("brightness", brightness)


func _row() -> AttackRow:
	if not ability:
		return null
	for effect in ability.effects:
		if effect is GearDamageEffect and effect.row:
			return effect.row
	return null


## Lines for StatTip.build: name, what it does, then the to-hit sum as
## part rows and the number to roll.
func _build_tooltip() -> String:
	if not ability:
		return ""
	var lines: PackedStringArray = []
	if ability.targeting:
		lines.append(ability.targeting.describe())
	for effect in ability.effects:
		lines.append(effect.describe())
	if ability.hit_location:
		lines.append(ability.hit_location.describe())
	if ability == UnitCombat.DECEPTIVE_ATTACK:
		lines.append("Per level: -2 to your skill, -1 to the target's defense")
	if ability.toggle_off:
		lines.append("Use again while on: %s" % ability.toggle_off.ability_name)
	if ability.max_level > 0:
		lines.append("Click while on: next level (1-%d). Right click: off" % ability.max_level)
	if other_set:
		lines.append("Using it swaps weapon sets")
	var parts: Array[Dictionary] = _to_hit_parts()
	var text_out: String = StatTip.tip_text(ability.ability_name, "\n".join(lines), parts)
	if not parts.is_empty():
		var total: int = 0
		for part in parts:
			total += part.amount
		text_out += "\nHit on %d or less, before range and the target's modifiers" % total
	return text_out


## The GURPS to-hit sum as far as it is known without a target: skill,
## the weapon's and statuses' own say (UnitCombat.to_hit_target with no
## target), then the aim and Deceptive Attack, which to_hit_target only
## adds against a unit.
func _to_hit_parts() -> Array[Dictionary]:
	var parts: Array[Dictionary] = []
	if not unit or ability.is_toggle:
		return parts
	var form: Ability = ability.form_for(unit)
	if not form.requires_to_hit:
		return parts
	var skill: int = unit.attack_skill()
	parts.append({"label": "Basic Attack skill", "amount": skill})
	parts.append({"label": "Weapon and statuses", "amount": unit.to_hit_target(null, form) - skill})
	var location: HitLocation = unit.hit_location_for(form)
	if location:
		parts.append({"label": "Aim: %s" % location.display_name, "amount": location.to_hit_penalty})
	var deceptive: int = unit.deceptive_level()
	if deceptive > 0:
		parts.append({"label": "Deceptive Attack %d" % deceptive, "amount": -2 * deceptive})
	return parts


func _make_custom_tooltip(for_text: String) -> Object:
	return StatTip.build(for_text)


func _set_style(style: StyleBox) -> void:
	_frame.add_theme_stylebox_override("panel", style)


## Re-applies armed / on / disabled state from AbilityManager and the
## unit. dock.gd calls it on every slot after anything that can change
## it; the tooltip is rebuilt too, since the to-hit sum moves with the
## toggles.
func refresh_state() -> void:
	_refresh_state()
	_refresh_face()


func _refresh_state() -> void:
	tooltip_text = _build_tooltip()
	if not ability or not unit:
		_set_style(style_empty)
		_toggle_border.visible = false
		_level_badge.visible = false
		disabled = false
		return
	var on: bool = ability.is_toggle and unit.is_toggled(ability)
	_toggle_border.visible = look != Look.ROUND and ((on) or ability.is_on_for(unit))
	_refresh_level_badge(on)
	if ability.is_toggle:
		_set_style(style_round_lit if on else style_round)
		disabled = false
		return
	var armed: bool = ability == AbilityManager.armed_ability
	_set_style(style_armed if armed else (style_weapon if look == Look.WEAPON else style_plain))
	# A toggle cast that is on is judged by what using it now does.
	var form: Ability = ability.form_for(unit)
	disabled = form.attack_action_spent_by(unit) or form.out_of_ammo(unit) \
			or (form.targeting and not form.targeting.has_any_valid_target(unit))


## An aim toggle's penalty while it is on; a leveled toggle's level,
## dimmed while off.
func _refresh_level_badge(on: bool) -> void:
	if ability.is_toggle and ability.max_level > 0:
		_level_badge.visible = true
		_level_badge.text = str(unit.toggle_level(ability))
		_level_badge.modulate = Color.WHITE if on else level_off_modulate
	elif ability.is_toggle and ability.hit_location and on:
		_level_badge.visible = true
		_level_badge.text = str(ability.hit_location.to_hit_penalty)
		_level_badge.modulate = Color.WHITE
	else:
		_level_badge.visible = false


## A click or this slot's hotkey.
func activate() -> void:
	if not ability or not unit or disabled:
		return
	if ability.is_toggle:
		if ability.max_level > 0 and unit.is_toggled(ability):
			unit.set_toggle_level(ability, unit.toggle_level(ability) % ability.max_level + 1)
		else:
			unit.set_toggled(ability, not unit.is_toggled(ability))
		return
	if _summon_demon_effect():
		_show_demon_picker()
		return
	if ability.targeting and ability.targeting.resolves_immediately():
		unit.use_ability(ability, unit)
		return
	if AbilityManager.armed_ability == ability:
		AbilityManager.disarm()
	else:
		AbilityManager.arm(ability)


func _on_gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT):
		return
	if ability and unit and ability.is_toggle and ability.max_level > 0:
		unit.set_toggled(ability, false)
		accept_event()


## A runtime type check rather than a field on Ability, so one ability's
## popup does not add schema to every other.
func _summon_demon_effect() -> SummonDemonEffect:
	for effect in ability.effects:
		if effect is SummonDemonEffect:
			return effect
	return null


## One entry per owned demon that is alive and not already fielded.
func _show_demon_picker() -> void:
	var owned: Array[OwnedDemon] = DemonRoster.all_owned()
	if owned.is_empty():
		SystemLog.print("No demons in your roster yet.")
		return
	var available: Array[OwnedDemon] = owned.filter(func(entry: OwnedDemon): return not entry.is_dead and not DemonRoster.is_fielded(entry))
	if available.is_empty():
		SystemLog.print("None of your demons can be summoned right now.")
		return
	var popup := PopupMenu.new()
	add_child(popup)
	for i in available.size():
		var entry: OwnedDemon = available[i]
		popup.add_item("%s (HP %d/%d)" % [entry.species.display_name, entry.get_pool(StatIds.HP), entry.species.stat_value(StatIds.HP)], i)
	popup.id_pressed.connect(func(id: int): _on_demon_picked(available[id]))
	popup.popup_hide.connect(popup.queue_free)
	popup.popup(Rect2(get_screen_position(), Vector2.ZERO))


## Arms a shallow copy of the ability carrying a fresh SummonDemonEffect
## for the picked demon; ground-click placement downstream is unchanged.
func _on_demon_picked(owned_demon: OwnedDemon) -> void:
	var picked_effect := SummonDemonEffect.new()
	picked_effect.owned_demon = owned_demon
	var picked_ability: Ability = ability.duplicate()
	picked_ability.effects = [picked_effect]
	AbilityManager.arm(picked_ability)


func _get_drag_data(_at_position: Vector2) -> Variant:
	if not ability:
		return null
	var preview := TextureRect.new()
	preview.texture = _icon_texture
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.size = size
	preview.position = -preview.size / 2
	preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_drag_preview(preview)
	return ability


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	return is_custom_slot and data is Ability


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	if is_custom_slot and data is Ability:
		set_ability(data)
