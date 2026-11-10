extends OmniLight3D

# The campfire's light breathes a little.


func _process(_delta: float) -> void:
	var t := Time.get_ticks_msec() * 0.001
	light_energy = 1.8 + sin(t * 11.0) * 0.2 + sin(t * 23.0) * 0.14
