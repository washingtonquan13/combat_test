class_name InteractionOption
extends Resource
## Base for one composable right-click verb ("Attack", "Examine", "Open",
## ...). Same discipline as this project's AbilityTargeting/AbilityEffect/
## PrerequisiteRule: the data (a subclass's own @export fields) and the
## logic that interprets it live together on the same resource, instead of
## a data resource with the evaluation logic living somewhere else.
##
## Composed onto anything interactable via that node's own `interactions:
## Array[InteractionOption]` export (see Unit.interactions,
## InteractableProp.interactions) — reused as-is across every instance
## that wants the same verb, same convention as Unit.abilities.
##
## Not every subclass needs both target's actual type checked the same
## way — target's real type depends on what interactable it came from
## (a Unit for AttackInteraction, potentially any Node for a generic verb
## like ExamineInteraction) — same "callers already filtered the obvious
## stuff" contract AbilityTargeting.is_valid_target documents.

@export var label: String
@export var icon: Texture2D


## Whether this verb should appear in actor's context menu for target
## right now. Called fresh every time the menu opens (see
## InteractionMenu.open_for) — never cached, so it can't go stale between
## two clicks (hostility, HP, distance, whatever a subclass cares about
## may have changed in between).
func is_available(_actor: Unit, _target) -> bool:
	push_error("%s doesn't implement is_available() yet" % get_script().resource_path)
	return false


## Runs the verb once the player picks it from the menu.
func execute(_actor: Unit, _target) -> void:
	push_error("%s doesn't implement execute() yet" % get_script().resource_path)
