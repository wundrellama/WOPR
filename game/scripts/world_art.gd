extends RefCounted
## Presentation-only geometry. No colliders, input or telemetry side effects.
const CYAN := Color("72d9d4")
const AMBER := Color("e6b673")
const ICE := Color("a9cddd")
const VIOLET := Color("9c91cb")
const EMBER := Color("ee8a60")
const EDGES = preload("res://shaders/architecture.gdshader")


static func process_height(mem_mb: float, pid: int) -> float:
	var height := clampf(12.0 + log(maxf(mem_mb, 1.0)) * 6.0, 12.0, 120.0)
	# Init is the capital landmark; all other towers retain the RAM mapping.
	return maxf(height, 145.0) if pid == 1 else height


static func material(color: Color, activity: float = 0.25) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color.darkened(0.91)
	mat.metallic = 0.6
	mat.roughness = 0.38
	mat.emission_enabled = true
	mat.emission = color * 0.025
	var trim := ShaderMaterial.new()
	trim.shader = EDGES
	trim.set_shader_parameter("signal_color", color)
	trim.set_shader_parameter("activity", activity)
	mat.next_pass = trim
	return mat


static func update_material(mat: StandardMaterial3D, color: Color, activity: float) -> void:
	mat.albedo_color = color.darkened(0.89)
	mat.emission = color * (0.025 + activity * 0.04)
	if mat.next_pass is ShaderMaterial:
		mat.next_pass.set_shader_parameter("signal_color", color)
		mat.next_pass.set_shader_parameter("activity", activity)


static func light_material(color: Color, energy: float = 1.0) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color * energy
	return mat


static func mesh_node(parent: Node3D, mesh: Mesh, pos: Vector3, mat: Material) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.material_override = mat
	node.position = pos
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(node)
	return node


static func box(parent: Node3D, pos: Vector3, size: Vector3, mat: Material) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	return mesh_node(parent, mesh, pos, mat)


static func ring(parent: Node3D, pos: Vector3, radius: float, color: Color, width: float = 1.2) -> MeshInstance3D:
	var mesh := TorusMesh.new()
	mesh.inner_radius = radius - width
	mesh.outer_radius = radius + width
	mesh.rings = 96
	mesh.ring_segments = 6
	return mesh_node(parent, mesh, pos, light_material(color, 1.5))


static func dais(parent: Node3D, center: Vector3, radius: float, color: Color) -> void:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius + 8.0
	mesh.height = 12.0
	mesh.radial_segments = 64
	mesh_node(parent, mesh, center + Vector3(0, 6, 0), material(color, 0.1))
	ring(parent, center + Vector3(0, 12.4, 0), radius, color.darkened(0.3), 0.8)


static func build_districts(parent: Node3D, cores: Array, harbor_x: float, vaults_x: float, plains_z: float, forge_z: float) -> void:
	# The capital: two broken-scale orbital rings and a raised dark foundation.
	dais(parent, Vector3.ZERO, 275, VIOLET)
	ring(parent, Vector3(0, 17, 0), 265, VIOLET, 1.3)
	ring(parent, Vector3(0, 18, 0), 148, AMBER, 0.75)
	for i in 48:
		var a := TAU * float(i) / 48.0
		var mark := box(parent, Vector3(cos(a) * 280, 19, sin(a) * 280),
			Vector3(1.0, 2.0, 9.0 if i % 4 == 0 else 4.0), light_material(VIOLET.darkened(0.2)))
		mark.rotation.y = -a + PI / 2.0
	# Init is a distinct architectural landmark; the live PID remains the target.
	ring(parent, Vector3(0, 120, 0), 38, AMBER, 0.7)
	ring(parent, Vector3(0, 32, 0), 55, AMBER, 1.2)
	# CPU islands give scattered processes an actual street plan and scale.
	for i in cores.size():
		var p: Vector3 = cores[i].position
		dais(parent, Vector3(p.x, 0, p.z), 39, ICE.darkened(0.35))
		for side in [-1.0, 1.0]:
			box(parent, Vector3(p.x + side * 39, 14, p.z), Vector3(0.6, 0.8, 32), light_material(ICE.darkened(0.5)))
	# A navigable harbor ring and tall paired gate pylons on its ocean edge.
	dais(parent, Vector3(harbor_x, 0, 0), 235, CYAN)
	ring(parent, Vector3(harbor_x, 14, 0), 212, CYAN, 0.7)
	for i in 7:
		var z := (float(i) - 3.0) * 65.0
		box(parent, Vector3(harbor_x - 170, 43, z), Vector3(8, 60, 8), material(CYAN, 0.4))
	# Vaults have a heavy, amber industrial sill. Their live boxes still pick.
	box(parent, Vector3(vaults_x, 6, 0), Vector3(115, 12, 570), material(AMBER, 0.1))
	for side in [-1.0, 1.0]:
		box(parent, Vector3(vaults_x + side * 54, 14, 0), Vector3(1.2, 1.0, 570), light_material(AMBER))
	# The forge: a crown of heat fins around a suspended reactor.
	dais(parent, Vector3(0, 0, forge_z), 130, EMBER)
	ring(parent, Vector3(0, 18, forge_z), 115, EMBER, 1.6)
	ring(parent, Vector3(0, 78, forge_z), 52, EMBER, 1.0)
	for i in 10:
		var a := TAU * float(i) / 10.0
		var fin := box(parent, Vector3(cos(a) * 76, 45, forge_z + sin(a) * 76),
			Vector3(7, 70, 22), material(EMBER, 0.4))
		fin.rotation.y = -a
	# Sparse mile markers connect the districts without another wall of labels.
	for i in 9:
		var z := 60.0 + float(i) * 44.0
		for side in [-1.0, 1.0]:
			box(parent, Vector3(side * 12.0, 10, z), Vector3(0.7, 2, 5), light_material(ICE.darkened(0.5)))
