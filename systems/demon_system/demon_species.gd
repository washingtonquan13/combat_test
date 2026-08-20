class_name DemonSpecies
extends Resource
## The shared, stateless TEMPLATE for one kind of demon — "what a Pixie
## is," not any specific owned Pixie (see OwnedDemon for that). Every
## OwnedDemon of this species points back at the same DemonSpecies
## instance; nothing here ever changes per-instance.
##
## order is the fusion lookup key (Order A + Order B -> Order C, see
## FusionChart) — a bare StringName tag, not a dedicated Resource type,
## same reasoning Unit.faction stays a bare tag: there's no per-Order
## behavior to plug in, just a grouping label.
##
## rank is this species' position within its own order's ordering —
## FusionCalculator picks whichever species in the result order has the
## rank closest to the fused average, same "next demon up/down" idea
## classic Megaten fusion charts use in place of a level system this
## project doesn't have.
##
## max_hp/max_fp are authored here explicitly rather than read off
## unit_scene at runtime, so OwnedDemon never needs to instantiate a
## scene just to know a fresh recruit's starting stats.

@export var species_id: String = ""
@export var species_name: String = ""
@export var order: StringName = &""
@export var rank: int = 1
## True means this species can never be a fusion RESULT — obtainable
## only via negotiation/story, standard "boss/unique demon" exemption.
## Can still be a fusion INPUT.
@export var is_special: bool = false
@export var portrait_texture: Texture2D
## A Unit-derived scene, exactly the same convention SummonEffect.
## summon_scene and the existing scenes/units/sylph.tscn already use.
@export var unit_scene: PackedScene
@export var max_hp: int = 10
@export var max_fp: int = 0
