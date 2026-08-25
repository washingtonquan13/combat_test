extends Button
## One ability slot in the hotbar. A Button rather than a plain Control —
## click handling, an icon, and a disabled state for free. Also a
## drag-and-drop SOURCE (see _get_drag_data) whenever it holds an
## ability, regardless of section — a Custom slot dragged elsewhere
## behaves identically to a Common/Abilities one (no "source was Custom"
## special-casing), which is what makes drag-based reassignment of a
## Custom slot work as a side effect without extra code. Only a
## Custom-section slot is a drop TARGET (see is_custom_slot) — a
## Common/Abilities slot always mirrors unit.abilities exactly and never
## accepts a drop.
##
## The drag payload is the Ability RESOURCE itself, not this Button —
## unlike the inventory system's Item (a Node with exactly one parent,
## moved by reparenting), the same Ability can legitimately sit in BOTH
## its home category slot AND a Custom slot at once, so there's no single
## "current location" to detach from. _get_drag_data's return type is
## plain Variant with no Node requirement — returning a Resource isn't a
## workaround, it's the same mechanism Variant always uses for any
## Object-derived reference.
##
## Scene setup: unchanged — a Button sized to your icon dimensions, no
## child nodes, everything set from code.

@export var armed_modulate: Color = Color(1, 0.85, 0.2, 1)

var ability: Ability = null
var unit: Unit = null

## Set by ability_hotbar.gd right after instantiate(), before add_child.
## Together these are the ONLY things distinguishing a Custom-section
## slot from a Common/Abilities one — every other behavior (rendering,
## arming/use, drag SOURCE) is identical regardless of section.
var is_custom_slot: bool = false
## Index into unit.custom_slots this slot mirrors, or -1 for a
## Common/Abilities slot. _drop_data writes back to
## unit.custom_slots[custom_slot_index] via set_ability — this Button's
## own `ability` field is a VIEW over that array element for a Custom
## slot, not an independent source of truth.
var custom_slot_index: int = -1


func _ready() -> void:
	_apply_ability()
	pressed.connect(_on_pressed)


## The only place ability is written after initial setup (see
## _drop_data). Routes through here so the Button's visuals and
## unit.custom_slots stay in lockstep instead of every caller having to
## remember to update both separately.
func set_ability(value: Ability) -> void:
	ability = value
	if is_custom_slot and unit and custom_slot_index >= 0 and custom_slot_index < unit.custom_slots.size():
		unit.custom_slots[custom_slot_index] = value
	_apply_ability()
	refresh_state()


func _apply_ability() -> void:
	icon = ability.icon if ability else null
	text = ability.ability_name if (ability and not ability.icon) else ""
	tooltip_text = _build_tooltip()


func _build_tooltip() -> String:
	if not ability:
		return ""
	var lines: PackedStringArray = [ability.ability_name]
	if ability.targeting:
		lines.append(ability.targeting.describe())
	for effect in ability.effects:
		lines.append(effect.describe())
	return "\n".join(lines)


func set_armed(value: bool) -> void:
	modulate = armed_modulate if value else Color(1, 1, 1, 1)


## Re-applies armed/disabled visual state from current
## AbilityManager/unit state — called by ability_hotbar._update_slot_states()
## for every slot after any ability-affecting signal, and by set_ability
## for the one slot that just changed which ability it holds (a fresh
## Custom assignment can't wait for the next unrelated signal to look
## right).
func refresh_state() -> void:
	if not ability or not unit:
		set_armed(false)
		disabled = false
		return
	set_armed(ability == AbilityManager.armed_ability)
	disabled = ability.attack_action_spent_by(unit) \
			or (ability.targeting and not ability.targeting.has_any_valid_target(unit))


func _on_pressed() -> void:
	if not ability:
		return
	var template_effect: SummonDemonEffect = _get_summon_demon_effect()
	if template_effect:
		_show_demon_picker()
		return
	if ability.targeting and ability.targeting.resolves_immediately():
		unit.use_ability(ability, unit)
		return
	if AbilityManager.armed_ability == ability:
		AbilityManager.disarm()
	else:
		AbilityManager.arm(ability)


## Whether `ability` carries a SummonDemonEffect template — a runtime
## type-check, not a new exported field on Ability/AbilityEffect, so this
## one ability's popup requirement doesn't add schema weight every OTHER
## ability's .tres would carry too. See this file's own header and
## demon_compendium_panel.gd for the fuller reasoning behind keeping this
## scope-contained.
func _get_summon_demon_effect() -> SummonDemonEffect:
	for effect in ability.effects:
		if effect is SummonDemonEffect:
			return effect
	return null


## One button per individually-owned demon — never grouped by species,
## since different instances can be mid-battle-damaged or freshly
## recruited, exactly the distinction a species-grouped list would hide.
## A plain built-in PopupMenu, not a custom Control — this is a one-off
## choice list, not something that needs its own scene.
func _show_demon_picker() -> void:
	var owned: Array[OwnedDemon] = DemonRoster.all_owned()
	if owned.is_empty():
		SystemLog.print("No demons in your roster yet.")
		return

	var popup := PopupMenu.new()
	add_child(popup)
	for i in owned.size():
		var entry: OwnedDemon = owned[i]
		popup.add_item("%s (HP %d/%d)" % [entry.species.display_name, entry.current_hp, entry.species.max_hp], i)
	popup.id_pressed.connect(func(id: int): _on_demon_picked(owned[id]))
	popup.popup_hide.connect(popup.queue_free)
	popup.popup(Rect2(get_screen_position(), Vector2.ZERO))


## Constructs a FRESH SummonDemonEffect wrapping the picked OwnedDemon,
## then arms it through AbilityManager exactly like any other targeted
## ability — the existing ground-click-to-place flow downstream is
## completely unaware anything special happened here. ability.duplicate()
## (a shallow copy — sub-resources like targeting stay SHARED with the
## template, not cloned) rather than hand-copying every Ability field, so
## this can't silently go stale the next time Ability gains a new export.
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
	preview.texture = ability.icon
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.size = custom_minimum_size
	preview.position = -preview.size / 2
	preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_drag_preview(preview)
	return ability


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	return is_custom_slot and data is Ability


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	if is_custom_slot and data is Ability:
		set_ability(data)
