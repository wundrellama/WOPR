extends Node3D
## Presentation only. A shot means "sent", never "succeeded"; only resolve()
## draws the green/red response. The caller owns requests and HUD messages.

const LOCK_COLOR := Color(0.22, 0.91, 1.0)
const FREEZE_COLOR := Color(0.55, 0.84, 1.0)
const RESUME_COLOR := Color(0.24, 1.0, 0.68)
const SMITE_COLOR := Color(1.0, 0.39, 0.26)
const AMBER_COLOR := Color(1.0, 0.73, 0.32)
const OK_COLOR := Color(0.32, 1.0, 0.52)
const REFUSED_COLOR := Color(1.0, 0.25, 0.30)
const FLASH_TIME := 0.12
const TAIL_TIME := 0.45

var _effects: Array[Dictionary] = []
var _ring_mesh: ImmediateMesh
var _ray_mesh: CylinderMesh
var _pending := false
var _last_impact := Vector3.ZERO
var _last_viewer: WeakRef
var _last_basis := Basis.IDENTITY


func _ready() -> void:
	set_process(not _effects.is_empty())


func lock_target(viewer: Camera3D, target_position: Vector3) -> void:
	if not _valid_viewer(viewer) or not target_position.is_finite():
		return
	_ensure_meshes()
	var muzzle := _muzzle(viewer)
	_spawn_ray(muzzle, target_position, LOCK_COLOR, 0.015, 0.32, 0.45)
	_spawn_ring(viewer, target_position, LOCK_COLOR, 0.38, 0.75, 1.55, 0.0)


func fire(viewer: Camera3D, target_position: Vector3, verb: String) -> void:
	if not _valid_viewer(viewer) or not target_position.is_finite():
		return
	var color: Color
	match verb:
		"freeze":
			color = FREEZE_COLOR
		"resume":
			color = RESUME_COLOR
		"smite":
			color = SMITE_COLOR
		_:
			return
	_ensure_meshes()
	_pending = true
	_last_impact = target_position
	_last_viewer = weakref(viewer)
	_last_basis = viewer.global_basis.orthonormalized()
	var muzzle := _muzzle(viewer)
	# A bright, short core inside a softer, longer tapered tracer.
	_spawn_ray(muzzle, target_position, color, 0.045, TAIL_TIME, 0.65)
	_spawn_ray(muzzle, target_position, color.lightened(0.35), 0.018, FLASH_TIME, 0.95)
	_spawn_ring(viewer, muzzle, color, FLASH_TIME, 0.04, 0.12, 0.0)
	if verb == "smite":
		# The packet travels along the outgoing shot. No impact burst is implied.
		var length := muzzle.distance_to(target_position)
		if length > 0.001:
			var direction := (target_position - muzzle) / length
			var packet_end := muzzle + direction * minf(2.0, length)
			var packet := _spawn_ray(muzzle, packet_end, AMBER_COLOR, 0.09, FLASH_TIME, 1.0)
			packet["travel"] = target_position - packet_end
			packet["origin"] = packet["node"].global_position
			# Dictionaries are shared; the effect already lives in _effects.


@warning_ignore("unused_parameter")
func resolve(ok: bool, message: String) -> void:
	# Keep the exact message in the caller's HUD; do not infer extra meaning.
	if not _pending:
		return
	_pending = false
	var viewer: Camera3D = null
	if _last_viewer != null:
		viewer = _last_viewer.get_ref() as Camera3D
	var color := OK_COLOR if ok else REFUSED_COLOR
	_spawn_ring(viewer, _last_impact, color, 0.60, 0.80, 2.10, 0.0)
	_spawn_ring(viewer, _last_impact, color, 0.60, 0.65, 1.90, 0.10)


func clear() -> void:
	# Invalidate the destination as well as the visuals, so a response received
	# after travel/cancellation cannot appear in the new world.
	_pending = false
	_last_impact = Vector3.ZERO
	_last_viewer = null
	_last_basis = Basis.IDENTITY
	for effect in _effects:
		var node: MeshInstance3D = effect["node"]
		if is_instance_valid(node):
			node.visible = false
			node.queue_free()
	_effects.clear()
	set_process(false)


func _process(delta: float) -> void:
	for index in range(_effects.size() - 1, -1, -1):
		var effect: Dictionary = _effects[index]
		var node: MeshInstance3D = effect["node"]
		var age: float = float(effect["age"]) + delta
		effect["age"] = age
		var delay: float = effect["delay"]
		var lifetime: float = effect["lifetime"]
		if not is_instance_valid(node) or age >= delay + lifetime:
			if is_instance_valid(node):
				node.queue_free()
			_effects.remove_at(index)
			continue
		node.visible = age >= delay
		if age < delay:
			continue
		var progress := clampf((age - delay) / lifetime, 0.0, 1.0)
		var material: StandardMaterial3D = effect["material"]
		var color: Color = effect["color"]
		color.a = float(effect["alpha"]) * pow(1.0 - progress, 1.4)
		material.albedo_color = color
		if effect["kind"] == "ring":
			var viewer_ref: WeakRef = effect["viewer"]
			var viewer := viewer_ref.get_ref() as Camera3D if viewer_ref != null else null
			var basis: Basis = effect["basis"]
			if _valid_viewer(viewer):
				basis = viewer.global_basis.orthonormalized()
			var radius := lerpf(float(effect["start_radius"]), float(effect["end_radius"]), progress)
			node.global_transform = Transform3D(basis.scaled(Vector3.ONE * radius), effect["impact"])
		else:
			if effect.has("travel"):
				node.global_position = effect["origin"] + effect["travel"] * progress
	set_process(not _effects.is_empty())


func _valid_viewer(viewer: Camera3D) -> bool:
	return is_instance_valid(viewer) and viewer.is_inside_tree() and is_inside_tree()


func _muzzle(viewer: Camera3D) -> Vector3:
	var basis := viewer.global_basis.orthonormalized()
	return viewer.global_position - basis.z * 4.0 + basis.x * 0.42 - basis.y * 0.28


func _ensure_meshes() -> void:
	if _ray_mesh == null:
		_ray_mesh = CylinderMesh.new()
		_ray_mesh.top_radius = 0.55
		_ray_mesh.bottom_radius = 1.0
		_ray_mesh.height = 1.0
		_ray_mesh.radial_segments = 10
		_ray_mesh.rings = 1
	if _ring_mesh != null:
		return
	# Shared annulus in local XY; no filled disc to obscure the target.
	_ring_mesh = ImmediateMesh.new()
	_ring_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for segment in range(64):
		var a := TAU * float(segment) / 64.0
		var b := TAU * float(segment + 1) / 64.0
		var outer_a := Vector3(cos(a), sin(a), 0.0)
		var outer_b := Vector3(cos(b), sin(b), 0.0)
		var inner_a := outer_a * 0.90
		var inner_b := outer_b * 0.90
		for vertex in [inner_a, outer_a, outer_b, inner_a, outer_b, inner_b]:
			_ring_mesh.surface_add_vertex(vertex)
	_ring_mesh.surface_end()


func _material(color: Color, alpha: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_color = Color(color.r, color.g, color.b, alpha)
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = 1.2
	material.no_depth_test = false
	return material


func _spawn_visual(mesh: Mesh, color: Color, alpha: float, lifetime: float) -> Dictionary:
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.material_override = _material(color, alpha)
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	node.top_level = true
	var effect := {"node": node, "material": node.material_override, "color": color,
		"alpha": alpha, "age": 0.0, "delay": 0.0, "lifetime": lifetime, "kind": "ray"}
	_effects.append(effect)
	set_process(true)
	return effect


func _spawn_ray(start: Vector3, end: Vector3, color: Color, radius: float, lifetime: float, alpha: float) -> Dictionary:
	var length := start.distance_to(end)
	if length < 0.001:
		return {}
	var effect := _spawn_visual(_ray_mesh, color, alpha, lifetime)
	var node: MeshInstance3D = effect["node"]
	# CylinderMesh's long axis is Y. Set a world transform only after parenting;
	# choose a nonparallel reference to handle shots straight up/down as well.
	var axis_y := (end - start) / length
	var reference := Vector3.RIGHT if absf(axis_y.dot(Vector3.UP)) > 0.98 else Vector3.UP
	var axis_x := reference.cross(axis_y).normalized()
	var axis_z := axis_x.cross(axis_y).normalized()
	node.global_transform = Transform3D(Basis(axis_x * radius, axis_y * length, axis_z * radius), (start + end) * 0.5)
	return effect


func _spawn_ring(viewer: Camera3D, impact: Vector3, color: Color, lifetime: float, start_radius: float, end_radius: float, delay: float) -> void:
	_ensure_meshes()
	var basis := _last_basis
	var viewer_ref: WeakRef = null
	if _valid_viewer(viewer):
		basis = viewer.global_basis.orthonormalized()
		viewer_ref = weakref(viewer)
		var distance_scale := clampf(viewer.global_position.distance_to(impact) / 100.0, 1.0, 8.0)
		start_radius *= distance_scale
		end_radius *= distance_scale
	# Small camera-facing offset keeps the annulus off the target's surface.
	var position := impact + basis.z * 0.16
	var effect := _spawn_visual(_ring_mesh, color, 0.90, lifetime)
	effect["kind"] = "ring"
	effect["viewer"] = viewer_ref
	effect["basis"] = basis
	effect["impact"] = position
	effect["start_radius"] = start_radius
	effect["end_radius"] = end_radius
	effect["delay"] = delay
	var node: MeshInstance3D = effect["node"]
	node.global_transform = Transform3D(basis.scaled(Vector3.ONE * start_radius), position)
	node.visible = delay <= 0.0
