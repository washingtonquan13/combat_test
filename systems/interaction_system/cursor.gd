class_name Cursor
extends RefCounted
## What the mouse is over this frame, and the height plane it may be on.
## Resolved ONCE per frame by ClickRouter (resolve_cursor), the only thing
## in the project that raycasts the mouse or reads the Ctrl height input.
##
## Before this, "where is the player aiming" had three owners: every
## indicator raycast for itself through a static per-frame cache on
## IndicatorBase, the router raycast again for each click, and the Ctrl
## drag's held ground point was a static that whichever indicator
## happened to be live wrote. An indicator switched off mid-press left
## that state stale, and the preview and the click could disagree about
## where the cursor was. Now there is one answer, built in one place,
## and the previews (through Aim) and the clicks read the same one.

## The point the cursor aims at, or null if the ray met nothing - the
## one point the previews (through Aim) and the clicks read. Usually the
## surface under the mouse, but while a height plane is active (see
## plane_height) it is the FIRST thing the mouse ray meets: the surface,
## or the ray crossing the plane, whichever is nearer the camera - so it
## can be midair (on_plane). While a Ctrl height hold is down it is the
## held spot raised to the held height: the mouse only moves the height,
## so the preview, the path and the click stay over that one spot.
var ground = null

## Whether ground came from the height plane (midair, or a held Ctrl
## spot) rather than from a surface the ray hit.
var on_plane: bool = false

## The height plane's world Y this frame, or null when none is active:
## an idle flier's altitude (always on while one flies), an aiming
## height the player latched with Ctrl + wheel or a Ctrl hold, or the
## height a Ctrl hold points at right now.
var plane_height = null

## The surface straight below ground (a downward ray against the
## router's ground_collision_mask) when on_plane, null if nothing is
## below it; ground itself otherwise. Where a walker sent to a midair
## point goes, and what a drop line from a midair marker reaches.
var floor_below = null

## Whether Ctrl is held over an intent that takes a height this frame:
## ground's XZ is frozen at the spot the hold started on and the mouse's
## height on screen sets plane_height (ClickRouter._sample_height).
var holding_height: bool = false

## Whether the player moved the plane this frame (a Ctrl hold, or a Ctrl
## + wheel step) - the cue for the intent to write plane_height to what
## it steers (PlayerIntent.steer). False on frames the plane only stood.
var height_steered: bool = false

## The Unit under the cursor, or null. Pickable bodies only (a corpse is
## not), otherwise unfiltered: alive/hostile/player-controlled checks
## belong to whoever is deciding what to do with it.
var unit: Unit = null

## Anything under the cursor implementing get_interactions() - a Unit, an
## InteractableProp, anything future. Null if the ray hit neither. Set
## alongside unit when a unit is hovered: a Unit is an interactable too.
var interactable: Node = null

## Where a point/area ability lands when the player clicks now - the ONE
## rule, read by both the preview (Aim.build) and the click
## (AimingIntent.handle_left_click), so they cannot disagree:
## - a Ctrl height hold keeps its spot (ground already is it);
## - a point-target ability with a unit under the cursor aims at that
##   unit: its centre of mass (CharacterModel.Anchor.CHEST) for a shape
##   that is aimed in 3D (AbilityTargeting.takes_aim_height - a cone, a
##   line, an aerial area), so pointing at a flier needs no height input;
##   its feet (unit.global_position) for anything placed on the floor;
## - otherwise ground (null if the ray met nothing).
## Before this, an area ability hovered over a unit previewed on the
## unit's capsule, and the click was then routed to the unit and refused
## silently by its targeting check.
func aim_point(ability: Ability) -> Variant:
	if holding_height:
		return ground
	if aims_at_unit(ability):
		if ability.targeting.takes_aim_height():
			return unit.anchor(CharacterModel.Anchor.CHEST)
		return unit.global_position
	return ground


## Whether aim_point(ability) is the hovered unit rather than ground.
func aims_at_unit(ability: Ability) -> bool:
	return (not holding_height and is_instance_valid(unit) and ability != null
		and ability.targeting != null and ability.targeting.expects_point_target())


## Where a move order to this cursor goes: the floor below a midair
## point, else the point itself. A flier takes only XZ from its
## destination (UnitMovement._query_destination puts it at its own
## altitude), so for it this is the same move as ground; a walker in the
## same selection gets the floor it can actually stand on.
func move_point() -> Variant:
	if on_plane and floor_below != null:
		return floor_below
	return ground


func describe() -> String:
	if unit:
		return "unit %s" % unit.name
	if interactable:
		return "interactable %s" % interactable.name
	if ground != null:
		return "ground %s" % ground
	return "nothing"
