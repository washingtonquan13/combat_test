class_name DerivedStats
extends RefCounted

## The GURPS secondary characteristics, computed from the four primaries.
## Unit, UnitDefinition and PartyMemberData each store only a per-unit
## bonus on top of these (GURPS's bought or sold levels), never the
## secondary itself, so raising an attribute raises everything derived
## from it. One place for the formulas, so the character creation preview
## and the live unit can never disagree.

static func hp(st: int, bonus: int) -> int:
	return st + bonus


static func fp(ht: int, bonus: int) -> int:
	return ht + bonus


static func will(iq: int, bonus: int) -> int:
	return iq + bonus


static func perception(iq: int, bonus: int) -> int:
	return iq + bonus


## A combat turn here is 6 seconds, not GURPS's 1, so Move is the distance
## covered in one: Basic Move over a whole turn. A GURPS yard is taken as
## one meter of world, not converted.
const TURN_SECONDS := 6


## Basic Move = Basic Speed, (DX + HT) / 4, with the fraction dropped. The
## bonus is in levels of Basic Move, as GURPS buys it, so Basic Move 5 is
## 30 m a turn.
static func move(dx: int, ht: int, bonus: int) -> int:
	return (floori((dx + ht) / 4.0) + bonus) * TURN_SECONDS
