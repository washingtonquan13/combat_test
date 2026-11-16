class_name RagdollPart
extends Resource
## One solid piece of a ragdoll: the bone it moves, and the shape that
## stands for it. See RagdollProfile and Corpse.
##
## The shape is a capsule from the bone's origin to `tip`'s origin, or
## between `tip` and `tip_b` when both are set (a hip bar across the two
## thighs), or a sphere on the bone when neither is (a head: nothing below
## it to point at). Every bone the profile does not name keeps its pose
## relative to its parent, so a hand rides its forearm and a foot its shin.

## The bone this piece moves.
@export var bone: StringName = &""
## Where the capsule ends. Empty for a sphere.
@export var tip: StringName = &""
## With `tip`: the capsule spans tip to tip_b instead of starting at the bone.
@export var tip_b: StringName = &""
## Capsule radius as a fraction of its length, so it scales with the body.
@export var radius_ratio: float = 0.2
## A sphere's radius, in the skeleton's own units (scaled with the body like
## its bones are). Its centre sits that far along the bone from its origin.
@export var sphere_radius: float = 0.1
## Relative weight: what the falling body hangs from.
@export var mass: float = 1.0
## How far this piece may swing off its parent piece, and twist about its
## own length, in degrees (a ConeTwistJoint3D at this bone's origin).
@export var swing_degrees: float = 40.0
@export var twist_degrees: float = 15.0
