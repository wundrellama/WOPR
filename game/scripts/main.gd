extends Node3D
## Frameshift v0 — the world is your machine.
## Polls frameshiftd (http://127.0.0.1:8765) and renders every live process
## as a monolith. F freezes (SIGSTOP), C resumes (SIGCONT), Shift+K smites
## (SIGKILL). These are real syscalls against real PIDs.

const API := "http://127.0.0.1:8765"
const GRID := 30.0  # spacing between monolith districts

var world_http: HTTPRequest
var action_http: HTTPRequest
var poll_timer: Timer
var world: Dictionary = {}
var monoliths: Dictionary = {}  # pid -> MeshInstance3D
var bob_phase: Dictionary = {}  # pid -> float
var selected_pid: int = -1
var last_action := ""

var camera: Camera3D
var yaw := 0.0
var pitch := -0.25
var env: Environment
var hud: Label
var floor_mesh: MeshInstance3D

func _ready() -> void:
	world_http = HTTPRequest.new()
	add_child(world_http)
	world_http.request_completed.connect(_on_world)
	action_http = HTTPRequest.new()
	add_child(action_http)
	action_http.request_completed.connect(_on_action)
	poll_timer = Timer.new()
	poll_timer.wait_time = 1.0
	add_child(poll_timer)
	poll_timer.timeout.connect(_poll_world)
	poll_timer.start()
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
	env.fog_density = 0.006
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, 35, 0)
	sun.light_energy = 0.8
	sun.light_color = Color(0.7, 0.8, 1.0)
	add_child(sun)

	floor_mesh = MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(2400, 2400)
	var fmat := StandardMaterial3D.new()
	fmat.albedo_color = Color(0.04, 0.06, 0.10)
	fmat.emission_enabled = true
	fmat.emission = Color(0.01, 0.03, 0.06)
	floor_mesh.material_override = fmat
	floor_mesh.mesh = pm
	add_child(floor_mesh)

	# --- player ---
	camera = Camera3D.new()
	camera.position = Vector3(0, 14, 60)
	add_child(camera)
	camera.current = true
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	# --- HUD ---
	hud = Label.new()
	hud.position = Vector2(16, 12)
	hud.add_theme_font_size_override("font_size", 14)
	hud.add_theme_color_override("font_color", Color(0.7, 0.9, 1.0))
	add_child(hud)


func _poll_world() -> void:
	world_http.request(API + "/world.json")


func _on_world(_result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if code != 200:
		return
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("procs"):
		return
	world = parsed
	_sync_world()
	_update_hud()


func _hash_pos(pid: int) -> Vector2:
	# deterministic layout: same pid -> same plot, spread across the plain
	var h1 := (pid * 2654435761) % 4093
	var h2 := (pid * 40503) % 4099
	return Vector2(float(h1 % 61) - 30.0, float(h2 % 61) - 30.0) * GRID * 0.55


func _sync_world() -> void:
	var alive := {}
	for p in world["procs"]:
		var pid: int = p["pid"]
		alive[pid] = true
		var mem_mb: float = float(p["mem_rss"]) / 1048576.0
		var height: float = clampf(2.0 + log(maxf(mem_mb, 1.0)) * 3.0, 2.0, 90.0)
		var cpu: float = clampf(float(p["cpu"]) / 100.0, 0.0, 1.0)
		var frozen: bool = p["state"] == "T"
		var pos := _hash_pos(pid)
		var m: MeshInstance3D
		if monoliths.has(pid):
			m = monoliths[pid].get_child(0)
		else:
			# StaticBody3D wrapper so the camera ray can actually hit a monolith
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
			add_child(body)
			monoliths[pid] = body
			bob_phase[pid] = randf() * TAU
		var body3d: StaticBody3D = monoliths[pid]
		body3d.position = Vector3(pos.x, height / 2.0, pos.y)
		m.scale = Vector3(GRID * 0.32, height, GRID * 0.32)
		body3d.get_child(1).shape.size = Vector3(GRID * 0.32, height, GRID * 0.32)
		var mat: StandardMaterial3D = m.material_override
		if frozen:
			mat.albedo_color = Color(0.25, 0.28, 0.32)
			mat.emission = Color(0.05, 0.06, 0.08)
		else:
			# hot processes glow toward red; idle are cool cyan
			var base := Color(0.1, 0.55, 0.8).lerp(Color(1.0, 0.35, 0.15), cpu)
			if pid == selected_pid:
				base = Color(1.0, 0.85, 0.2)
			mat.albedo_color = base
			mat.emission = base * (0.15 + cpu * 0.65)
	# remove dead monoliths
	for pid in monoliths.keys():
		if not alive.has(pid):
			monoliths[pid].queue_free()
			monoliths.erase(pid)
			bob_phase.erase(pid)
			if pid == selected_pid:
				selected_pid = -1


func _process(delta: float) -> void:
	# fly controls
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
	elif Input.get_mouse_mode() == Input.MOUSE_MODE_VISIBLE and event is InputEventMouseMotion:
		pass
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_ESCAPE:
				get_tree().quit()
			KEY_F:
				_act(19)   # SIGSTOP
			KEY_C:
				_act(18)   # SIGCONT
			KEY_K:
				if event.shift_pressed:
					_act(9)  # SIGKILL


func _pick() -> void:
	if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		return
	var space := camera.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		camera.global_position,
		camera.global_position + camera.global_transform.basis.z * -600.0)
	var hit := space.intersect_ray(query)
	if hit.is_empty() or not hit.has("collider"):
		return
	for pid in monoliths:
		if monoliths[pid] == hit["collider"]:
			selected_pid = pid


func _act(sig: int) -> void:
	if selected_pid < 0:
		last_action = "no target — left-click a monolith"
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


func _update_hud() -> void:
	if world.is_empty():
		hud.text = "waiting for frameshiftd... (python3 telemetry/frameshiftd.py)"
		return
	var cpu: Dictionary = world["cpu"]
	var mem: Dictionary = world["mem"]
	var host: Dictionary = world["host"]
	var net: Dictionary = world["net"]
	var lines := [
		"%s — %s | tick %d" % [host["hostname"], host["os"], world["tick"]],
		"CPU %d%% (%d cores, load %s)   MEM %d%%   procs %d   bridges %d   gates %d" % [
			int(cpu["total"]), int(cpu["count"]), str(cpu["load"]),
			int(mem["percent"]), world["procs"].size(),
			net["conns"].size(), net["listeners"].size()],
		"WASD move · Q/E down/up · Shift sprint · mouse look · ESC quit",
		"F freeze (SIGSTOP) · C resume (SIGCONT) · Shift+K smite (SIGKILL) — REAL syscalls",
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
