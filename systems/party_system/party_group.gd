class_name PartyGroup
extends RefCounted
## Party members who move together and share one location.
##
## The unit of TRAVEL, which is the thing "who is going" was missing.
## Travellers used to be derived ad hoc from the selection at the instant a
## door fired, so a split was whatever happened to be selected and nothing
## anywhere held on to the answer afterwards. A group is that answer, kept.
##
## EMBODIED or ABSTRACT, and which one is a property of where the group is
## rather than of the group itself. In an ordinary area its members are
## live Units standing in the world. In a world with no place for Units —
## the overworld and its avatar (spawns_party() -> false) — they collapse
## to PartyMemberData and the group is drawn as one avatar. The conversion
## is wholesale in both directions, which is why members need no stable
## identity for any of this to work: nothing ever has to match a record
## back up with a Unit.
##
## `records` is also the SERIALIZABLE form, so it is refreshed for an
## embodied group too (see PartyManager.capture, which SaveManager calls
## before writing). Only `embodied` says which of the two is currently the
## truth — an empty `units` does not, since a wiped-out group is still
## embodied, just dead.

## The LAST KNOWN area, and meaningful ONLY while this group is
## abstract. The empty name means "nowhere yet", which is the state
## between chargen and the first world load.
##
## Where an EMBODIED member is standing is not stored anywhere: it is
## unit.get_world_3d(), derived from the scene tree, and it cannot go
## stale. This field is only the answer for a group with no units to
## ask, which is the overworld case and nothing else.
##
## Named awkwardly on purpose. It was `area_id`, and reading it for an
## embodied group is precisely the mistake that made a member
## unclickable three times over: a second record of a fact the unit
## already carries, kept in step by hand across embody/split/merge/load,
## and wrong the moment that bookkeeping missed a step. Use
## current_area_id() unless you specifically mean the remembered one.
var abstract_area_id: StringName = &""


## Where this group IS.
##
## Derived from a live member whenever there is one, so it cannot
## disagree with where anybody is actually standing; falls back to the
## remembered area only when nobody is embodied to ask.
func current_area_id() -> StringName:
	if embodied:
		for unit in units:
			if not is_instance_valid(unit) or not unit.is_inside_tree():
				continue
			var area: AreaDefinition = WorldManager.area_of(unit)
			if area:
				return area.id
	return abstract_area_id

## True while this group's members exist as Units in the world named by
## area_id. False while they are folded down to records.
var embodied: bool = false

var units: Array[Unit] = []
var records: Array[PartyMemberData] = []

## Where this group's avatar stands while abstract. Meaningless otherwise —
## an embodied group's position is its Units' own, individually.
var overworld_position: Vector3 = Vector3.ZERO


## How many people are in this group, whichever form it is currently in.
func size() -> int:
	return live_units().size() if embodied else records.size()


func is_empty() -> bool:
	return size() == 0


func has_unit(unit: Unit) -> bool:
	return units.has(unit)


## Members still actually alive. `units` can hold freed entries between a
## death and the signal that prunes it, and every caller that iterates
## really wants the live ones.
func live_units() -> Array[Unit]:
	var live: Array[Unit] = []
	for unit in units:
		if is_instance_valid(unit):
			live.append(unit)
	return live


## Takes everyone from `other`, in whichever form each is currently in.
##
## Two groups normally only meet by being in the same place, and being
## in the same place decides the form, so both are usually the same
## kind. Not always though: a group can still carry the area id it had
## before it was folded down, so a merge CAN cross forms, and embodied
## has to win when it does.
func absorb(other: PartyGroup) -> void:
	if other == null or other == self:
		return
	# Whichever side is embodied wins. Without this a merge can hand an
	# ABSTRACT group live Units while leaving it marked abstract, and the
	# next travel rebuilds those people from records instead of carrying
	# them - silently replacing them with copies, and stranding the
	# originals in the world they were standing in.
	if other.embodied:
		embodied = true

	for unit in other.units:
		if is_instance_valid(unit) and not units.has(unit):
			units.append(unit)
	for record in other.records:
		if not records.has(record):
			records.append(record)
	other.units.clear()
	other.records.clear()
