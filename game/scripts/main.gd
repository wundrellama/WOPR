extends Node3D
## Frameshift v0.2 — the world is your machine, with geography.
##
## Districts (logical layout):
##   KERNEL RING   — kernel spirits circle the Init God at the world's heart
##   CPU PLAINS    — one pillar per core; processes cluster on the core they run on
##   NETWORK HARBOR— towers for remote hosts, light-roads carry real connections
##   FILE VAULTS   — a monolith per mount, height = fill %
##   GPU FORGE     — one great furnace, glow = GPU busy%
##   THE TIDE      — memory pressure is a literal water level over the plain
##
## F freezes (SIGSTOP), C resumes (SIGCONT), Shift+K smites (SIGKILL).
## These are real syscalls against real PIDs.

const API := "http://127.0.0.1:8765"

var world_http: HTTPRequest
var action_http: HTTPRequest
var poll_timer: Timer
var world: Dictionary = {}
var monoliths: Dictionary = {}   # pid -> StaticBody3D (processes)
var bob_phase: Dictionary = {}   # pid -> float
var pickables: Dictionary = {}   # StaticBody3D -> hover info dict
var core_bodies: Array = []      # core index -> StaticBody3D
var selected_pid: int = -1
var last_action := ""

var camera: Camera3D
var yaw := 0.0
var pitch := -0.35
var env: Environment
var hud: Label
var crosshair: Label
var hover_label: Label
var hover_pid: int = -1

var built_geo := false
var water: MeshInstance3D
var forge_body: StaticBody3D = null
var tower_bodies: Dictionary = {}  # ip -> StaticBody3D

# --- vault interiors ---
var world_root: Node3D
var vault_root: Node3D
var list_http: HTTPRequest
var mode := "world"            # "world" | "vault"
var vault_path := ""
var vault_parent := ""
var vault_bodies: Dictionary = {}  # StaticBody3D -> entry dict
var erase_hold_start := -1.0       # msec when X was pressed, -1 = not held
var hover_mount_path := ""         # vault path under crosshair in world mode
const ERASE_HOLD_MS := 1000.0

func _ready() -> void:
	world_http = HTTPRequest.new()
	add_child(world_http)
	world_http.request_completed.connect(_on_world)
	action_http = HTTPRequest.new()
	add_child(action_http)
	action_http.request_completed.connect(_on_action)
	list_http = HTTPRequest.new()
	add_child(list_http)
	list_http.request_completed.connect(_on_listing)
	world_root = Node3D.new()
	add_child(world_root)
	vault_root = Node3D.new()
	vault_root.visible = false
	add_child(vault_root)
	poll_timer = Timer.new()
	poll_timer.wait_time = 1.0
	add_child(poll_timer)
	poll_timer.timeout.connect(_poll_world)
	_poll_world()

	# --- environment ---
	var we := WorldEnvironment.new()
	env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.15, 0.2, 0.35)
	env.ambient_light_energy = 0.6
	env.fog_enabled = true
	env.fog_light_color = Color(0.03, 0.05, 0.1)
	env.fog_density = 0.0035
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, 35, 0)
	sun.light_energy = 0.8
	sun.light_color = Color(0.7, 0.8, 1.0)
	add_child(sun)

	var floor_mesh := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(3000, 3000)
	var fmat := StandardMaterial3D.new()
	fmat.albedo_color = Color(0.04, 0.06, 0.10)
	fmat.emission_enabled = true
	fmat.emission = Color(0.01, 0.03, 0.06)
	floor_mesh.material_override = fmat
	floor_mesh.mesh = pm
	add_child(floor_mesh)

	# --- the tide (memory water) ---
	water = MeshInstance3D.new()
	var wpm := PlaneMesh.new()
	wpm.size = Vector2(3000, 3000)
	var wmat := StandardMaterial3D.new()
	wmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	wmat.albedo_color = Color(0.1, 0.35, 0.7, 0.35)
	wmat.emission_enabled = true
	wmat.emission = Color(0.05, 0.2, 0.5)
	water.material_override = wmat
	water.mesh = wpm
	water.position = Vector3(0, 5, 0)
	add_child(water)

	# --- player ---
	camera = Camera3D.new()
	camera.position = Vector3(0, 120, 520)
	add_child(camera)
	camera.current = true
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	# --- HUD ---
	hud = Label.new()
	hud.position = Vector2(16, 12)
	hud.add_theme_font_size_override("font_size", 14)
	hud.add_theme_color_override("font_color", Color(0.7, 0.9, 1.0))
	add_child(hud)

	crosshair = Label.new()
	crosshair.text = "+"
	crosshair.add_theme_font_size_override("font_size", 22)
	crosshair.add_theme_color_override("font_color", Color(0.9, 1.0, 1.0, 0.9))
	add_child(crosshair)

	hover_label = Label.new()
	hover_label.add_theme_font_size_override("font_size", 15)
	hover_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hover_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	add_child(hover_label)


func _poll_world() -> void:
	world_http.request(API + "/world.json")


func _on_world(_result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if code != 200:
		return
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("procs"):
		return
	world = parsed
	if not built_geo:
		_build_geography()
		built_geo = true
	_sync_procs()
	_update_geo()
	_update_hud()


# ---------------------------------------------------------------- geography

func _add_box(pos: Vector3, size: Vector3, color: Color, info: Dictionary) -> StaticBody3D:
	var body := StaticBody3D.new()
	var m := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	m.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.emission_enabled = true
	mat.albedo_color = color
	mat.emission = color * 0.4
	m.material_override = mat
	body.add_child(m)
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	body.add_child(cs)
	body.position = pos
	world_root.add_child(body)
	pickables[body] = info
	return body


func _add_label(text: String, pos: Vector3, color: Color) -> void:
	var l := Label3D.new()
	l.text = text
	l.font_size = 64
	l.pixel_size = 0.02
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.outline_size = 8
	l.outline_modulate = Color(0, 0, 0, 0.8)
	l.modulate = color
	l.position = pos
	world_root.add_child(l)


func _build_geography() -> void:
	var ncores: int = int(world["cpu"]["count"])
	# CPU PLAINS: grid of core pillars, north of center
	var cols := ceili(sqrt(float(ncores)))
	for i in ncores:
		var row := i / cols
		var col := i % cols
		var p := Vector3((col - cols / 2.0) * 70.0, 18, 300.0 + row * 70.0)
		var body := _add_box(p, Vector3(10, 36, 10),
			Color(0.55, 0.75, 1.0), {"kind": "core", "core": i})
		core_bodies.append(body)
	_add_label("CPU PLAINS — %d cores" % ncores, Vector3(0, 80, 300), Color(0.55, 0.75, 1.0))

	# NETWORK HARBOR: west
	_add_label("NETWORK HARBOR", Vector3(-450, 90, 0), Color(0.2, 0.9, 0.8))

	# FILE VAULTS: east
	_add_label("FILE VAULTS", Vector3(450, 90, 0), Color(0.95, 0.75, 0.4))
	var mounts: Array = world.get("hw", {}).get("mounts", [])
	for i in mounts.size():
		var mnt: Dictionary = mounts[i]
		var pct: float = float(mnt["percent"])
		var h: float = maxf(6.0, pct * 0.9)
		var z := (float(i) - float(mounts.size()) / 2.0) * 60.0
		_add_box(Vector3(450, h / 2.0, z), Vector3(28, h, 28),
			Color(0.95, 0.75, 0.4), {"kind": "mount", "mnt": mnt})

	# GPU FORGE: south
	var forge_pos := Vector3(0, 30, -320)
	forge_body = _add_box(forge_pos, Vector3(60, 60, 60),
		Color(1.0, 0.4, 0.15), {"kind": "forge"})
	_add_label("GPU FORGE", forge_pos + Vector3(0, 55, 0), Color(1.0, 0.5, 0.2))

	# KERNEL RING label
	_add_label("KERNEL RING", Vector3(0, 110, 0), Color(0.75, 0.55, 1.0))


func _tower_pos(idx: int, total: int) -> Vector3:
	var t := idx / maxf(float(total - 1), 1.0)
	var ang := lerpf(deg_to_rad(-75.0), deg_to_rad(75.0), t)
	return Vector3(-450.0, 0, 0) + Vector3(cos(ang) * 140.0, 0, sin(ang) * 280.0)


func _update_geo() -> void:
	# tide: memory percent -> water height
	var mem_pct: float = float(world["mem"]["percent"])
	water.position.y = lerpf(0.5, 40.0, mem_pct / 100.0)

	# forge glow: gpu busy
	if forge_body != null:
		var busy: float = clampf(float(world.get("hw", {}).get("gpu_busy", 0)) / 100.0, 0.0, 1.0)
		var fmat: StandardMaterial3D = forge_body.get_child(0).material_override
		fmat.emission = Color(1.0, 0.4, 0.15) * (0.15 + busy * 0.85)

	# core pillar glow = per-core load
	var per_core: Array = world.get("cpu", {}).get("per_core", [])
	for i in core_bodies.size():
		var load: float = 0.0
		if i < per_core.size():
			load = clampf(float(per_core[i]) / 100.0, 0.0, 1.0)
		var cmat: StandardMaterial3D = core_bodies[i].get_child(0).material_override
		cmat.emission = Color(0.55, 0.75, 1.0).lerp(Color(1.0, 0.4, 0.2), load) * (0.3 + load * 0.7)

	# network towers + light-roads
	var remotes: Array = world.get("net", {}).get("remote_hosts", [])
	var seen := {}
	for i in remotes.size():
		var r: Dictionary = remotes[i]
		var ip: String = r["ip"]
		seen[ip] = true
		var h: float = clampf(8.0 + float(r["count"]) * 1.5, 8.0, 80.0)
		var pos := _tower_pos(i, remotes.size())
		var body: StaticBody3D
		if tower_bodies.has(ip):
			body = tower_bodies[ip]
			body.position = Vector3(pos.x, h / 2.0, pos.z)
		else:
			body = _add_box(Vector3(pos.x, h / 2.0, pos.z),
				Vector3(14, h, 14), Color(0.2, 0.9, 0.8), {"kind": "tower", "remote": r})
			tower_bodies[ip] = body
			# light-road from world center to tower
			var road := MeshInstance3D.new()
			var rbm := BoxMesh.new()
			rbm.size = Vector3(1, 1.5, 1)
			road.mesh = rbm
			var rmat := StandardMaterial3D.new()
			rmat.emission_enabled = true
			rmat.albedo_color = Color(0.2, 0.9, 0.8)
			rmat.emission = Color(0.2, 0.9, 0.8) * 0.6
			road.material_override = rmat
			var mid := Vector3(pos.x / 2.0, 2.0, pos.z / 2.0)
			road.position = mid
			road.scale = Vector3(1.5, 1.5, maxf(mid.length() * 2.0, 1.0))
			world_root.add_child(road)
			road.look_at(Vector3(pos.x, 2.0, pos.z))
		var tmat: StandardMaterial3D = body.get_child(0).material_override
		tmat.emission = Color(0.2, 0.9, 0.8) * (0.2 + clampf(float(r["count"]) / 20.0, 0.0, 0.8))
	for ip in tower_bodies.keys():
		if not seen.has(ip):
			pickables.erase(tower_bodies[ip])
			tower_bodies[ip].queue_free()
			tower_bodies.erase(ip)


# ---------------------------------------------------------------- processes

func _district_pos(p: Dictionary) -> Vector3:
	var pid: int = p["pid"]
	var h1 := (pid * 2654435761) % 4093
	var h2 := (pid * 40503) % 4099
	if pid == 1:
		return Vector3.ZERO
	if p["ppid"] == 2 or (p["ppid"] == 1 and str(p["name"]).begins_with("[")):
		# kernel spirits: ring around the Init God
		var ang := lerpf(0, TAU, float(h1 % 1000) / 1000.0)
		var rad := 110.0 + float(h2 % 100) * 0.6
		return Vector3(cos(ang) * rad, 0, sin(ang) * rad)
	var cn: int = int(p.get("cpu_num", -1))
	if cn >= 0 and cn < core_bodies.size():
		# cluster around the core pillar it actually runs on
		var base: Vector3 = core_bodies[cn].position
		return Vector3(base.x + float(h1 % 50) - 25.0, 0, base.z + float(h2 % 50) - 25.0)
	# wanderers (no cpu affinity info): between center and plains
	return Vector3(float(h1 % 160) - 80.0, 0, 140.0 + float(h2 % 80))


func _sync_procs() -> void:
	var alive := {}
	for p in world["procs"]:
		var pid: int = p["pid"]
		alive[pid] = true
		var mem_mb: float = float(p["mem_rss"]) / 1048576.0
		var height: float = clampf(2.0 + log(maxf(mem_mb, 1.0)) * 3.0, 2.0, 90.0)
		var cpu: float = clampf(float(p["cpu"]) / 100.0, 0.0, 1.0)
		var frozen: bool = p["state"] == "T"
		var pos := _district_pos(p)
		var m: MeshInstance3D
		if monoliths.has(pid):
			m = monoliths[pid].get_child(0)
		else:
			var body := StaticBody3D.new()
			m = MeshInstance3D.new()
			var bm := BoxMesh.new()
			bm.size = Vector3.ONE
			m.mesh = bm
			var mat := StandardMaterial3D.new()
			mat.emission_enabled = true
			m.material_override = mat
			body.add_child(m)
			var cs := CollisionShape3D.new()
			var shape := BoxShape3D.new()
			shape.size = Vector3.ONE
			cs.shape = shape
			body.add_child(cs)
			world_root.add_child(body)
			monoliths[pid] = body
			pickables[body] = {"kind": "proc", "pid": pid}
			bob_phase[pid] = randf() * TAU
		var body3d: StaticBody3D = monoliths[pid]
		body3d.position = Vector3(pos.x, height / 2.0, pos.z)
		m.scale = Vector3(6.0, height, 6.0)
		body3d.get_child(1).shape.size = Vector3(6.0, height, 6.0)
		var mat2: StandardMaterial3D = m.material_override
		if frozen:
			mat2.albedo_color = Color(0.25, 0.28, 0.32)
			mat2.emission = Color(0.05, 0.06, 0.08)
		else:
			var base := _species_color(p)
			if pid == selected_pid:
				base = Color(1.0, 0.85, 0.2)  # locked target = gold
			mat2.albedo_color = base.darkened(0.35 - cpu * 0.35)
			mat2.emission = base * (0.15 + cpu * 0.65)
	for pid in monoliths.keys():
		if not alive.has(pid):
			pickables.erase(monoliths[pid])
			monoliths[pid].queue_free()
			monoliths.erase(pid)
			bob_phase.erase(pid)
			if pid == selected_pid:
				selected_pid = -1


# ---------------------------------------------------------------- species

## Species taxonomy — what KIND of creature this monolith is.
## Kernel spirits are born of kthreadd (pid 2).
func _species(p: Dictionary) -> Dictionary:
	var pid: int = p["pid"]
	if pid == 0:
		return {"name": "The Void", "color": Color(0.5, 0.0, 0.6)}
	if pid == 1:
		return {"name": "The Init God", "color": Color(1.0, 0.85, 0.0)}
	if p["ppid"] == 2 or (p["ppid"] == 1 and str(p["name"]).begins_with("[")):
		return {"name": "Kernel Spirit", "color": Color(0.6, 0.3, 0.9)}
	var user := str(p["user"])
	if user == "root":
		return {"name": "System Daemon", "color": Color(0.2, 0.75, 0.45)}
	if user == str(world.get("me", {}).get("user", "")):
		return {"name": "Your Kin", "color": Color(0.2, 0.8, 1.0)}
	if user == "nobody" or user == "?":
		return {"name": "Wraith", "color": Color(0.8, 0.2, 0.5)}
	return {"name": "User Agent", "color": Color(0.95, 0.6, 0.2)}


func _species_color(p: Dictionary) -> Color:
	return _species(p)["color"]


# ---------------------------------------------------------------- input

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		yaw -= event.relative.x * 0.0025
		pitch = clampf(pitch - event.relative.y * 0.0025, -1.4, 1.4)
		camera.rotation = Vector3(pitch, yaw, 0)
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_pick()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_ESCAPE:
				if mode == "vault":
					_vault_leave()
				else:
					get_tree().quit()
			KEY_ENTER, KEY_KP_ENTER:
				if mode == "vault":
					_vault_open_hovered()
				elif hover_mount_path != "":
					_enter_vault(hover_mount_path)
			KEY_BACKSPACE:
				if mode == "vault":
					if vault_parent != "" and vault_parent != vault_path:
						_enter_vault(vault_parent)
					else:
						_vault_leave()
			KEY_F:
				if mode == "world":
					_act(19)   # SIGSTOP
			KEY_C:
				if mode == "world":
					_act(18)   # SIGCONT
			KEY_K:
				if mode == "world" and event.shift_pressed:
					_act(9)  # SIGKILL


func _process(delta: float) -> void:
	var speed := 40.0
	if Input.is_key_pressed(KEY_SHIFT):
		speed = 110.0
	var dir := Vector3.ZERO
	if Input.is_key_pressed(KEY_W): dir += -camera.global_transform.basis.z
	if Input.is_key_pressed(KEY_S): dir += camera.global_transform.basis.z
	if Input.is_key_pressed(KEY_A): dir += -camera.global_transform.basis.x
	if Input.is_key_pressed(KEY_D): dir += camera.global_transform.basis.x
	if Input.is_key_pressed(KEY_E): dir += Vector3.UP
	if Input.is_key_pressed(KEY_Q): dir += Vector3.DOWN
	camera.global_position += dir.normalized() * speed * delta
	crosshair.position = get_viewport().get_visible_rect().size / 2.0 - Vector2(6, 14)
	hover_label.position = Vector2(0, get_viewport().get_visible_rect().size.y * 0.72)
	if mode == "vault":
		_vault_hover_text()
		# hold-to-erase gesture: X held for ERASE_HOLD_MS fires real rm
		if Input.is_key_pressed(KEY_X):
			if erase_hold_start < 0.0:
				erase_hold_start = Time.get_ticks_msec()
			elif Time.get_ticks_msec() - erase_hold_start >= ERASE_HOLD_MS:
				erase_hold_start = -1.0
				_vault_erase()
		else:
			erase_hold_start = -1.0
	else:
		_update_hover()
	# living world breathes; frozen ones don't
	for pid in monoliths:
		var body3d: StaticBody3D = monoliths[pid]
		var p = _proc(pid)
		if p != null and p["state"] != "T":
			var cpu: float = clampf(float(p["cpu"]) / 100.0, 0.0, 1.0)
			body3d.position.y += sin(Time.get_ticks_msec() / 300.0 + bob_phase[pid]) * cpu * 0.02


func _proc(pid: int):
	for p in world.get("procs", []):
		if p["pid"] == pid:
			return p
	return null


func _hover_ray() -> Dictionary:
	var space := camera.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		camera.global_position,
		camera.global_position + camera.global_transform.basis.z * -1500.0)
	var hit := space.intersect_ray(query)
	if hit.is_empty() or not hit.has("collider"):
		return {}
	if pickables.has(hit["collider"]):
		return {"info": pickables[hit["collider"]]}
	return {}


func _update_hover() -> void:
	hover_pid = -1
	hover_mount_path = ""
	var hit := _hover_ray()
	if hit.is_empty():
		hover_label.text = ""
		return
	var info: Dictionary = hit["info"]
	match info.get("kind", ""):
		"proc":
			hover_pid = int(info["pid"])
			var p: Variant = _proc(hover_pid)
			if typeof(p) != TYPE_DICTIONARY:
				hover_label.text = ""
				return
			var sp := _species(p)
			hover_label.add_theme_color_override("font_color", sp["color"].lightened(0.25))
			var state_txt := "FROZEN" if p["state"] == "T" else str(p["state"])
			hover_label.text = "%s  ·  pid %d '%s'  ·  %s  ·  cpu %s%% (core %d)  ·  %dMB  ·  %s" % [
				sp["name"], p["pid"], p["name"], state_txt, p["cpu"],
				int(p.get("cpu_num", -1)), int(float(p["mem_rss"]) / 1048576.0), p["user"]]
		"core":
			var i: int = int(info["core"])
			var load: float = 0.0
			var per_core: Array = world.get("cpu", {}).get("per_core", [])
			if i < per_core.size():
				load = float(per_core[i])
			hover_label.add_theme_color_override("font_color", Color(0.55, 0.75, 1.0))
			hover_label.text = "CORE %d  ·  %d%% load" % [i, int(load)]
		"tower":
			var r: Dictionary = info["remote"]
			hover_label.add_theme_color_override("font_color", Color(0.2, 0.9, 0.8))
			hover_label.text = "REMOTE CITY %s  ·  %d live bridges" % [r["ip"], r["count"]]
		"mount":
			var mnt: Dictionary = info["mnt"]
			hover_mount_path = str(mnt["path"])
			hover_label.add_theme_color_override("font_color", Color(0.95, 0.75, 0.4))
			hover_label.text = "VAULT %s  ·  %s  ·  %d%% full  ·  %d GB  ·  Enter: descend" % [
				mnt["path"], mnt["fstype"], int(mnt["percent"]),
				int(float(mnt["total"]) / 1073741824.0)]
		"forge":
			var hw: Dictionary = world.get("hw", {})
			var gpu: int = int(hw.get("gpu_busy", -1))
			var t: float = float(hw.get("temps", {}).get("amdgpu", 0.0))
			hover_label.add_theme_color_override("font_color", Color(1.0, 0.5, 0.2))
			hover_label.text = "GPU FORGE  ·  %d%% busy  ·  %.0f°C" % [gpu, t]


func _pick() -> void:
	if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		return
	if mode == "vault":
		return  # Enter/Backspace drive navigation inside
	if hover_pid >= 0:
		selected_pid = hover_pid


# ---------------------------------------------------------------- vaults

func _enter_vault(path: String) -> void:
	list_http.request(API + "/list?path=" + path.uri_encode())


func _on_listing(_result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("entries"):
		last_action = "vault refused: " + str(parsed)
		return
	mode = "vault"
	world_root.visible = false
	vault_root.visible = true
	vault_path = parsed["path"]
	vault_parent = parsed["parent"]
	_render_vault(parsed["entries"], parsed.get("truncated", false))
	# park the camera above the hall looking down its length
	camera.position = Vector3(0, 60, 220)
	yaw = 0.0
	pitch = -0.35
	camera.rotation = Vector3(pitch, yaw, 0)
	last_action = "entered " + vault_path


func _fmt_size(b: int) -> String:
	var f := float(b)
	for unit in ["B", "KB", "MB", "GB", "TB"]:
		if f < 1024.0:
			return "%.1f %s" % [f, unit]
		f /= 1024.0
	return "%.1f PB" % f


func _render_vault(entries: Array, truncated: bool) -> void:
	for c in vault_root.get_children():
		c.queue_free()
	vault_bodies.clear()
	# hall floor
	var fm := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(1200, 1200)
	var fmat := StandardMaterial3D.new()
	fmat.albedo_color = Color(0.06, 0.05, 0.03)
	fmat.emission_enabled = true
	fmat.emission = Color(0.03, 0.02, 0.01)
	fm.material_override = fmat
	fm.mesh = pm
	vault_root.add_child(fm)
	var title := Label3D.new()
	title.text = "%s   (%d entries%s)" % [vault_path, entries.size(),
		", truncated" if truncated else ""]
	title.font_size = 96
	title.pixel_size = 0.02
	title.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	title.modulate = Color(0.95, 0.75, 0.4)
	title.position = Vector3(0, 70, -160)
	vault_root.add_child(title)
	# grid of file/dir monoliths, dirs gold, files amber; size = bytes
	var n := entries.size()
	var cols := ceili(sqrt(float(maxi(n, 1))))
	for i in n:
		var e: Dictionary = entries[i]
		var sz: float = float(e["size"])
		var h: float = clampf(2.0 + log(maxf(sz, 1.0)) * 4.0, 2.0, 120.0)
		var row := i / cols
		var col := i % cols
		var x := (float(col) - float(cols) / 2.0) * 26.0
		var z := (float(row) - float(cols) / 2.0) * 26.0
		var is_dir: bool = e["dir"]
		var color: Color = Color(1.0, 0.8, 0.3) if is_dir else Color(0.85, 0.55, 0.3)
		var body := StaticBody3D.new()
		var m := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3.ONE
		m.mesh = bm
		var mat := StandardMaterial3D.new()
		mat.emission_enabled = true
		mat.albedo_color = color
		mat.emission = color * 0.35
		m.material_override = mat
		body.add_child(m)
		var cs := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		cs.shape = shape
		body.add_child(cs)
		body.position = Vector3(x, h / 2.0, z)
		m.scale = Vector3(10, h, 10)
		shape.size = Vector3(10, h, 10)
		vault_root.add_child(body)
		vault_bodies[body] = e


func _vault_hover() -> Dictionary:
	var space := camera.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		camera.global_position,
		camera.global_position + camera.global_transform.basis.z * -1500.0)
	var hit := space.intersect_ray(query)
	if hit.is_empty() or not hit.has("collider"):
		return {}
	if vault_bodies.has(hit["collider"]):
		return {"body": hit["collider"], "entry": vault_bodies[hit["collider"]]}
	return {}


func _vault_hover_text() -> void:
	var hit := _vault_hover()
	if hit.is_empty():
		hover_label.text = "VAULT %s — Enter: descend into dir · Backspace: leave · hold X: erase" % vault_path
		return
	var e: Dictionary = hit["entry"]
	var full := vault_path.rstrip("/") + "/" + str(e["name"])
	hover_label.add_theme_color_override("font_color",
		Color(1.0, 0.85, 0.4) if e["dir"] else Color(0.9, 0.65, 0.4))
	var kind := "DIR" if e["dir"] else "FILE"
	hover_label.text = "%s  '%s'  ·  %s  ·  %s\nEnter: open · hold X: ERASE (real rm)" % [
		kind, e["name"], _fmt_size(int(e["size"])),
		Time.get_datetime_string_from_unix_time(int(e["mtime"]))]


func _vault_open_hovered() -> void:
	var hit := _vault_hover()
	if hit.is_empty():
		return
	var e: Dictionary = hit["entry"]
	if e["dir"]:
		_enter_vault(vault_path.rstrip("/") + "/" + str(e["name"]))


func _vault_leave() -> void:
	mode = "world"
	world_root.visible = true
	vault_root.visible = false
	vault_bodies.clear()
	camera.position = Vector3(0, 120, 520)
	yaw = 0.0
	pitch = -0.35
	camera.rotation = Vector3(pitch, yaw, 0)
	last_action = "left vault"


func _vault_erase() -> void:
	var hit := _vault_hover()
	if hit.is_empty():
		last_action = "nothing to erase under crosshair"
		return
	var e: Dictionary = hit["entry"]
	var full := vault_path.rstrip("/") + "/" + str(e["name"])
	var body := JSON.stringify({"verb": "rm", "path": full, "confirm": true})
	action_http.request(API + "/action", [], HTTPClient.METHOD_POST, body)
	last_action = "erasing %s..." % full


func _act(sig: int) -> void:
	if selected_pid < 0:
		last_action = "no target — aim at a process monolith"
		return
	var body := JSON.stringify({"verb": "kill", "pid": selected_pid, "sig": sig})
	action_http.request(API + "/action", [], HTTPClient.METHOD_POST, body)
	last_action = "casting kill(%d, %d)..." % [selected_pid, sig]


func _on_action(_result: int, _code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var resp = JSON.parse_string(body.get_string_from_utf8())
	if typeof(resp) == TYPE_DICTIONARY and resp.get("ok", false):
		last_action = "fired " + str(resp.get("syscall", ""))
	else:
		last_action = "REFUSED: " + str(resp.get("error", "unknown"))


# ---------------------------------------------------------------- hud

func _update_hud() -> void:
	if world.is_empty():
		hud.text = "waiting for frameshiftd... (python3 telemetry/frameshiftd.py)"
		return
	var cpu: Dictionary = world["cpu"]
	var mem: Dictionary = world["mem"]
	var host: Dictionary = world["host"]
	var net: Dictionary = world["net"]
	var hw: Dictionary = world.get("hw", {})
	var lines := [
		"%s — %s | tick %d" % [host["hostname"], host["os"], world["tick"]],
		"CPU %d%%  MEM %d%% (tide)  GPU %s%%  procs %d  bridges %d  cities %d  mounts %d" % [
			int(cpu["total"]), int(mem["percent"]),
			str(hw.get("gpu_busy", "?")), world["procs"].size(),
			net["conns"].size(), net["remote_hosts"].size(),
			hw.get("mounts", []).size()],
		"WASD move · Q/E down/up · Shift sprint · mouse look · ESC quit",
		"F freeze (SIGSTOP) · C resume (SIGCONT) · Shift+K smite (SIGKILL) — REAL syscalls",
		"purple=Kernel Spirit · green=Daemon · cyan=Your Kin · orange=User Agent · gold=Init God · grey=Frozen",
		"last: " + last_action,
	]
	var p = null
	if selected_pid >= 0:
		p = _proc(selected_pid)
	if p != null:
		lines.append("TARGET pid %d '%s' user=%s state=%s cpu=%s%% rss=%dMB threads=%d children=%d age=%ds" % [
			p["pid"], p["name"], p["user"], p["state"], p["cpu"],
			int(float(p["mem_rss"]) / 1048576.0), p["threads"], p["children"], int(p["age"])])
		lines.append("  " + str(p["cmdline"]))
	hud.text = "\n".join(lines)
