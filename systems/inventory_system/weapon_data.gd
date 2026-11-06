class_name WeaponData
extends Resource
## Composed onto GearItem only when it's actually a weapon — kept
## separate rather than a pile of weapon-only fields sitting unused on
## every armor/accessory GearItem too, same reasoning StatusBehavior
## already splits "what a status DOES" into small focused pieces
## instead of one class with a field per possible status.
##
## A weapon is its rows: each AttackRow is one way to use it (a
## broadsword swings to cut or thrusts to impale), and each becomes its
## own attack on the hotbar — see Unit.combat_abilities().

@export var attacks: Array[AttackRow] = []
## Takes both hands (GURPS's dagger mark, B269): while it's held, the
## paired off-hand slot stays empty — no shield, no second weapon. See
## UnitEquipment.hands_allow().
@export var two_handed: bool = false
## GURPS Shots: rounds a full magazine holds. Each attack fires up to
## the row's RoF from it; empty, the weapon can't fire until Reload
## (data/abilities/reload.tres). 0 is no magazine — a bow, a thrown axe.
## The rounds left are per copy (ItemInstance.shots_left).
@export var shots: int = 0
## What the hand holds while this is the drawn weapon (UnitWeapons). Its
## origin is the grip; +Y runs out of the thumb side of the fist (a
## blade's length, a pistol's top) and +Z the way the knuckles face (a
## blade's edge, a muzzle). Null shows nothing.
@export var model_scene: PackedScene = null
## Held in the other hand from the slot it's equipped in: a bow is
## equipped as the main weapon but held in the bow hand, the string hand
## free to draw.
@export var held_in_off_hand: bool = false
## The looping clip the body stands in while this is drawn, in place of
## its plain idle: the guard it fights from (UnitAnimator._idle). A
## shield's beats the main hand's - it changes how the whole body
## stands. Empty, or a clip the body lacks, keeps the plain idle.
@export var stance_animation: String = ""
## What Reload plays while this is the drawn magazine weapon. Null plays
## nothing.
@export var reload_animation: AnimationSequence = null

## Where it's carried while equipped but not in hand (UnitWeapons): the
## inactive set, and both sets while sheathed. AUTO decides by
## resolved_sheath(); the hand it's held in picks the hip's side.
enum Sheath { AUTO, BACK, HIP }
@export var sheath: Sheath = Sheath.AUTO


## sheath with AUTO decided: what takes both hands - a greatsword, a bow,
## a long gun, a crossbow - and any shield go across the back; anything
## one-handed - a sword, an axe, a pistol - on the hip.
func resolved_sheath(is_shield: bool) -> Sheath:
	if sheath != Sheath.AUTO:
		return sheath
	return Sheath.BACK if two_handed or is_shield else Sheath.HIP


## This weapon's rows of one kind, in authored order.
func rows_of(kind: AttackRow.Kind) -> Array[AttackRow]:
	var rows: Array[AttackRow] = []
	for row in attacks:
		if row and row.kind == kind:
			rows.append(row)
	return rows
