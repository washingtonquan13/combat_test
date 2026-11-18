class_name SocketProfile
extends Resource

## Every socket a kind of body has, by meaning (SocketSpec), so a new body
## of that kind gets its grips, casting hand, head and sheaths without any
## nodes placed by hand. One profile serves every humanoid
## (data/sockets/humanoid.tres); a body of another kind names its own on
## CharacterModel.socket_profile, or gets none and holds nothing.

@export var sockets: Array[SocketSpec] = []
## The bone the fallback gaze turns (CharacterModel.look_at_modifier unset).
@export var gaze_bone: StringName = &"Head"


## Whether every socket finds its bones on this skeleton: the test for the
## default profile, which a body only gets when it is of that kind.
func fits(skeleton: Skeleton3D) -> bool:
	for spec: SocketSpec in sockets:
		if spec.place(skeleton).is_empty():
			return false
	return skeleton.find_bone(gaze_bone) != -1
