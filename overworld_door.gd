class_name OverworldDoor
extends Area3D
## Authored, walk-in overworld exit — reads its own AreaExit child (see
## area_exit.gd) for where "in" leads, same trigger shape the old
## procedurally-generated door used. Reproduces its two constraints:
##
## The PRIMED guard: without it, the instant this door's collider starts
## overlapping the avatar it was just spawned on top of (returning from
## wherever it leads), body_entered would fire again and bounce straight
## back. A door not matching the avatar's spawn point starts primed=true
## (a real approach should trigger normally); overworld.gd flips a
## matching door to primed=false right after placing the avatar on it
## (see set_primed() below), and body_exited flips it back the moment
## the avatar actually walks off.
##
## The DEFERRED load: body_entered fires from WITHIN the physics
## server's own callback, and the load this triggers synchronously frees
## this exact world — including this door's own CollisionObject3D via
## WorldManager's remove_child(). Godot disallows removing a
## CollisionObject3D mid-physics-callback; AreaExit.travel() defers the
## actual load to the next idle frame for exactly this reason.

var _primed: bool = true


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


func set_primed(value: bool) -> void:
	_primed = value


func _on_body_exited(body: Node3D) -> void:
	if body is OverworldAvatar:
		_primed = true


func _on_body_entered(body: Node3D) -> void:
	if not body is OverworldAvatar or not _primed:
		return
	var exit: AreaExit = AreaExit.find_on(self)
	if exit:
		exit.travel()
