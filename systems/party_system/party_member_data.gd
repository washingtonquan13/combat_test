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

## Stable identity, carried onto the spawned Unit as its
## persistent_id and back off it on capture.
##
## Generated ONCE, then saved and never regenerated — a turn order, or
## anything else written down about a unit, is only meaningful if the
## same name finds the same person on the far side of a load. Empty on
## a record built before ids existed; PartyManager stamps one then.
@export var id: StringName = &""

@export var definition: UnitDefinition = null
## Whether this record was PartyManager's leader at capture time — read
## by spawn_party() to re-designate the leader among the freshly spawned
## Units, since the old leader reference doesn't survive the world reload
## that made this snapshot necessary in the first place.
@export var is_leader: bool = false

@export var display_name: String = ""
@export var portrait_texture: Texture2D = null
@export var faction: StringName = &"player"
## Team colors — authored per-instance on Unit (test_arena.tscn's 4
## starting members each set their own), not derivable from definition
## the way most other cascaded fields are. Missing this was a real,
## silent bug: every world reload restored a member's stats but not its
## color, so a party member's HUD/selection-ring color quietly reverted
## to Unit's own script defaults the moment spawn_member() replaced the
## original hand-placed node.
@export var selected_color: Color = Color(1, 0.85, 0.2, 0.9)
@export var hover_color: Color = Color(1, 1, 1, 0.5)

@export var strength: int = 10
@export var dexterity: int = 10
@export var intelligence: int = 10
@export var health: int = 10
@export var will: int = 10
@export var perception: int = 10
@export var move: int = 5
## Real-time physical movement speed — distinct from move (the tactical
## move-budget stat) the same way it's distinct on Unit itself. Missing
## this was a silent bug of the exact same shape selected_color's own doc
## comment already records: every world reload restored a member's stats
## but not their physical speed, so a hand-tuned member (test_arena.tscn
## authors 5.0 on all four starting members, Unit's own script default is
## 4.0) quietly reverted the moment spawn_member() replaced the original
## hand-placed node.
@export var move_speed: float = 4.0

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
