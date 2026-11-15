class_name GiveItemEffect
extends DialogueEffect
## Puts a fresh copy of gear_data in the party's shared bag
## (PartyManager.inventory) — the "quest reward" case named in
## dialogue_system_bg3_gap_analysis.md. The bag lives on an autoload, so
## this Resource reaches it the same way FlagPrerequisite reaches
## FlagManager, whether or not any inventory screen exists.
##
## No StashComponent/shop-opening sibling yet — that would need a
## specific container instance a Resource has no clean way to reference
## either, and no scene actually needs it yet. Add it once one does,
## same restraint skill_check_choice.gd's own header already argues for.

## What this is called in a dialogue file (see DialogueScript).
const SCRIPT_WORDS: PackedStringArray = ["give"]

const ITEMS_DIR: String = "res://data/items"

@export var gear_data: ItemDefinition


func apply(_c: Conversation) -> void:
	if not PartyManager.inventory.add(ItemInstance.new(gear_data)):
		push_warning("GiveItemEffect: party inventory has no room for %s." % gear_data.item_name)


## "give healing_potion": an item by its file name in ITEMS_DIR.
func read_script(_word: String, args: PackedStringArray, _where: String) -> String:
	var path: String = "%s/%s.tres" % [ITEMS_DIR, args[0]] if args.size() == 1 else ""
	if path == "" or not ResourceLoader.exists(path):
		return "'give' is followed by the name of one item in %s." % ITEMS_DIR
	gear_data = load(path) as ItemDefinition
	return "" if gear_data else "'%s' is not an item that can be given." % args[0]
