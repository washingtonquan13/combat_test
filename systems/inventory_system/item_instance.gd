class_name ItemInstance
extends RefCounted
## One copy of an item — the per-copy state that ItemDefinition (shared,
## authored, one per kind of item) can't hold: the stack count, rarity,
## item level, affixes or unique, whether it's identified, and sockets
## and the runes in them. LootRoller rolls a fresh drop's.
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

## Diablo's colour tiers: magic and rare carry rolled affixes, unique a
## fixed authored set (UniqueItem).
enum Rarity { NORMAL, MAGIC, RARE, UNIQUE }

const RARITY_COLORS: Dictionary = {
	Rarity.NORMAL: Color(0.86, 0.86, 0.86),
	Rarity.MAGIC: Color(0.53, 0.53, 1.0),
	Rarity.RARE: Color(1.0, 1.0, 0.47),
	Rarity.UNIQUE: Color(0.78, 0.48, 0.2),
}

var definition: ItemDefinition

var rarity: Rarity = Rarity.NORMAL

## The level it dropped at: which affix tiers and uniques it could roll.
var item_level: int = 1
## Rolled prefixes and suffixes, prefixes first.
var affixes: Array[Affix] = []
## The authored unique this copy is, or null.
var unique: UniqueItem
## A rare's two-word name, rolled with it.
var rare_name: String = ""
## An unidentified copy hides its affixes or unique and gets nothing from
## them until an IdentifyScroll reveals it — Diablo 2's rule, so a scroll
## is worth using.
var identified: bool = true

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


## Every modifier on this copy, as it applies to this kind of item: its
## affixes or unique once identified, then its runes.
func modifiers() -> Array[ItemModifier]:
	var result: Array[ItemModifier] = []
	if identified:
		for affix in affixes:
			result.append(affix.modifier)
		if unique:
			result.append_array(unique.modifiers)
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


func prefixes() -> Array[Affix]:
	return _affixes_of(Affix.Kind.PREFIX)


func suffixes() -> Array[Affix]:
	return _affixes_of(Affix.Kind.SUFFIX)


func _affixes_of(kind: Affix.Kind) -> Array[Affix]:
	var result: Array[Affix] = []
	for affix in affixes:
		if affix.kind == kind:
			result.append(affix)
	return result


func identify() -> void:
	identified = true
	_modifiers_changed()


## Unidentified, only the base's name. Magic: "Sharp Iron Sword of the
## Hawk". Rare and unique: their own name (the tooltip adds the base).
func display_name() -> String:
	if not definition:
		return ""
	if not identified:
		return definition.item_name
	match rarity:
		Rarity.MAGIC:
			var words: Array[String] = []
			for affix in prefixes():
				words.append(affix.affix_name)
			words.append(definition.item_name)
			for affix in suffixes():
				words.append(affix.affix_name)
			return " ".join(words)
		Rarity.RARE:
			if rare_name != "":
				return rare_name
		Rarity.UNIQUE:
			if unique:
				return unique.unique_name
	return definition.item_name


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
	if item_level != 1:
		entry["ilvl"] = item_level
	if not affixes.is_empty():
		entry["affixes"] = affixes.map(func(a): return a.id)
	if unique:
		entry["unique"] = unique.id
	if rare_name != "":
		entry["rare_name"] = rare_name
	if not identified:
		entry["identified"] = false
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
	item.item_level = int(entry.get("ilvl", 1))
	for id in entry.get("affixes", []):
		var affix := AffixDatabase.find(id)
		if affix:
			item.affixes.append(affix)
	if entry.has("unique"):
		item.unique = UniqueDatabase.find(entry["unique"])
	item.rare_name = entry.get("rare_name", "")
	item.identified = entry.get("identified", true)
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
	twin.item_level = item_level
	twin.affixes = affixes.duplicate()
	twin.unique = unique
	twin.rare_name = rare_name
	twin.identified = identified
	twin.sockets = sockets
	twin.runes = runes.duplicate()
	twin._shots_left = _shots_left
	return twin
