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
## On a Character Creator body (CCLook.wear), the garment's mesh in the
## body's clothed export; its covers mask is baked beside that export.
## Empty: not worn on CC bodies.
@export var cc_part: StringName
## Which garment is over which, where CC's layers sit through each other:
## a higher layer is worn over a lower, and the lower loses what it hides
## (CCLook). Two at the same layer are over each other by depth: each loses
## only what lies behind the other (a belt over a shirt's front, under its
## back). The base's underwear is under everything.
@export var cc_layer: int = 1
