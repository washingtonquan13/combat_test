class_name LootRoller
extends RefCounted
## Rolls fresh drops: a base, its rarity, affixes or unique, sockets, all
## at one item level — a monster's (UnitDefinition.level) for what it
## leaves behind, the area's (AreaDefinition.level) for a chest. Static,
## like the databases it draws from.
##
## Everything that isn't gear (runes, the awl, scrolls, potions) drops as
## a single loose item instead, CURRENCY_CHANCE of the time.

const CURRENCY_CHANCE := 0.25

## Odds of each rarity for a gear drop. A unique roll with no unique at
## this level falls back to rare.
const RARITY_WEIGHTS: Dictionary = {
	ItemInstance.Rarity.NORMAL: 60,
	ItemInstance.Rarity.MAGIC: 30,
	ItemInstance.Rarity.RARE: 9,
	ItemInstance.Rarity.UNIQUE: 1,
}

## Per rarity: fewest and most affixes, and most of either kind.
const AFFIX_COUNTS: Dictionary = {
	ItemInstance.Rarity.MAGIC: [1, 2, 1],
	ItemInstance.Rarity.RARE: [2, 4, 2],
}

## A rare's name is one word from each.
const RARE_FIRST: Array[String] = [
	"Grim", "Ash", "Blood", "Bone", "Storm", "Dread", "Hollow", "Iron",
	"Raven", "Gloom", "Wrath", "Doom", "Pale", "Venom", "Cinder", "Night",
]
const RARE_SECOND: Array[String] = [
	"Fang", "Bite", "Ward", "Shell", "Grasp", "Song", "Veil", "Mark",
	"Hide", "Spike", "Coil", "Brand", "Howl", "Thorn", "Mantle", "Knell",
]


## count rolls at level, each a drop.
static func roll_many(level: int, count: int, rng: RandomNumberGenerator) -> Array[ItemInstance]:
	var drops: Array[ItemInstance] = []
	for i in count:
		var item := roll(level, rng)
		if item:
			drops.append(item)
	return drops


## One drop at level, or null when there is nothing to drop.
static func roll(level: int, rng: RandomNumberGenerator) -> ItemInstance:
	var gear: Array[ItemDefinition] = []
	var loose: Array[ItemDefinition] = []
	for definition in ItemDatabase.get_all():
		(gear if definition is GearItem else loose).append(definition)
	if not loose.is_empty() and (gear.is_empty() or rng.randf() < CURRENCY_CHANCE):
		return ItemInstance.new(loose[rng.randi_range(0, loose.size() - 1)])
	if gear.is_empty():
		return null

	var rarity: ItemInstance.Rarity = _weighted_key(RARITY_WEIGHTS, rng)
	var item: ItemInstance
	if rarity == ItemInstance.Rarity.UNIQUE:
		var uniques := UniqueDatabase.get_all().filter(func(u): return u.level <= level and u.base)
		if uniques.is_empty():
			rarity = ItemInstance.Rarity.RARE
		else:
			var unique: UniqueItem = uniques[rng.randi_range(0, uniques.size() - 1)]
			item = ItemInstance.new(unique.base)
			item.unique = unique
	if not item:
		item = ItemInstance.new(gear[rng.randi_range(0, gear.size() - 1)])
	item.item_level = level
	item.rarity = rarity
	if AFFIX_COUNTS.has(rarity):
		roll_affixes(item, rng)
	if item.rarity == ItemInstance.Rarity.RARE:
		item.rare_name = "%s %s" % [RARE_FIRST[rng.randi_range(0, RARE_FIRST.size() - 1)],
			RARE_SECOND[rng.randi_range(0, RARE_SECOND.size() - 1)]]
	item.identified = item.rarity == ItemInstance.Rarity.NORMAL
	item.roll_sockets(rng)
	return item


## Fills item with its rarity's number of affixes, by weight, one per
## group and no more prefixes or suffixes than the rarity allows. A magic
## or rare copy nothing can roll on comes out normal.
static func roll_affixes(item: ItemInstance, rng: RandomNumberGenerator) -> void:
	var counts: Array = AFFIX_COUNTS[item.rarity]
	var target: int = rng.randi_range(counts[0], counts[1])
	var per_kind: int = counts[2]
	var pool := AffixDatabase.get_all().filter(func(a): return a.can_roll_on(item))
	var taken: Dictionary = {}
	var kinds: Dictionary = {Affix.Kind.PREFIX: 0, Affix.Kind.SUFFIX: 0}
	item.affixes.clear()
	while item.affixes.size() < target:
		var options := pool.filter(func(a): return not taken.has(a.group) and kinds[a.kind] < per_kind)
		if options.is_empty():
			break
		var weights: Dictionary = {}
		for affix in options:
			weights[affix] = affix.weight
		var affix: Affix = _weighted_key(weights, rng)
		taken[affix.group] = true
		kinds[affix.kind] += 1
		item.affixes.append(affix)
	item.affixes.sort_custom(func(a, b): return a.kind < b.kind)
	if item.affixes.is_empty():
		item.rarity = ItemInstance.Rarity.NORMAL


static func _weighted_key(weights: Dictionary, rng: RandomNumberGenerator) -> Variant:
	var total := 0
	for key in weights:
		total += weights[key]
	var pick := rng.randi_range(1, maxi(total, 1))
	for key in weights:
		pick -= weights[key]
		if pick <= 0:
			return key
	return weights.keys()[0]
