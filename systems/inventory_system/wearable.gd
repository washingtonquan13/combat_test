class_name Wearable
extends Resource
## How a worn item looks on a body: clothes, shoes, armour. Baked by
## tools/characters/bake_character.py (a recipe's "wearables") into
## assets/wearables/<item>/: one .glb per body, the item fitted to that body
## on the same rig, and one covers mask, the same for every body because the
## bodies share MakeHuman's UVs. CharacterLook.wear() puts it on.

## Body type -> the item fitted to it (CharacterLook.body_type). An item
## with no fit for a body is not shown on it.
@export var meshes: Dictionary[StringName, PackedScene] = {}
## The skin the item hides, in the body's UV space: alpha is the cover.
@export var covers: Texture2D
