class_name SceneBinding
extends Resource
## Which dialogue nodes have a staged scene, kept OUT of the dialogue.
##
## This is the one structural thing the BG3 study said Larian got most
## right: content and presentation split by id, joined by a separate file.
## A conversation says what is said and what it branches on; a binding says
## how one of its moments is shot. Neither has to know the other exists.
##
## What it buys, concretely:
##   - a scene can be re-staged without touching a narrative file
##   - a line can ship with no staging and gain some later, which is most
##     barks and every minor NPC
##   - re-recording and localisation never open a cinematic file
##   - two stagings of one conversation become possible
##
## DEMOTED FROM ARCHITECTURAL. In drafts 1 and 2 this was the seam the
## whole design hung from, because dialogue was the spine. It is not — this
## is how ONE caller locates its scenes. Fusion, area arrivals and combat
## openings never look here; they hold their scene directly.

## Dialogue node id -> the scene to stage for it.
@export var scenes: Dictionary = {}


func scene_for(node_id: String) -> CinematicScene:
	if node_id == "":
		return null
	var found: Variant = scenes.get(node_id)
	return found if found is CinematicScene else null


func binds(node_id: String) -> bool:
	return scene_for(node_id) != null
