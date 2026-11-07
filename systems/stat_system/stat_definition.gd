class_name StatDefinition
extends Resource
## One stat, as data — what it is called, whether it is authored or
## derived, and (for a derived stat) the formula that derives it. One
## .tres per stat under res://data/stats/; StatDatabase loads them all,
## so adding a stat is dropping in a file, and changing one is editing it
## in the Inspector.
##
## Shared and never mutated, like Ability: every unit that has DX points
## at the same dx.tres. The per-unit numbers live on StatInstance nodes —
## see that file for the definition/instance split, which is the same one
## Skill/SkillInstance already draws.

enum Kind {
	## An authored value — ST, DX, IQ, HT, DR. StatInstance.base IS the
	## stat before modifiers.
	PRIMARY,
	## Computed from other stats by `formula` — HP, FP, Will, Per, Move.
	## StatInstance.base is a bought or sold bonus on top (GURPS's levels
	## over the formula), never the stat itself, so raising an input
	## raises everything derived from it.
	DERIVED,
}

## How code and data name this stat — StatIds holds the ones rules refer
## to by name. Must be a valid identifier: formulas read other stats by
## exactly this id.
@export var id: StringName = &""
@export var display_name: String = ""
@export var abbreviation: String = ""
@export_multiline var description: String = ""
## Sort key for every list that shows stats (character sheet, chargen,
## demon sheet). Lower first.
@export var order: int = 0

@export var kind: Kind = Kind.PRIMARY
## Godot Expression over other stats' ids, evaluated with their MODIFIED
## values, fractions and all — a formula drops a fraction itself where
## GURPS does (floori(BasicSpeed) for Basic Move) — "ST", "floori((DX + HT) * 1.5)". Built-in global functions
## (floori, max, clampi, ...) are available. Ignored for PRIMARY.
## StatDatabase parses every formula at load and refuses one that does not
## parse or names a stat that does not exist.
@export var formula: String = ""
## A base value for PRIMARY, a bonus for DERIVED — what a unit gets when
## nothing authors this stat for it.
@export var default_value: int = 0

## Also tracks a current value against this stat as its maximum — HP, FP.
## Damage, healing and spending move current; the stat itself is the cap.
@export var is_pool: bool = false

## Bought with points in character creation when set; a stat with no
## table (DR, every derived stat) is not offered there.
@export var point_buy: PointBuyTable = null


func is_derived() -> bool:
	return kind == Kind.DERIVED


func label() -> String:
	return abbreviation if abbreviation != "" else String(id)


## A stat's value as a sheet shows it: whole when it is whole, else to
## two places (Basic Speed 5.25 — GURPS's own way of writing it).
static func format(value: float) -> String:
	return "%d" % floori(value) if value == floorf(value) else "%.2f" % value
