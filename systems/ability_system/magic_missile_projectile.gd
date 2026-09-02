extends Node3D
## Visual for the Magic Missile projectile (see PathedProjectileStep,
## abilities/magic_missile.tres) — a small SHADED, glowing bolt with a
## short, continuously-fading particle trail behind it. Built in code
## rather than as hand-placed scene sub-resources, matching how every
## other VFX/indicator visual in this project builds its own meshes at
## runtime (see IndicatorBase._create_line_mesh, area_indicator.gd).
##
## Shaded deliberately, unlike the movement indicator's unshaded ribbon
## (render_mode unshaded, see movement_indicator_line.gdshader) — this
## is a solid object flying through lit space, not a decal painted on
## the ground, so it should actually respond to scene lighting. It still
## reads as bright via emission (bloom is already project-wide, see
## main.tscn's WorldEnvironment) rather than needing an unshaded/emissive
## trick to look lit from within.
##
## The trail is deliberately NOT permanent — each particle has a short
## lifetime and fades to transparent via color_ramp, so it continuously
## ages out as the bolt travels instead of leaving a lingering streak.

@export var bolt_color: Color = Color(0.55, 0.35, 1.0)
@export var bolt_radius: float = 0.12
@export var trail_lifetime: float = 0.35
@export var trail_amount: int = 24


func _ready() -> void:
	_build_bolt()
	_build_trail()


## Tapered, not a plain sphere — a sphere is rotationally symmetric, so
## PathedProjectileStep's yaw-per-frame rotation (see that file) would be
## mathematically correct but completely invisible on one. CylinderMesh's
## long axis is +Y by default; the mesh_instance's own local -90° X
## rotation below points the narrow (top_radius) end toward local -Z,
## which is the wrapper's forward — the tip leads the direction of
## travel once PathedProjectileStep aims the wrapper. Bottom-heavy taper
## (bottom_radius > top_radius) so the wide end trails toward the trail
## particles behind it.
func _build_bolt() -> void:
	var mesh_instance := MeshInstance3D.new()
	add_child(mesh_instance)
	mesh_instance.rotation.x = deg_to_rad(-90.0)

	var dart := CylinderMesh.new()
	dart.top_radius = bolt_radius * 0.25
	dart.bottom_radius = bolt_radius
	dart.height = bolt_radius * 4.0
	mesh_instance.mesh = dart

	var mat := StandardMaterial3D.new()
	mat.albedo_color = bolt_color
	mat.emission_enabled = true
	mat.emission = bolt_color
	mat.emission_energy_multiplier = 4.0
	mesh_instance.material_override = mat


## GPUParticles3D in world space (local_coords = false) so previously-
## emitted particles stay behind at the world position they were spawned
## at, rather than riding along with the bolt — that's what actually
## reads as a trail rather than a cloud following the mesh around.
## visibility_aabb is set generously wide/deep because the default box
## is sized for a stationary emitter; a fast-moving world-space trail
## can extend well past it and silently get frustum-culled otherwise.
func _build_trail() -> void:
	var particles := GPUParticles3D.new()
	add_child(particles)

	particles.emitting = true
	particles.amount = trail_amount
	particles.lifetime = trail_lifetime
	particles.local_coords = false
	particles.draw_order = GPUParticles3D.DRAW_ORDER_LIFETIME
	particles.visibility_aabb = AABB(Vector3(-8, -8, -8), Vector3(16, 16, 16))

	var mesh := SphereMesh.new()
	mesh.radius = bolt_radius * 0.5
	mesh.height = bolt_radius
	particles.draw_pass_1 = mesh

	var process_mat := ParticleProcessMaterial.new()
	process_mat.direction = Vector3(0, 0, 0)
	process_mat.spread = 10.0
	process_mat.initial_velocity_min = 0.0
	process_mat.initial_velocity_max = 0.3
	process_mat.gravity = Vector3.ZERO
	process_mat.scale_min = 1.0
	process_mat.scale_max = 1.0

	var gradient := Gradient.new()
	gradient.colors = PackedColorArray([
		Color(bolt_color.r, bolt_color.g, bolt_color.b, 0.8),
		Color(bolt_color.r, bolt_color.g, bolt_color.b, 0.0),
	])
	var gradient_texture := GradientTexture1D.new()
	gradient_texture.gradient = gradient
	process_mat.color_ramp = gradient_texture

	particles.process_material = process_mat

	var trail_mat := StandardMaterial3D.new()
	trail_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	trail_mat.vertex_color_use_as_albedo = true
	trail_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	trail_mat.emission_enabled = true
	trail_mat.emission = bolt_color
	trail_mat.emission_energy_multiplier = 3.0
	particles.material_override = trail_mat
