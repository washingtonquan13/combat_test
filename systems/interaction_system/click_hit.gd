class_name ClickHit
extends RefCounted
## What was under the cursor at the moment of one click, raycast ONCE by
## ClickRouter and handed to whichever PlayerIntent is current.
##
## Built once per click rather than per branch: the old router asked
## _get_hovered_interactable() on the left-click path, again on the
## right-click path, and Unit._on_input_event effectively asked a third
## time through physics picking. The underlying raycast is frame-cached
## (see IndicatorBase._raycast_cache) so that was cheap, but "cheap" was
## never the problem — three callers each deciding separately what the
## cursor was over is.
##
## All three fields are nullable and independent. unit and interactable
## come from the SAME raycast hit: a Unit is an interactable too (it
## implements get_interactions), so both are set when a unit is hovered.

## Where the ground is under the cursor, or null if the ray missed it.
var ground = null

## The Unit under the cursor, or null. Unfiltered — alive/hostile/
## player-controlled checks belong to whoever is deciding what the click
## does.
var unit: Unit = null

## Anything under the cursor implementing get_interactions() — a Unit, an
## InteractableProp, anything future. Null if the ray hit neither.
var interactable: Node = null


func describe() -> String:
	if unit:
		return "unit %s" % unit.name
	if interactable:
		return "interactable %s" % interactable.name
	if ground != null:
		return "ground %s" % ground
	return "nothing"
