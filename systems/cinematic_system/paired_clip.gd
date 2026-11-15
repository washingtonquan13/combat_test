class_name PairedClip
extends Resource
## Two clips made to be played together by two bodies: a stab and the one
## stabbed, a throw and the one thrown. PairedActionBeat plays one.
##
## The clips were made on one clock and one ground. Both start at time 0;
## the lead's starts with the lead over the origin facing +Z, and
## partner_from_lead is where the partner must stand, and the way it must
## face, measured from there. Stood like that and started on the same
## frame, the two meet: the blade is in the chest at contact_time.
##
## Made by a bake tool that knows the clips (tools/kimodo/
## make_paired_animations.gd), not typed: the numbers are measurements.

## The lead's clip, as its AnimationPlayer names it ("Paired/Stab_Lead").
@export var lead_clip: String = ""
## The partner's clip.
@export var partner_clip: String = ""
## The partner's place and facing, from the lead's, with +Z the way a body
## faces. Flat: heights are each body's own floor.
@export var partner_from_lead: Transform3D = Transform3D(Basis(Vector3.UP, PI), Vector3(0.0, 0.0, 1.0))
## Seconds in at which the two touch. Both bodies are on their places
## before this.
@export_range(0.0, 30.0, 0.01, "suffix:s") var contact_time: float = 0.5
## Seconds both clips last.
@export_range(0.0, 60.0, 0.01, "suffix:s") var length: float = 1.0
## The partner's clip ends with them dead on the ground.
@export var kills_partner: bool = false
