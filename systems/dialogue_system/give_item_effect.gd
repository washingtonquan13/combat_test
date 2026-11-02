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

@export var gear_data: GearItem


func apply(_c: Conversation) -> void:
	if not PartyManager.inventory.add(ItemInstance.new(gear_data)):
		push_warning("GiveItemEffect: party inventory has no room for %s." % gear_data.item_name)
