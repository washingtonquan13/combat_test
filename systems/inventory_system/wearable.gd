class_name Wearable
extends Resource
## How a worn item looks on a body: clothes, shoes, armour. The fits are
## keyed by body type, &"cc_male" / &"cc_female" (CCLook.body_type): one
## .glb per piece per Character Creator base, fitted in Blender by
## tools/armor_fit/ and bound at runtime by CCWear. CCLook.wear() puts it on.

## Body type -> the item fitted to it (CCLook.body_type). An item with no
## fit for a body is not shown on it.
@export var meshes: Dictionary[StringName, PackedScene] = {}
## On a CC body: the bones, as the body's skeleton names them, whose skin
## the item hides, each with every bone below it (CCLook.wear). Skin mostly
## weighted to them is not drawn, nor underwear mostly under them, so
## neither pokes through. &"CC_Base_Pelvis" is the hips, legs and feet.
@export var hides: Array[StringName] = []
