class_name IndicatorPalette
extends RefCounted
## The one palette for every world-space indicator and unit ring.
##
## Two axes, never mixed:
## - Answer colours say what a click would do: OK (white), OUT_OF_REACH
##   (grey: too far, beyond the move budget), BLOCKED (red: refused,
##   walled, invalid). Red means "no" everywhere and nothing else.
## - Relation colours say who a unit is to the party: PARTY blue,
##   ENEMY vermillion, NEUTRAL yellow (Okabe-Ito, safe for the common
##   colour-blind types). State (hovered, selected, active turn) is shown
##   by brightness and thickness, never by a new hue.

const OK: Color = Color(1.0, 1.0, 1.0, 0.9)
const OUT_OF_REACH: Color = Color(0.55, 0.55, 0.58, 0.65)
const BLOCKED: Color = Color(0.9, 0.3, 0.15, 0.9)
const NO_TARGET: Color = Color(0.7, 0.7, 0.7, 0.35)
## Dark edge under ribbons so they read on bright ground.
const EDGE: Color = Color(0.0, 0.0, 0.0, 0.55)

const PARTY: Color = Color(0.34, 0.71, 0.91, 1.0)
const ENEMY: Color = Color(0.84, 0.37, 0.0, 1.0)
const NEUTRAL: Color = Color(0.94, 0.89, 0.26, 1.0)
## The active-turn marker. Gold, distinct from every relation colour.
const ACTIVE_TURN: Color = Color(1.0, 0.82, 0.35, 1.0)
