extends GameArea
## The world the headless harness stands up when a suite says
## wants_world() (see AiTestCase). Not an area of the game: it lives under
## tests/fixtures rather than data/areas precisely so AreaDatabase's
## directory scan never lists it and nothing in the game can travel here.
##
## spawns_party() is false because the party is not what any of these
## suites are about. WorldManager._embody_into() reads it, and with it
## true every combat case that opts into a world would find the authored
## starting party standing in the middle of its fixture.
##
## Deliberately carries no class_name: a new class_name needs the editor
## class cache rescanned before a headless run can see it, and this script
## is only ever reached through the scene that already names it.


func spawns_party() -> bool:
	return false
