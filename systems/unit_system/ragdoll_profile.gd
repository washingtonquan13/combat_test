class_name RagdollProfile
extends Resource
## How a body falls when it dies: which bones get a solid piece, and how
## those pieces hang together. A CharacterModel declares one (its `ragdoll`)
## and Corpse builds it; a body with none keeps its death clip instead.
##
## One profile per rig, not per creature: every body on the shared humanoid
## rig uses data/ragdolls/humanoid.tres, at whatever size it is worn.

## Parents before children is not required; Corpse orders them itself.
@export var parts: Array[RagdollPart] = []
