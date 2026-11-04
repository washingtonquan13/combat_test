class_name Cursor
extends RefCounted
## What the mouse is over this frame, and whether it is dragging a height.
## Resolved ONCE per frame by ClickRouter (resolve_cursor), the only thing
## in the project that raycasts the mouse or reads the Ctrl height drag.
##
## Before this, "where is the player aiming" had three owners: every
## indicator raycast for itself through a static per-frame cache on
## IndicatorBase, the router raycast again for each click, and the Ctrl
## drag's held ground point was a static that whichever indicator
## happened to be live wrote. An indicator switched off mid-press left
## that state stale, and the preview and the click could disagree about
## where the cursor was. Now there is one answer, built in one place,
## and the previews (through Aim) and the clicks read the same one.

## Where the ground is under the cursor, or null if the ray missed it.
## While a Ctrl height drag is held this is the ground point the press
## started on, not the one under the mouse: the mouse only moves the
## height, so the preview, the path and the click stay on that one spot.
var ground = null

## The Unit under the cursor, or null. Pickable bodies only (a corpse is
## not), otherwise unfiltered: alive/hostile/player-controlled checks
## belong to whoever is deciding what to do with it.
var unit: Unit = null

## Anything under the cursor implementing get_interactions() - a Unit, an
## InteractableProp, anything future. Null if the ray hit neither. Set
## alongside unit when a unit is hovered: a Unit is an interactable too.
var interactable: Node = null

## Whether a Ctrl height drag is held this frame - only ever true while
## the current intent takes one (PlayerIntent.drags_height).
var dragging_height: bool = false

## The height the drag points at: the mouse ray crossing a vertical wall
## through the held ground point, snapped to ClickRouter.HEIGHT_STEP.
## Null when not dragging, or the ray runs parallel to the wall.
var height = null


func describe() -> String:
	if unit:
		return "unit %s" % unit.name
	if interactable:
		return "interactable %s" % interactable.name
	if ground != null:
		return "ground %s" % ground
	return "nothing"
