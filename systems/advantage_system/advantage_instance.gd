class_name AdvantageInstance
extends Node
## One unit's own hold on one Advantage, as StatInstance is for a stat. A
## child of the unit's Advantages node; see UnitAdvantages, which adds and
## removes these.

var advantage: Advantage
var level: int = 1
## What this unit got from having it, not what it already knew, so taking
## it away leaves the rest alone.
var granted: Array[Ability] = []
