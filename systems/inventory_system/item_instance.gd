class_name ItemInstance
extends RefCounted
## One copy of an item — the per-copy state that ItemDefinition (shared,
## authored, one per kind of item) can't hold: the stack count, rarity,
## sockets and the runes in them. Where affixes, item level and
## identified go when those exist.
##
## What the copy does is its definition plus its modifiers (ItemModifier):
## attacks() for the local half, stat_modifiers() for the global one.
## Everything that reads a held weapon's rows or a worn item's modifiers
## reads them from here, never from the shared definition.
##
## RefCounted rather than Resource on purpose: a Resource can be saved
## into a .tres and shared by accident, the same trap
## resource_vs_node_for_mutable_state warns about. Two units can never
## end up wearing the same copy.
##
## Lives in an ItemContainer (a grid) or a UnitEquipment slot. The Item
## Control is only a view of one of these — see item.gd.

signal changed
## Sockets or runes changed — what the copy grants did. UnitEquipment
## re-registers a worn copy's stat modifiers on it.
signal modifiers_changed

## Diablo's colour tiers. Only a name colour for now: magic and rare are
## what will carry affixes, unique a fixed authored set.
enum Rarity { NORMAL, MAGIC, RARE, UNIQUE }

const RARITY_COLORS: Dictionary = {
	Rarity.NORMAL: Color(0.86, 0.86, 0.86),
	Rarity.MAGIC: Color(0.53, 0.53, 1.0),
	Rarity.RARE: Color(1.0, 1.0, 0.47),
	Rarity.UNIQUE: Color(0.78, 0.48, 0.2),
}

var definition: ItemDefinition

var rarity: Rarity = Rarity.NORMAL

## Empty sockets plus filled ones. Never more than max_sockets().
var sockets: int = 0
## One per filled socket, in the order they went in. Permanent.
var runes: Array[RuneItem] = []

## attacks() built once per change to the modifiers; null when stale.
var _attacks: Variant = null

var count: int = 1:
	set(value):
		count = value
		changed.emit()

## Rounds left in this copy's magazine (WeaponData.shots); -1 is a full
## one, so a fresh copy needs no setup. Not saved: a loaded weapon comes
## back full (the party record keeps definitions — inventory.md issue 12).
var _shots_left: int = -1

## Same name and meaning as Item.gear_data had, so call sites that read
## `.gear_data` (UnitCombat, GearDamageEffect, PartyManager) read an
## instance exactly the way they read a widget.
var gear_data: GearItem:
	get: return definition as GearItem


func _init(item_definition: ItemDefinition = null, stack: int = 1) -> void:
	definition = item_definition
	count = stack


func size() -> Vector2i:
	if not definition:
		return Vector2i.ONE
	return Vector2i(definition.width, definition.height)


## Rounds left, or -1 for a weapon with no magazine.
func shots_left() -> int:
	var capacity: int = magazine()
	if capacity <= 0:
		return -1
	return capacity if _shots_left < 0 else _shots_left


func magazine() -> int:
	return gear_data.weapon_data.shots if gear_data and gear_data.weapon_data else 0


## Fires up to count rounds; returns how many actually went.
func fire(count: int) -> int:
	var left: int = shots_left()
	if left < 0:
		return count
	var fired: int = mini(count, left)
	_shots_left = left - fired
	changed.emit()
	return fired


func reload() -> void:
	_shots_left = -1
	changed.emit()


## --- Sockets and modifiers ---

## Attack rows count this a weapon; a shield's bash doesn't.
func is_weapon() -> bool:
	return gear_data != null and gear_data.weapon_data != null and not gear_data.is_shield


## The kind's limit, capped by how many cells the item covers — boots are
## 2x2 but hold 2.
func max_sockets() -> int:
	if not gear_data:
		return 0
	return mini(gear_data.socket_limit(), definition.width * definition.height)


func free_sockets() -> int:
	return sockets - runes.size()


func add_socket() -> bool:
	if sockets >= max_sockets():
		return false
	sockets += 1
	_modifiers_changed()
	return true


func insert_rune(rune: RuneItem) -> bool:
	if free_sockets() <= 0:
		return false
	runes.append(rune)
	_modifiers_changed()
	return true


## A fresh drop's sockets: 0 to max_sockets(), evenly.
func roll_sockets(rng: RandomNumberGenerator = null) -> void:
	var top: int = max_sockets()
	sockets = rng.randi_range(0, top) if rng else randi_range(0, top)
	_modifiers_changed()


## Every modifier on this copy, as it applies to this kind of item.
func modifiers() -> Array[ItemModifier]:
	var result: Array[ItemModifier] = []
	for rune in runes:
		var modifier: ItemModifier = rune.modifier_for(self)
		if modifier:
			result.append(modifier)
	return result


## What the wearer gets: the definition's own modifiers, then the
## modifiers' global halves.
func stat_modifiers() -> Array[StatModifierBehavior]:
	var result: Array[StatModifierBehavior] = []
	if gear_data:
		result.append_array(gear_data.stat_modifiers)
	for modifier in modifiers():
		result.append_array(modifier.stat_modifiers)
	return result


## This copy's attack rows. With no local modifiers these ARE the shared
## WeaponData rows; with some, they're this copy's own duplicates with the
## modifiers written in — built once, and the same objects until the
## modifiers change, because UnitCombat keys its bound attacks by row.
func attacks() -> Array[AttackRow]:
	if _attacks == null:
		var rows: Array[AttackRow] = []
		if gear_data and gear_data.weapon_data:
			rows = gear_data.weapon_data.attacks
			var local: Array[ItemModifier] = modifiers().filter(func(m): return m.changes_attacks())
			if not local.is_empty():
				var own: Array[AttackRow] = []
				for row in rows:
					var copy: AttackRow = row.duplicate()
					for modifier in local:
						modifier.apply_to_row(copy)
					own.append(copy)
				rows = own
		_attacks = rows
	return _attacks


func rows_of(kind: AttackRow.Kind) -> Array[AttackRow]:
	var rows: Array[AttackRow] = []
	for row in attacks():
		if row and row.kind == kind:
			rows.append(row)
	return rows


func display_name() -> String:
	return definition.item_name if definition else ""


func rarity_color() -> Color:
	return RARITY_COLORS[rarity]


func _modifiers_changed() -> void:
	_attacks = null
	modifiers_changed.emit()
	changed.emit()


## --- Save/load ---

## Everything per-copy, as plain data keyed by ids. Defaults are left out,
## so an untouched copy saves as {"id": ...} alone.
func to_dict() -> Dictionary:
	var entry: Dictionary = {"id": definition.id}
	if count != 1:
		entry["stack"] = count
	if rarity != Rarity.NORMAL:
		entry["rarity"] = rarity
	if sockets > 0:
		entry["sockets"] = sockets
	if not runes.is_empty():
		entry["runes"] = runes.map(func(r): return r.id)
	return entry


## Null when the id is unknown. Takes a bare id too — what a save from
## before per-copy state wrote.
static func from_dict(entry: Variant) -> ItemInstance:
	if not entry is Dictionary:
		entry = {"id": entry}
	var definition: ItemDefinition = ItemDatabase.find(entry.get("id", &""))
	if not definition:
		return null
	var item := ItemInstance.new(definition, int(entry.get("stack", 1)))
	item.rarity = int(entry.get("rarity", Rarity.NORMAL)) as Rarity
	item.sockets = int(entry.get("sockets", 0))
	for id in entry.get("runes", []):
		var rune := ItemDatabase.find(id) as RuneItem
		if rune:
			item.runes.append(rune)
	return item


## A second copy with this one's state — rounds in the magazine included.
func copy() -> ItemInstance:
	var twin := ItemInstance.new(definition, count)
	twin.rarity = rarity
	twin.sockets = sockets
	twin.runes = runes.duplicate()
	twin._shots_left = _shots_left
	return twin
