class_name FaceShapeNames
extends Resource
## What a rig calls the face shapes FaceDriver drives. FaceDriver speaks
## ARKit (eyeBlinkLeft, mouthSmileLeft...) and the Meta visemes (viseme_aa...),
## which is what every MPFB human is baked with; a rig named otherwise maps
## each of those names to its own shape or shapes (Character Creator has one
## browInnerUp per side). A name not mapped is looked up as it is.
@export var names: Dictionary[String, PackedStringArray] = {}
## How far each of the rig's own shapes turns the jaw bone open at full
## weight, in degrees: the bone half of a shape whose morph the export kept
## and whose bone turn it dropped (Character Creator's V_Open, Jaw_Open).
## Read from the rig's own data, never picked by eye; see FaceJaw.
@export var jaw_degrees: Dictionary[String, float] = {}
## The bone jaw_degrees turns.
@export var jaw_bone: StringName = &"Jaw"
