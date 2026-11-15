class_name InteractionApproach
extends Node
## A verb picked out of reach: the actor walks to the target, the rest of
## the party follows in formation, and the verb runs on arrival (BG3's
## "click a door across the room"). Lives as a child of the actor for as
## long as the walk lasts, so it goes with the actor wherever the actor
## goes (freed with its world, gone if it dies) and an actor has at most
## one: picking another verb replaces it.
##
## Out of combat only. In a fight a walk spends movement and wants a path
## preview first, so there a verb still runs where the actor stands.
##
## Called off by anything that makes the walk meaningless, every frame:
##   - another order: the actor's route stops ending where this one sent
##     it (a ground click, another group move), whoever issued it;
##   - the target is gone or dead, or the verb is no longer on offer (an
##     NPC turned hostile);
##   - the actor dies or a fight takes it in;
##   - no route: the move was refused, or the actor stopped short and the
##     target had not moved, so walking again would end in the same spot.
## A target that moved is walked to again, a few times.

const NODE_NAME: StringName = &"InteractionApproach"
## How many times a stop short of a moving target sends the actor again.
const RETRIES: int = 3
## How far a route's end may move before it is someone else's order.
const OWN_ROUTE_SLACK: float = 0.3
## How far a target must have moved for one more walk to be worth it.
const TARGET_MOVED: float = 0.5

var option: InteractionOption
var actor: Unit
var target: Node3D
var _route_end: Vector3
var _sent_toward: Vector3
var _retries_left: int = RETRIES


## Runs option for actor on target, walking into its reach first when
## the actor is out of it and out of combat. The one way a picked verb is
## run (InteractionMenu, a left click on someone to talk to).
static func run(option: InteractionOption, actor: Unit, target: Node) -> void:
	cancel_for(actor)
	if option.reach <= 0.0 or actor.in_combat() or not target is Node3D \
			or option.in_reach(actor, target):
		option.execute(actor, target)
		return
	var approach := InteractionApproach.new()
	approach.name = NODE_NAME
	approach.option = option
	approach.actor = actor
	approach.target = target
	actor.add_child(approach)
	if not approach._send():
		SystemLog.print("%s can't reach %s." % [actor.get_display_name(), _name_of(target)])
		approach._finish()


## The walk actor is on to run a verb, or null.
static func of(actor: Unit) -> InteractionApproach:
	if not is_instance_valid(actor):
		return null
	var found: Node = actor.get_node_or_null(NodePath(NODE_NAME))
	return found as InteractionApproach if found and not found.is_queued_for_deletion() else null


static func cancel_for(actor: Unit) -> void:
	var approach: InteractionApproach = of(actor)
	if approach:
		approach.name = &"InteractionApproachDone"
		approach.queue_free()


func _physics_process(_delta: float) -> void:
	if not _still_wanted():
		_finish()
		return
	if actor.is_moving():
		var route: Dictionary = actor.current_route()
		if not route.is_empty() and _flat(route.path[route.path.size() - 1]).distance_to(_flat(_route_end)) > OWN_ROUTE_SLACK:
			_finish()
			return
		if option.in_reach(actor, target):
			actor.stop_moving()
			_arrive()
		return
	if option.in_reach(actor, target):
		_arrive()
	elif _retries_left > 0 and _flat(target.global_position).distance_to(_flat(_sent_toward)) > TARGET_MOVED and _send():
		_retries_left -= 1
	else:
		SystemLog.print("%s can't reach %s." % [actor.get_display_name(), _name_of(target)])
		_finish()


func _still_wanted() -> bool:
	if not is_instance_valid(actor) or not actor.is_alive() or actor.in_combat():
		return false
	if not is_instance_valid(target) or not target.is_inside_tree():
		return false
	if target is Unit and not (target as Unit).is_alive():
		return false
	return option.is_available(actor, target)


## Sends the actor (and whoever moves with it) to stand within reach on
## its own side of the target. Returns whether a route came of it.
func _send() -> bool:
	_sent_toward = target.global_position
	var destination: Vector3 = _stand_point()
	var movers: Array[Unit] = []
	if actor in SelectionManager.selected_units:
		movers = ClickRouter.move_order_units()
	if actor not in movers:
		movers = [actor]
	FormationPlanner.command_group_move(movers, destination, actor)
	var route: Dictionary = actor.current_route()
	if route.is_empty() or route.path.is_empty():
		return false
	_route_end = route.path[route.path.size() - 1]
	return true


## Half the reach short of the target's body, on the line from it to the
## actor: inside the reach, with the target between the actor and nobody.
func _stand_point() -> Vector3:
	var from: Vector3 = target.global_position
	var away: Vector3 = _flat(actor.global_position - from)
	away = away.normalized() if away.length() > 0.01 else Vector3.BACK
	var body: float = (target as Unit).radius if target is Unit else 0.0
	return from + away * (body + actor.radius + option.reach * 0.5)


func _arrive() -> void:
	var o: InteractionOption = option
	var a: Unit = actor
	var t: Node3D = target
	_finish()
	o.execute(a, t)


func _finish() -> void:
	set_physics_process(false)
	name = &"InteractionApproachDone"
	queue_free()


static func _flat(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z)


static func _name_of(node: Node) -> String:
	return (node as Unit).get_display_name() if node is Unit else String(node.name)
