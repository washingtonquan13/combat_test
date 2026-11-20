class_name ImpactKit
extends Resource
## What an impact looks and sounds like, by kind of contact: the content
## half of CinematicStage.impact(). The ContactEvent says what touched and
## how hard; this says what plays there. One kit serves every paired clip a
## stage plays, so a scene's blades all ring the same.
##
## Any field left empty simply plays nothing for that kind.

@export_group("Parry")
## Blade on blade: sparks at the meeting point.
@export var parry_vfx: VfxEffect
@export var parry_sfx: SfxCue
@export_group("Hit")
## A point or edge in a body: blood at the struck point.
@export var hit_vfx: VfxEffect
@export var hit_sfx: SfxCue
@export_group("Kill")
## Empty falls back to the hit's.
@export var kill_vfx: VfxEffect
@export var kill_sfx: SfxCue
@export_group("Land")
## A body meeting the ground: dust at the feet and a thud.
@export var land_vfx: VfxEffect
@export var land_sfx: SfxCue
@export_group("Reaction")
## The struck body's recoil, played on its FLINCH layer on the contact
## frame. Empty asks the body for its own hit clip.
@export var flinch_clip: String = ""


func vfx_for(kind: ContactEvent.Kind) -> VfxEffect:
	match kind:
		ContactEvent.Kind.PARRY:
			return parry_vfx
		ContactEvent.Kind.HIT:
			return hit_vfx
		ContactEvent.Kind.KILL:
			return kill_vfx if kill_vfx else hit_vfx
		ContactEvent.Kind.LAND:
			return land_vfx
	return null


func sfx_for(kind: ContactEvent.Kind) -> SfxCue:
	match kind:
		ContactEvent.Kind.PARRY:
			return parry_sfx
		ContactEvent.Kind.HIT:
			return hit_sfx
		ContactEvent.Kind.KILL:
			return kill_sfx if kill_sfx else hit_sfx
		ContactEvent.Kind.LAND:
			return land_sfx
	return null
