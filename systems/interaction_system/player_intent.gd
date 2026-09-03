class_name PlayerIntent
extends RefCounted
## What the next click MEANS. One object, derived fresh by ClickRouter
## from the state that already exists (see ClickRouter.intent()) — never
## stored anywhere, exactly like GameMode.current_mode().
##
## Before this, "what does this click mean" was answered independently in
## eight places: ground_click_target's own _unhandled_input, Unit.
## _on_input_event's physics-picked copy of the same question, the debug
## spawner's interceptor list, and five indicators that each re-derived
## the armed ability's targeting type every single frame to decide
## whether they were the one being aimed. Adding a targeting shape meant
## finding all of them; forgetting one is how movement_indicator.gd
## spent a while not knowing abilities existed at all.
##
## Now: the router derives ONE intent, the intent owns the click, and the
## intent NAMES the indicators that belong to it (indicator_ids). An
## indicator no longer asks whether it is the one — it is told.
##
## Subclasses live beside this file (IdleIntent, AimingIntent,
## LockedIntent) plus SpawningIntent under debug/, which is why
## push_intent takes a PlayerIntent rather than production code naming a
## debug tool.
##
## handle_left_click/handle_right_click take the router untyped on
## purpose: the router already depends on these classes, and typing the
## parameter the other way round would make that a cycle.


## Identity for change detection — ClickRouter compares kind() plus the
## ability, not object identity, so re-deriving the same intent object
## after object does not re-fire intent_changed.
func kind() -> StringName:
	return &"none"


## The ability being aimed, when the intent is about one. Null otherwise
## — declared here rather than only on AimingIntent so the router can
## compare any two intents without type-checking first.
var ability: Ability = null


## Returns whether the click was CONSUMED. False means "this intent had
## nothing to do with that click": the router leaves the event unhandled
## and it falls through to physics picking exactly as it would if this
## system did not exist (which is what keeps a click on the overworld
## avatar working).
func handle_left_click(_router, _hit: ClickHit) -> bool:
	return false


func handle_right_click(_router, _hit: ClickHit) -> bool:
	return false


## The ids of the indicators that should be live while this intent is
## current — see IndicatorBase.serves(). Anything not named goes dark.
func indicator_ids() -> Array[StringName]:
	return []


func describe() -> String:
	return "nothing"
