class_name PartyMemberData
extends Resource
## A data-only snapshot of one party member — everything about a live
## Unit that isn't recoverable from a UnitDefinition, captured so a whole
## world can be freed and reloaded without losing the party. See
## PartyManager.capture()/spawn_into(), the only writer/reader of this
## shape.
##
## definition is nullable: present for a recruited demon or an authored
## companion (a real species template — see UnitDefinition's own header),
## null for a character-creation leader, who is genuinely individual, not
## an instance of a shared species. spawn_into() branches on this exactly
## once, at the point it decides which scene to instantiate and whether
## the definition-cascade setter fires at all.
##
## Deliberately NOT captured: active status effects (every status in this
## project is turn-duration combat state, and world travel only ever
## happens out of combat — see WorldManager.can_load()) and world
## position (a saved position from a different level is meaningless, and
## could spawn the party inside geometry; a loaded world's own named spawn
## point is what actually places the party — see PartyManager.spawn_into).

@export var definition: UnitDefinition = null
## Whether this record was PartyManager's leader at capture time — read
## by spawn_party() to re-designate the leader among the freshly spawned
## Units, since the old leader reference doesn't survive the world reload
## that made this snapshot necessary in the first place.
@export var is_leader: bool = false

@export var display_name: String = ""
@export var portrait_texture: Texture2D = null
@export var faction: StringName = &"player"

@export var strength: int = 10
@export var dexterity: int = 10
@export var intelligence: int = 10
@export var health: int = 10
@export var will: int = 10
@export var perception: int = 10
@export var move: int = 5

@export var maximum_hp: int = 10
@export var current_hp: int = 10
@export var maximum_fp: int = 10
@export var current_fp: int = 10
@export var damage_reduction: int = 0

@export var alignment: int = 0
@export var tendency: int = 0

@export var abilities: Array[Ability] = []
@export var custom_slots: Array[Ability] = []

@export var skills: Array[PartySkillRecord] = []

## EquipSlot.Slot (int) -> GearItem — the data an equipped Item wraps, not
## the live Item node itself (see PartyManager.spawn_into(), which
## instantiates a fresh Item from each entry the same way GiveItemEffect
## already does).
@export var equipment: Dictionary = {}
