class_name PartySkillRecord
extends Resource
## One trained skill inside a PartyMemberData snapshot — the same
## (Skill, levels_purchased) pair a live SkillInstance node carries, just
## as plain data instead of a scene-tree child. See PartyMemberData's own
## header for why a live Unit's skills need this instead of persisting
## SkillInstance nodes directly (nodes aren't the storage shape a
## Resource-based party snapshot wants).

@export var skill: Skill = null
@export var levels_purchased: int = 1
