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


## A combat turn here is 6 seconds, not GURPS's 1, so Move is the meters
## covered in one: Basic Move (yards per second) over a whole turn.
const TURN_SECONDS := 6.0
const METERS_PER_YARD := 0.9144


## Basic Move = Basic Speed, (DX + HT) / 4, with the fraction dropped. The
## bonus is in levels of Basic Move, as GURPS buys it, so Basic Move 5 is
## 27 m a turn.
static func move(dx: int, ht: int, bonus: int) -> int:
	var basic_move: int = floori((dx + ht) / 4.0) + bonus
	return floori(basic_move * TURN_SECONDS * METERS_PER_YARD)
