class_name CinematicScene
extends Resource
## A staged moment: what the camera and the actors do, independent of who
## asked for it.
##
## NAMED CinematicScene, NOT Scene, deliberately. In Godot "scene" already
## means a .tscn, and a Resource called Scene that is not a PackedScene
## would read as one at every call site.
##
## PHASE 0 STUB. The plan (see the cinematic director build plan, draft 3)
## gives this roles and an Array[ScenePhase], each phase carrying steps at
## offsets and a duration source of vfx/clip/fixed/line. None of that is
## here yet, because phase 0 is only the seam — the point of building it
## alone is that a wrong seam is invisible and expensive later.
##
## `hold_seconds` is the one concession: a scene that occupies no time
## cannot be caught in CUTSCENE mode by any test, so the seam would be
## unobservable and phase 0 would prove nothing. It is the degenerate case
## of a fixed-duration phase and phase 1 subsumes it.

@export var id: StringName = &""
@export var hold_seconds: float = 0.0
