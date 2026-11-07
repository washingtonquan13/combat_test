class_name StatIds
extends RefCounted
## The stats that rules name in code — damage reads HP and DR, the
## stay-up roll reads HT, a turn's budget reads Move (Air Move while
## flying), a hit is dodged against Dodge, every defense adds DB, a hit is
## aimed against SM, turn order reads Basic Speed. Constants rather than
## bare &"HP" literals so a misspelling is a parse error instead of a
## silent lookup miss.
##
## Not the list of stats: that is whatever .tres files sit in
## res://data/stats/ (see StatDatabase). A stat only data refers to — a
## new one being tried out, read only by a formula or a skill — needs no
## entry here at all.

const ST: StringName = &"ST"
const DX: StringName = &"DX"
const IQ: StringName = &"IQ"
const HT: StringName = &"HT"
const DR: StringName = &"DR"
const HP: StringName = &"HP"
const FP: StringName = &"FP"
const WILL: StringName = &"Will"
const PER: StringName = &"Per"
const MOVE: StringName = &"Move"
const AIR_MOVE: StringName = &"AirMove"
const SM: StringName = &"SM"
const DODGE: StringName = &"Dodge"
const DB: StringName = &"DB"
const BASIC_SPEED: StringName = &"BasicSpeed"
