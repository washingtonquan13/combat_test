class_name FaceShapeNames
extends Resource
## What a rig calls the face shapes FaceDriver drives. FaceDriver speaks
## ARKit (eyeBlinkLeft, mouthSmileLeft...) and the Meta visemes (viseme_aa...),
## which is what every MPFB human is baked with; a rig named otherwise maps
## each of those names to its own shape or shapes (Character Creator has one
## browInnerUp per side). A name not mapped is looked up as it is.
@export var names: Dictionary[String, PackedStringArray] = {}
