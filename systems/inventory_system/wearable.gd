class_name Wearable
extends Resource
## How a worn item looks on a body: clothes, shoes, armour. Baked by
## tools/characters/bake_character.py (a recipe's "wearables") into
## assets/wearables/<item>/: one .glb per body, the item fitted to that body
## on the same rig, and one covers mask, the same for every body because the
## bodies share MakeHuman's UVs. CharacterLook.wear() puts it on.
##
## On a Character Creator body the fits are keyed &"cc_male" / &"cc_female"
## (CCLook.body_type): one .glb per piece per base, fitted in Blender by
## tools/armor_fit/ and bound at runtime by CCWear. covers is unused there:
## hides says which skin the item hides instead.

## Body type -> the item fitted to it (CharacterLook.body_type). An item
## with no fit for a body is not shown on it.
@export var meshes: Dictionary[StringName, PackedScene] = {}
## The skin the item hides, in the body's UV space: alpha is the cover.
@export var covers: Texture2D
## On a CC body: the bones, as the body's skeleton names them, whose skin
## the item hides, each with every bone below it (CCLook.wear). Skin mostly
## weighted to them is not drawn, nor underwear mostly under them, so
## neither pokes through. &"CC_Base_Pelvis" is the hips, legs and feet.
@export var hides: Array[StringName] = []
