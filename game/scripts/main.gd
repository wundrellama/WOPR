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
## F freezes (SIGSTOP), C resumes (SIGCONT), K smites (SIGKILL).
## These are real syscalls against real PIDs.

const API := "http://127.0.0.1:8765"
const Art = preload("res://scripts/world_art.gd")

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
var rogue_kills := 0
var rogue_frees := 0  # rogues that expired on their own (you failed them)

var camera: Camera3D
var yaw := 0.0
var pitch := -0.35
var env: Environment
var hud: Control
var console: Control
var crosshair: Control
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
var mode := "world"            # "world" | "vault" | "remote"
var vault_path := ""
var vault_parent := ""
var vault_host := ""           # "" = local machine
var vault_bodies: Dictionary = {}  # StaticBody3D -> entry dict
var erase_hold_start := -1.0       # msec when X was pressed, -1 = not held
var hover_mount_path := ""         # vault path under crosshair in world mode
const ERASE_HOLD_MS := 1000.0

# --- ssh travel ---
var remote_root: Node3D
var remote_host := ""              # "" = home machine
var ssh_gates: Dictionary = {}     # host -> StaticBody3D
var hover_ssh_host := ""
var remote_procs: Array = []
var remote_monoliths: Dictionary = {}  # pid -> StaticBody3D on remote
var remote_rogues: Dictionary = {}     # pid -> true for rogues on the remote host
var remote_tick_timer: Timer
var ssh_http: HTTPRequest
var targets: Dictionary = {}       # pid -> Vector3 target (lerped each frame)
var splash: Control = null         # WOPR boot screen; null once playing
var farewell: Control = null       # end-of-game screen
var arm_screen: Control = null     # YOLO arming ritual screen; null when closed
var arm_field: LineEdit = null     # masked incantation input
var arm_status: Label = null       # error/result line inside the ritual screen
var oracle_armed := false          # mirrored from world["oracle"]["armed"]
var sim_playing := false           # mirrored from world["sim"]["playing"]
var sim_info := {}                 # full sim state for the HUD
var daemon_pid := -1               # daemon we spawned ourselves (-1 = adopted)
var rogue_tags: Dictionary = {}    # pid -> Label3D floating over a ROGUE
var roads: Dictionary = {}         # ip -> {start, end, mat, packets}
var kernel_ring_rot := 0.0
var water_y := 6.0

# Presentation transitions never commit a destination before its reply succeeds.
var travel_overlay: Control
var travel_state := "idle"       # depart -> waiting for real reply -> arrive
var travel_kind := ""
var travel_operation := ""
var travel_destination := ""
var travel_serial := 0
var travel_elapsed := 0.0
var travel_wait_elapsed := 0.0
var travel_ready := false
var travel_error := ""
var travel_payload: Dictionary = {}
var travel_vault_host := ""
var travel_origin: Transform3D
var travel_camera_end: Vector3
var travel_camera_start: Vector3
var travel_origin_fov := 65.0
var travel_arrival_root: Node3D
var actions_need_release := false
var listing_callback: Callable
var remote_callback: Callable

var action_effects: Node3D
var pending_shot: Dictionary = {}
var action_result: Dictionary = {}
var action_result_expires := 0



# district anchors — far enough apart to read as separate countries
const HARBOR_X := -1000.0
const VAULTS_X := 1000.0
const PLAINS_Z := 800.0
const FORGE_Z := -800.0
const HOME_POS := Vector3(340, 180, 1080)

func _ready() -> void:
	# game owns the daemon: adopt a running one, else spawn a child that
	# watches our pid. On exit we shut it down either way — quitting the
	# game stops EVERYTHING (recording, enemies, oracle).
	if not _daemon_running():
		_spawn_daemon()
	world_http = HTTPRequest.new()
	add_child(world_http)
	world_http.request_completed.connect(_on_world)
	action_http = HTTPRequest.new()
	add_child(action_http)
	action_http.request_completed.connect(_on_action)
	action_http.timeout = 30.0
	list_http = HTTPRequest.new()
	add_child(list_http)
	list_http.timeout = 15.0
	world_root = Node3D.new()
	add_child(world_root)
	vault_root = Node3D.new()
	vault_root.visible = false
	add_child(vault_root)
	remote_root = Node3D.new()
	remote_root.visible = false
	add_child(remote_root)
	remote_tick_timer = Timer.new()
	remote_tick_timer.wait_time = 5.0
	add_child(remote_tick_timer)
	remote_tick_timer.timeout.connect(_refresh_remote)
	ssh_http = HTTPRequest.new()
	add_child(ssh_http)
	ssh_http.timeout = 15.0
	poll_timer = Timer.new()
	poll_timer.wait_time = 1.0
	add_child(poll_timer)
	poll_timer.timeout.connect(_poll_world)
	console = preload("res://scripts/console_ui.gd").new()
	add_child(console)
	console.build_hud()
	console.visible = false
	_build_splash()

	# --- environment ---
	var we := WorldEnvironment.new()
	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ShaderMaterial.new()
	sky_mat.shader = preload("res://shaders/atmosphere.gdshader")
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.28, 0.43, 0.5)
	env.ambient_light_energy = 0.65
	env.fog_enabled = true
	env.fog_light_color = Color(0.035, 0.075, 0.09)
	env.fog_density = 0.00065
	env.glow_enabled = true
	env.glow_intensity = 0.8
	env.glow_bloom = 0.08
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, 35, 0)
	sun.light_energy = 0.65
	sun.light_color = Color(0.56, 0.75, 0.85)
	add_child(sun)

	# --- tron grid floor: dark plates, glowing seams ---
	var floor_mesh := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(6000, 6000)
	var fmat := ShaderMaterial.new()
	fmat.shader = preload("res://shaders/grid.gdshader")
	floor_mesh.material_override = fmat
	floor_mesh.mesh = pm
	world_root.add_child(floor_mesh)

	# --- the tide (memory water): animated neon sheet ---
	water = MeshInstance3D.new()
	var wpm := PlaneMesh.new()
	wpm.size = Vector2(6000, 6000)
	wpm.subdivide_width = 96
	wpm.subdivide_depth = 96
	var wmat := ShaderMaterial.new()
	wmat.shader = preload("res://shaders/tide.gdshader")
	water.material_override = wmat
	water.mesh = wpm
	water.position = Vector3(0, 6, 0)
	world_root.add_child(water)

	# --- player ---
	camera = Camera3D.new()
	camera.position = HOME_POS
	add_child(camera)
	camera.current = true
	camera.far = 6500.0
	camera.fov = 65.0
	camera.look_at(Vector3(0, 24, 420))
	pitch = camera.rotation.x
	yaw = camera.rotation.y
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

	# --- HUD (hidden until the player commits to playing) ---
	hud = console

	crosshair = preload("res://scripts/flight_overlay.gd").new()
	crosshair.visible = false
	crosshair.viewer = camera
	add_child(crosshair)

	hover_label = Label.new()
	hover_label.visible = false
	hover_label.add_theme_font_size_override("font_size", 15)
	var mono := SystemFont.new()
	mono.font_names = PackedStringArray(["JetBrains Mono", "DejaVu Sans Mono"])
	hover_label.add_theme_font_override("font", mono)
	hover_label.add_theme_color_override("font_outline_color", Color(0.0, 0.01, 0.02, 0.9))
	hover_label.add_theme_constant_override("outline_size", 4)
	hover_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hover_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hover_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hover_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	add_child(hover_label)
	action_effects = preload("res://scripts/action_effects.gd").new()
	add_child(action_effects)
	travel_overlay = preload("res://scripts/travel_overlay.gd").new()
	add_child(travel_overlay)


func _notification(what: int) -> void:
	# window close button / OS-level quit: same contract — everything stops
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_shutdown_daemon()


func _poll_world() -> void:
	world_http.request(API + "/world.json")


# ---------------------------------------------------------------- daemon lifecycle

func _daemon_running() -> bool:
	# synchronous TCP probe on boot: is something already on 8765?
	var tcp := StreamPeerTCP.new()
	if tcp.connect_to_host("127.0.0.1", 8765) != OK:
		return false
	var deadline := Time.get_ticks_msec() + 1000
	while tcp.get_status() == StreamPeerTCP.STATUS_CONNECTING \
			and Time.get_ticks_msec() < deadline:
		tcp.poll()
		OS.delay_msec(20)
	var up := tcp.get_status() == StreamPeerTCP.STATUS_CONNECTED
	tcp.close()
	return up


func _spawn_daemon() -> void:
	# the daemon lives next to the game project: ../telemetry/frameshiftd.py
	var script := ProjectSettings.globalize_path("res://../telemetry/frameshiftd.py")
	if not FileAccess.file_exists(script):
		push_warning("frameshiftd.py not found at " + script)
		return
	daemon_pid = OS.create_process("python3",
		[script, "--parent", str(OS.get_process_id())])
	if daemon_pid <= 0:
		push_warning("could not spawn frameshiftd (pid %d)" % daemon_pid)
		daemon_pid = -1


func _shutdown_daemon() -> void:
	# quit means EVERYTHING stops: recording, enemies, oracle. Prefer the
	# pid we spawned; otherwise ask the daemon itself (world.json reports
	# its pid) so an adopted daemon dies too. SIGTERM, not SIGKILL: the
	# daemon's atexit handlers must run to clean up enemy procs + oracle.
	var pid := daemon_pid
	if pid <= 0:
		pid = int(world.get("me", {}).get("pid", 0))
	if pid > 0:
		OS.create_process("kill", ["-TERM", str(pid)])
	daemon_pid = -1


func _quit_game() -> void:
	_shutdown_daemon()
	get_tree().quit()


# ---------------------------------------------------------------- WOPR screens

func _make_screen(title: String, sub: String, blink: String) -> Control:
	return console.make_screen(title, sub, blink)


func _build_splash() -> void:
	splash = _make_screen("W O P R",
		"\"The only winning move is not to play.\"\n\nWARNING: every spell is a real syscall.\nThis game can destroy this machine —\nincluding its snapshots.",
		"— PRESS ENTER TO PLAY —")
	add_child(splash)
	splash.move_to_front()


# ---------------------------------------------------------------- YOLO ritual

func _build_arm_screen() -> void:
	var panel := ColorRect.new()
	panel.color = Color(0.027, 0.059, 0.094, 0.99)
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	var mono := SystemFont.new()
	mono.font_names = PackedStringArray(["JetBrains Mono", "DejaVu Sans Mono"])
	var ritual_theme := Theme.new()
	ritual_theme.default_font = mono
	panel.theme = ritual_theme
	var center := CenterContainer.new()
	panel.add_child(center)
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.custom_minimum_size = Vector2(860, 0)
	vb.add_theme_constant_override("separation", 22)
	center.add_child(vb)
	var t := Label.new()
	t.text = "THE KERNEL ORACLE"
	t.add_theme_font_size_override("font_size", 42)
	t.add_theme_color_override("font_color", Color("f28b80"))
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(t)
	var s := Label.new()
	s.text = "Speak the incantation (your sudo password).\nThe Oracle will demand a snapshot exists before it arms.\nArmed for 120s. Every verb is logged before it runs.\nThis can destroy the machine. Including the snapshots."
	s.add_theme_font_size_override("font_size", 19)
	s.add_theme_color_override("font_color", Color("e1e8e5"))
	s.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(s)
	arm_field = LineEdit.new()
	arm_field.secret = true
	arm_field.secret_character = "•"
	arm_field.add_theme_font_size_override("font_size", 20)
	var field_style := StyleBoxFlat.new()
	field_style.bg_color = Color("0b1922")
	field_style.border_color = Color("e6b673")
	field_style.set_border_width_all(1)
	field_style.content_margin_top = 12
	field_style.content_margin_bottom = 12
	arm_field.add_theme_stylebox_override("normal", field_style)
	var focus_style := StyleBoxFlat.new()
	focus_style.bg_color = Color(0, 0, 0, 0)
	focus_style.border_color = Color("f28b80")
	focus_style.set_border_width_all(1)
	arm_field.add_theme_stylebox_override("focus", focus_style)
	arm_field.placeholder_text = "incantation"
	arm_field.custom_minimum_size = Vector2(420, 44)
	arm_field.alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(arm_field)
	arm_status = Label.new()
	arm_status.text = "press ENTER to speak · ESC to back away"
	arm_status.add_theme_font_size_override("font_size", 20)
	arm_status.add_theme_color_override("font_color", Color(0.7, 0.7, 0.8))
	arm_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(arm_status)
	arm_field.text_submitted.connect(_on_incantation)
	arm_screen = panel
	add_child(arm_screen)
	arm_screen.move_to_front()
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	arm_field.grab_focus()


func _close_arm_screen() -> void:
	if arm_screen != null:
		arm_screen.queue_free()
	arm_screen = null
	arm_field = null
	arm_status = null
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _on_incantation(text: String) -> void:
	if arm_status != null:
		arm_status.text = "speaking... the Oracle listens"
	action_http.request(API + "/action", [], HTTPClient.METHOD_POST,
		JSON.stringify({"verb": "oracle_arm", "incantation": text}))
	# response lands in _on_action; on success we close from the world poll


func _oracle_verb(line: String) -> void:
	action_http.request(API + "/action", [], HTTPClient.METHOD_POST,
		JSON.stringify({"verb": "oracle", "line": line}))


func _start_game() -> void:
	splash.queue_free()
	splash = null
	hud.visible = true
	crosshair.visible = true
	hover_label.visible = true
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	_poll_world()
	poll_timer.start()


func _show_farewell() -> void:
	poll_timer.stop()
	if mode == "remote":
		_return_home()
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	hud.visible = false
	crosshair.visible = false
	hover_label.visible = false
	_build_farewell()


func _build_farewell() -> void:
	if farewell != null:
		return
	farewell = _make_screen("How about a nice game of chess?",
		"",
		"— PRESS ENTER TO RETURN · ESC TO EXIT —")
	add_child(farewell)


func _on_world(_result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if code != 200:
		return
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("procs"):
		return
	world = parsed
	# mirror sim state
	var sim: Dictionary = world.get("sim", {})
	sim_info = sim
	sim_playing = bool(sim.get("playing", false))
	# mirror the Oracle's armed state; close the ritual screen once armed
	var orc: Dictionary = world.get("oracle", {})
	var was_armed := oracle_armed
	oracle_armed = bool(orc.get("armed", false))
	if oracle_armed and arm_screen != null:
		_close_arm_screen()
		last_action = "THE ORACLE IS ARMED (120s). K now kills as root."
	elif was_armed and not oracle_armed:
		last_action = "the Oracle went cold. re-arm with Y if you dare."
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
	var mat := Art.material(color)
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
	l.pixel_size = 0.24
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.outline_size = 8
	l.outline_modulate = Color(0, 0, 0, 0.8)
	l.modulate = color
	l.position = pos
	world_root.add_child(l)


func _build_geography() -> void:
	var ncores: int = int(world["cpu"]["count"])
	# CPU PLAINS: grid of core pillars, far north
	var cols := ceili(sqrt(float(ncores)))
	for i in ncores:
		var row := i / cols
		var col := i % cols
		var p := Vector3((col - (cols - 1) / 2.0) * 90.0, 30, PLAINS_Z - 300.0 + row * 90.0)
		var body := _add_box(p, Vector3(10, 36, 10),
			Color(0.55, 0.75, 1.0), {"kind": "core", "core": i})
		core_bodies.append(body)
	_add_label("01 / CPU PLAINS", Vector3(0, 145, PLAINS_Z - 100), Art.ICE)

	# NETWORK HARBOR: west — towers in a wide arc facing the sea
	_add_label("02 / NETWORK HARBOR", Vector3(HARBOR_X, 130, 0), Art.CYAN)

	# FILE VAULTS: east
	_add_label("03 / FILE VAULTS", Vector3(VAULTS_X, 175, 0), Art.AMBER)
	var mounts: Array = world.get("hw", {}).get("mounts", [])
	for i in mounts.size():
		var mnt: Dictionary = mounts[i]
		var pct: float = float(mnt["percent"])
		var h: float = maxf(6.0, pct * 1.4)
		var z := (float(i) - float(mounts.size()) / 2.0) * 110.0
		_add_box(Vector3(VAULTS_X, h / 2.0, z), Vector3(34, h, 34),
			Color(0.95, 0.75, 0.4), {"kind": "mount", "mnt": mnt})

	# GPU FORGE: south
	var forge_pos := Vector3(0, 30, FORGE_Z)
	forge_body = _add_box(forge_pos, Vector3(60, 60, 60),
		Color(1.0, 0.4, 0.15), {"kind": "forge"})
	_add_label("04 / GPU FORGE", forge_pos + Vector3(0, 105, 0), Art.EMBER)

	# KERNEL RING: the capital at center
	_add_label("00 / KERNEL RING", Vector3(0, 190, 0), Art.VIOLET)

	# light-roads linking the capital to each district
	_add_road("rd_plains", Vector3.ZERO, Vector3(0, 0, PLAINS_Z - 340), Color(0.55, 0.75, 1.0), 3.0)
	_add_road("rd_harbor", Vector3.ZERO, Vector3(HARBOR_X + 260, 0, 0), Color(0.2, 0.9, 0.8), 4.0)
	_add_road("rd_vaults", Vector3.ZERO, Vector3(VAULTS_X - 60, 0, 0), Color(0.95, 0.75, 0.4), 1.5)
	_add_road("rd_forge", Vector3.ZERO, Vector3(0, 0, FORGE_Z + 60), Art.EMBER, 2.0)
	Art.build_districts(world_root, core_bodies, HARBOR_X, VAULTS_X, PLAINS_Z, FORGE_Z)


func _add_road(key: String, from: Vector3, to: Vector3, color: Color, flow: float) -> void:
	if roads.has(key):
		roads[key]["end"] = to
		roads[key]["flow"] = flow
		return
	var dist := Vector3(to.x - from.x, 0, to.z - from.z).length()
	if dist < 4.0:
		return  # degenerate road (start == end): look_at would fail, nothing to draw
	var road := MeshInstance3D.new()
	var rbm := BoxMesh.new()
	road.mesh = rbm
	var rmat := StandardMaterial3D.new()
	rmat.emission_enabled = true
	rmat.albedo_color = color
	rmat.emission = color * 0.5
	road.material_override = rmat
	road.position = (from + to) / 2.0 + Vector3(0, 1.5, 0)
	road.scale = Vector3(2.0, 1.5, maxf(dist, 1.0))
	world_root.add_child(road)
	road.look_at(to + Vector3(0, 1.5, 0))
	# traffic packets: little light-cars riding the road
	var packets := []
	for i in 3:
		var pk := MeshInstance3D.new()
		var sp := SphereMesh.new()
		sp.radius = 3.0
		sp.height = 6.0
		sp.radial_segments = 8
		sp.rings = 4
		pk.mesh = sp
		var pmat := StandardMaterial3D.new()
		pmat.emission_enabled = true
		pmat.albedo_color = color.lightened(0.5)
		pmat.emission = color * 1.5
		pk.material_override = pmat
		world_root.add_child(pk)
		packets.append({"mesh": pk, "t": randf() * 2.0})
	roads[key] = {"start": from, "end": to, "mesh": road, "mat": rmat, "packets": packets, "flow": flow}


func _tower_pos(idx: int, total: int) -> Vector3:
	var t := idx / maxf(float(total - 1), 1.0)
	var ang := lerpf(deg_to_rad(-80.0), deg_to_rad(80.0), t)
	return Vector3(HARBOR_X, 0, 0) + Vector3(cos(ang) * 260.0, 0, sin(ang) * 420.0)


func _update_geo() -> void:
	# tide: memory percent raises the water; swap pressure floods higher
	# and turns the crest blood-tinged — swap means the machine is drowning
	var mem_pct: float = float(world["mem"]["percent"])
	var sw_total: float = float(world["mem"].get("swap_total", 0))
	var sw_pct: float = (float(world["mem"].get("swap_used", 0)) / sw_total * 100.0) if sw_total > 0 else 0.0
	water_y = lerpf(2.0, 60.0, mem_pct / 100.0) + lerpf(0.0, 45.0, sw_pct / 100.0)
	if water.material_override is ShaderMaterial:
		var drown: float = clampf(sw_pct / 100.0, 0.0, 1.0)
		water.material_override.set_shader_parameter("crest_color",
			Color(0.15, 0.75, 1.0).lerp(Color(1.0, 0.3, 0.15), drown))

	# forge glow: gpu busy
	if forge_body != null:
		var busy: float = clampf(float(world.get("hw", {}).get("gpu_busy", 0)) / 100.0, 0.0, 1.0)
		var fmat: StandardMaterial3D = forge_body.get_child(0).material_override
		Art.update_material(fmat, Art.EMBER, 0.2 + busy)

	# core pillar glow = per-core load
	var per_core: Array = world.get("cpu", {}).get("per_core", [])
	for i in core_bodies.size():
		var load: float = 0.0
		if i < per_core.size():
			load = clampf(float(per_core[i]) / 100.0, 0.0, 1.0)
		var cmat: StandardMaterial3D = core_bodies[i].get_child(0).material_override
		Art.update_material(cmat, Art.ICE.lerp(Art.EMBER, load), 0.3 + load)

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
			# light-road from harbor mouth to tower, flow ~ connection count
			_add_road("rd_" + ip, Vector3(HARBOR_X + 260, 0, 0), pos,
				Color(0.2, 0.9, 0.8), clampf(float(r["count"]) * 0.4, 0.5, 6.0))
		var tmat: StandardMaterial3D = body.get_child(0).material_override
		Art.update_material(tmat, Art.CYAN, 0.2 + clampf(float(r["count"]) / 20.0, 0.0, 0.8))
	for ip in tower_bodies.keys():
		if not seen.has(ip):
			pickables.erase(tower_bodies[ip])
			tower_bodies[ip].queue_free()
			tower_bodies.erase(ip)
			if roads.has("rd_" + ip):
				for pk in roads["rd_" + ip]["packets"]:
					pk["mesh"].queue_free()
				roads["rd_" + ip]["mesh"].queue_free()
				roads.erase("rd_" + ip)
	_update_ssh_gates()


func _update_ssh_gates() -> void:
	var ssh: Dictionary = world.get("ssh", {})
	var hosts: Array = ssh.get("hosts", [])
	var status: Dictionary = ssh.get("status", {})
	var seen := {}
	for i in hosts.size():
		var h: String = hosts[i]
		seen[h] = true
		var st: String = str(status.get(h, "unknown"))
		# gates stand at the harbor mouth, facing the capital
		var ang := lerpf(deg_to_rad(-70.0), deg_to_rad(70.0),
			i / maxf(float(hosts.size() - 1), 1.0))
		var pos := Vector3(HARBOR_X + 500.0 + cos(ang) * 90.0, 0, sin(ang) * 260.0)
		var color: Color
		match st:
			"open":
				color = Color(0.2, 1.0, 0.6)
			"unknown-hostkey":
				color = Color(1.0, 0.7, 0.2)
			_:
				color = Color(0.4, 0.4, 0.45)
		if not ssh_gates.has(h):
			var gate := _add_box(Vector3(pos.x, 25, pos.z), Vector3(8, 50, 8),
				color, {"kind": "ssh", "host": h, "status": st})
			var tag := Label3D.new()
			tag.text = "%s\n[%s]" % [h, st]
			tag.font_size = 48
			tag.pixel_size = 0.02
			tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			tag.modulate = color
			tag.position = Vector3(pos.x, 62, pos.z)
			world_root.add_child(tag)
			ssh_gates[h] = [gate, tag]
		else:
			var pair: Array = ssh_gates[h]
			var gmat: StandardMaterial3D = pair[0].get_child(0).material_override
			Art.update_material(gmat, color, 0.4)
			pair[1].text = "%s\n[%s]" % [h, st]
			pickables[pair[0]] = {"kind": "ssh", "host": h, "status": st}
	for h in ssh_gates.keys():
		if not seen.has(h):
			pickables.erase(ssh_gates[h][0])
			ssh_gates[h][0].queue_free()
			ssh_gates[h][1].queue_free()
			ssh_gates.erase(h)


# ---------------------------------------------------------------- processes

func _district_pos(p: Dictionary) -> Vector3:
	var pid: int = p["pid"]
	var h1 := (pid * 2654435761) % 4093
	var h2 := (pid * 40503) % 4099
	if pid in world.get("enemies", []):
		# rogues roam the CPU plains: hash anchor + slow lissajous drift per tick
		var t := float(world.get("tick", 0))
		var ph := float(h1 % 628) / 100.0
		var ax := float(h1 % 500) - 250.0
		var az := PLAINS_Z - 200.0 + float(h2 % 300) - 150.0
		return Vector3(ax + sin(t * 0.35 + ph) * 120.0, 0,
			az + cos(t * 0.27 + ph * 1.7) * 90.0)
	if pid == 1:
		return Vector3.ZERO
	if p["ppid"] == 2 or (p["ppid"] == 1 and str(p["name"]).begins_with("[")):
		# kernel spirits: a slowly rotating ring around the Init God
		var ang := lerpf(0, TAU, float(h1 % 1000) / 1000.0) + kernel_ring_rot
		var rad := 160.0 + float(h2 % 100) * 0.9
		return Vector3(cos(ang) * rad, 0, sin(ang) * rad)
	var cn: int = int(p.get("cpu_num", -1))
	if cn >= 0 and cn < core_bodies.size():
		# cluster around the core pillar it actually runs on
		var base: Vector3 = core_bodies[cn].position
		return Vector3(base.x + float(h1 % 50) - 25.0, 0, base.z + float(h2 % 50) - 25.0)
	# wanderers (no cpu affinity info): between center and plains
	return Vector3(float(h1 % 300) - 150.0, 0, 320.0 + float(h2 % 180))


func _sync_procs() -> void:
	var alive := {}
	for p in world["procs"]:
		var pid: int = p["pid"]
		alive[pid] = true
		var mem_mb: float = float(p["mem_rss"]) / 1048576.0
		var height: float = Art.process_height(mem_mb, pid)
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
			var mat := Art.material(Art.CYAN)
			m.material_override = mat
			body.add_child(m)
			var cs := CollisionShape3D.new()
			var shape := BoxShape3D.new()
			shape.size = Vector3.ONE
			cs.shape = shape
			body.add_child(cs)
			world_root.add_child(body)
			body.position = Vector3(pos.x, 14.0 + height / 2.0, pos.z)
			monoliths[pid] = body
			pickables[body] = {"kind": "proc", "pid": pid}
			bob_phase[pid] = randf() * TAU
		var body3d: StaticBody3D = monoliths[pid]
		targets[pid] = Vector3(pos.x, 14.0 + height / 2.0, pos.z)
		m.scale = Vector3(8.0, height, 8.0)
		body3d.get_child(1).shape.size = Vector3(8.0, height, 8.0)
		var mat2: StandardMaterial3D = m.material_override
		if frozen:
			Art.update_material(mat2, Color(0.25, 0.28, 0.32), 0.0)
		else:
			var base := _species_color(p)
			if pid == selected_pid:
				base = Color(1.0, 0.85, 0.2)  # locked target = gold
			Art.update_material(mat2, base, 0.2 + cpu)
		# ROGUEs get a floating tag so they can't hide in the crowd
		if pid in world.get("enemies", []):
			if not rogue_tags.has(pid):
				var tag := Label3D.new()
				tag.text = "▼ ROGUE ▼"
				tag.font_size = 64
				tag.pixel_size = 0.02
				tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
				tag.outline_size = 8
				tag.outline_modulate = Color(0, 0, 0, 0.9)
				tag.modulate = Color(1.0, 0.15, 0.15)
				world_root.add_child(tag)
				rogue_tags[pid] = tag
			rogue_tags[pid].position = body3d.position + Vector3(0, height * 0.5 + 14.0, 0)
		elif rogue_tags.has(pid):
			rogue_tags[pid].queue_free()
			rogue_tags.erase(pid)
	for pid in monoliths.keys():
		if not alive.has(pid):
			pickables.erase(monoliths[pid])
			monoliths[pid].queue_free()
			monoliths.erase(pid)
			targets.erase(pid)
			bob_phase.erase(pid)
			if rogue_tags.has(pid):
				rogue_tags[pid].queue_free()
				rogue_tags.erase(pid)
			if pid == selected_pid:
				selected_pid = -1


# ---------------------------------------------------------------- species

## Species taxonomy — what KIND of creature this monolith is.
## Kernel spirits are born of kthreadd (pid 2).
func _species(p: Dictionary) -> Dictionary:
	var pid: int = p["pid"]
	if pid in world.get("enemies", []):
		return {"name": "ROGUE", "color": Color(1.0, 0.1, 0.1)}
	if bool(p.get("hydra", false)):
		return {"name": "Hydra", "color": Color(0.9, 0.75, 0.1)}
	if str(p["state"]) == "Z":
		return {"name": "Ghost", "color": Color(0.75, 0.9, 0.8)}
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
	if travel_state != "idle":
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			_cancel_travel()
		return
	if actions_need_release or (event is InputEventKey and event.echo):
		return
	if not pending_shot.is_empty() and event is InputEventKey and event.keycode in [KEY_F, KEY_C, KEY_K, KEY_Y, KEY_M, KEY_H, KEY_ENTER, KEY_KP_ENTER]:
		return
	if arm_screen != null:
		# the ritual screen owns all input while open
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			_close_arm_screen()
		return
	if splash != null or farewell != null:
		if event is InputEventKey and event.pressed:
			if event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER:
				if splash != null:
					_start_game()
				else:
					# back to the title screen for another round
					farewell.queue_free()
					farewell = null
					_build_splash()
			elif event.keycode == KEY_ESCAPE:
				_quit_game()
		return
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
				elif mode == "remote":
					_return_home()
				else:
					_show_farewell()
			KEY_ENTER, KEY_KP_ENTER:
				if mode == "vault":
					_vault_open_hovered()
				elif mode == "world" and hover_ssh_host != "":
					_travel_to(hover_ssh_host)
				elif mode == "world" and hover_mount_path != "":
					_enter_vault(hover_mount_path)
			KEY_BACKSPACE:
				if mode == "vault":
					if vault_parent != "" and vault_parent != vault_path:
						_enter_vault(vault_parent, vault_host)
					else:
						_vault_leave()
			KEY_F:
				if mode != "vault":
					_act(19)   # SIGSTOP
			KEY_C:
				if mode != "vault":
					_act(18)   # SIGCONT
			KEY_K:
				if mode != "vault":
					_act(9)  # SIGKILL; _act preserves the armed local Oracle route
			KEY_Y:
				if mode == "world" and arm_screen == null and not oracle_armed:
					_build_arm_screen()
			KEY_M:
				# toggle sim mode: replay of the recorded window, all verbs
				# frozen server-side. Safe tier.
				var op := "stop" if sim_playing else "start"
				action_http.request(API + "/action", [], HTTPClient.METHOD_POST,
					JSON.stringify({"verb": "sim", "op": op}))
				last_action = "leaving sim — back to the live machine" if sim_playing else "entering SIM MODE — replaying the last %d s, verbs frozen" % int(sim_info.get("length", 0))
			KEY_V:
				if mode == "remote" and remote_host != "":
					_enter_vault("~", remote_host)
			KEY_H:
				# one key cycles: off -> local -> local+remote -> off
				var lvl: int = (int(world.get("enemies_level", 0)) + 1) % 3
				action_http.request(API + "/action", [], HTTPClient.METHOD_POST,
					JSON.stringify({"verb": "enemies", "level": lvl}))
				last_action = ["hunting OFF — rogues purged",
					"hunting LOCAL ONLY — rogues will spawn here",
					"hunting LOCAL + REMOTE — rogues on every open host"][lvl]


func _process(delta: float) -> void:
	_advance_travel(delta)
	if actions_need_release and not _action_key_held():
		actions_need_release = false
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
	if travel_state == "idle" and splash == null and farewell == null and arm_screen == null:
		camera.global_position += dir.normalized() * speed * delta
	var viewport_size := get_viewport().get_visible_rect().size
	hover_label.position = Vector2(64, viewport_size.y * 0.68)
	hover_label.size.x = viewport_size.x - 128.0
	crosshair.target = remote_monoliths.get(selected_pid) if mode == "remote" else monoliths.get(selected_pid)
	if travel_state != "idle" or actions_need_release or arm_screen != null or splash != null or farewell != null:
		erase_hold_start = -1.0
	elif mode == "vault":
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
	elif mode == "remote":
		_update_remote_hover()
	else:
		_update_hover()
	# living world: glide monoliths toward their targets every frame
	kernel_ring_rot += delta * 0.05
	water.position.y = lerpf(water.position.y, water_y, clampf(delta * 0.7, 0.0, 1.0))
	var now := Time.get_ticks_msec() / 1000.0
	for pid in monoliths:
		var body3d: StaticBody3D = monoliths[pid]
		if not targets.has(pid):
			continue
		body3d.position = body3d.position.lerp(targets[pid], clampf(delta * 2.5, 0.0, 1.0))
		if rogue_tags.has(pid):
			# heartbeat pulse on the ROGUE monolith + tag
			var pulse := 0.5 + 0.5 * sin(now * 5.0)
			var rmat: StandardMaterial3D = body3d.get_child(0).material_override
			Art.update_material(rmat, Color(1.0, 0.22, 0.15), 0.4 + pulse)
			(rogue_tags[pid] as Label3D).modulate = Color(1.0, 0.15 + pulse * 0.4, 0.15)
			rogue_tags[pid].position = body3d.position + Vector3(0, body3d.get_child(1).shape.size.y * 0.5 + 14.0, 0)
		var p = _proc(pid)
		if p != null and p["state"] != "T":
			var cpu: float = clampf(float(p["cpu"]) / 100.0, 0.0, 1.0)
			body3d.position.y += sin(now * 3.0 + bob_phase[pid]) * (0.3 + cpu * 2.5) * 0.5
	# light-road traffic
	for key in roads:
		var rd: Dictionary = roads[key]
		for pk in rd["packets"]:
			pk["t"] = fmod(pk["t"] + delta * rd["flow"] * 0.25, 1.0)
			pk["mesh"].position = rd["start"].lerp(rd["end"], pk["t"]) + Vector3(0, 4.0, 0)


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
	query.collision_mask = 1
	var hit := space.intersect_ray(query)
	if hit.is_empty() or not hit.has("collider"):
		return {}
	if pickables.has(hit["collider"]):
		return {"info": pickables[hit["collider"]]}
	return {}


func _update_hover() -> void:
	hover_pid = -1
	hover_mount_path = ""
	hover_ssh_host = ""
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
		"ssh":
			hover_ssh_host = str(info["host"])
			var st: String = str(info["status"])
			var col := Color(0.4, 0.4, 0.45)
			var hint := "SEALED"
			if st == "open":
				col = Color(0.2, 1.0, 0.6)
				hint = "Enter: TRAVEL"
			elif st == "unknown-hostkey":
				col = Color(1.0, 0.7, 0.2)
				hint = "host key unconfirmed — run ssh once"
			hover_label.add_theme_color_override("font_color", col)
			hover_label.text = "GATEWAY '%s'  ·  %s  ·  %s" % [hover_ssh_host, st, hint]


func _pick() -> void:
	if travel_state != "idle" or actions_need_release or not pending_shot.is_empty():
		return
	if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		return
	_lock_hovered_target()


func _process_target_surface(body: Node3D) -> Vector3:
	# Aim feedback at the camera-facing surface of the real pick shape. A ring
	# at the body's center is occluded by its own opaque architectural shell.
	var shape: BoxShape3D = body.get_child(1).shape
	var half_size := shape.size * 0.5
	var direction := body.to_local(camera.global_position).normalized()
	if direction.length_squared() < 0.0001:
		direction = (body.global_basis.inverse() * -camera.global_basis.z).normalized()
	var distance := INF
	for axis in 3:
		if absf(direction[axis]) > 0.0001:
			distance = minf(distance, half_size[axis] / absf(direction[axis]))
	return body.to_global(direction * (distance + 0.3))


func _lock_hovered_target() -> void:
	if mode == "vault" or travel_state != "idle" or actions_need_release or not pending_shot.is_empty():
		return
	if hover_pid >= 0:
		selected_pid = hover_pid
		var bodies: Dictionary = remote_monoliths if mode == "remote" else monoliths
		if bodies.has(selected_pid) and is_instance_valid(action_effects):
			action_effects.lock_target(camera, _process_target_surface(bodies[selected_pid]))
		last_action = "LOCK / PID %d @ %s" % [selected_pid, remote_host if mode == "remote" else "LOCAL"]
		_update_hud()


# ---------------------------------------------------------------- traversal

func _action_key_held() -> bool:
	for key in [KEY_X, KEY_K, KEY_F, KEY_C, KEY_Y, KEY_H, KEY_M, KEY_ENTER, KEY_KP_ENTER]:
		if Input.is_key_pressed(key):
			return true
	return false


func _begin_travel(kind: String, destination: String, operation: String) -> bool:
	if travel_state != "idle" or splash != null or farewell != null or arm_screen != null:
		return false
	if not pending_shot.is_empty() or action_http.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		last_action = "wait for the current action result before traveling"
		return false
	if is_instance_valid(action_effects):
		action_effects.clear()
	travel_serial += 1
	travel_kind = kind
	travel_operation = operation
	travel_destination = destination
	travel_elapsed = 0.0
	travel_wait_elapsed = 0.0
	travel_ready = false
	travel_error = ""
	travel_payload = {}
	travel_origin = camera.transform
	travel_origin_fov = camera.fov
	travel_arrival_root = null
	travel_state = "depart"
	erase_hold_start = -1.0
	remote_tick_timer.stop()
	hud.visible = false
	crosshair.visible = false
	hover_label.visible = false
	if is_instance_valid(travel_overlay):
		travel_overlay.begin(kind, destination)
		travel_overlay.set_phase("AWAITING DIRECTORY" if operation == "vault" else "AWAITING REMOTE SNAPSHOT" if operation == "ssh" else "RETURNING TO PREVIOUS WORLD")
	return true


func _travel_coverage(value: float) -> void:
	if is_instance_valid(travel_overlay):
		travel_overlay.coverage = value


func _advance_travel(delta: float) -> void:
	if travel_state == "idle":
		return
	travel_elapsed += delta
	if travel_state == "depart":
		var duration := 0.55 if travel_kind == "ssh" else 0.45
		var t := smoothstep(0.0, 1.0, clampf(travel_elapsed / duration, 0.0, 1.0))
		_travel_coverage(t)
		camera.position = travel_origin.origin - travel_origin.basis.z * (18.0 * t)
		if travel_kind == "vault":
			camera.position.y -= t * 8.0
		camera.fov = lerpf(travel_origin_fov, 82.0 if travel_kind == "ssh" else 58.0, t)
		if travel_elapsed < duration:
			return
		travel_state = "waiting"
		travel_elapsed = 0.0
	if travel_state == "waiting":
		travel_wait_elapsed += delta
		if not travel_ready and travel_wait_elapsed > 20.0:
			_reject_travel("navigation timed out; original world preserved")
		if travel_ready:
			_commit_travel()
		return
	if travel_state == "arrive":
		var t := smoothstep(0.0, 1.0, clampf(travel_elapsed / 0.7, 0.0, 1.0))
		_travel_coverage(1.0 - t)
		if travel_error == "":
			camera.position = travel_camera_start.lerp(travel_camera_end, t)
			camera.fov = lerpf(74.0 if travel_kind == "ssh" else 60.0, travel_origin_fov, t)
			if is_instance_valid(travel_arrival_root):
				travel_arrival_root.position.y = lerpf(-12.0, 0.0, t)
		if travel_elapsed >= 0.7:
			_finish_travel()


func _activate_world(next_mode: String) -> void:
	mode = next_mode
	world_root.visible = mode == "world"
	vault_root.visible = mode == "vault"
	remote_root.visible = mode == "remote"
	selected_pid = -1
	if is_instance_valid(action_effects):
		action_effects.clear()
	hover_pid = -1
	hover_mount_path = ""
	hover_ssh_host = ""
	erase_hold_start = -1.0
	hover_label.text = ""


func _commit_travel() -> void:
	# Everything below is hidden behind full coverage. Failed replies do not
	# mutate mode, host, path, visible roots or the target namespace.
	_travel_coverage(1.0)
	if travel_error != "":
		camera.transform = travel_origin
		camera.fov = travel_origin_fov
		last_action = "REFUSED: " + travel_error
		if is_instance_valid(travel_overlay):
			travel_overlay.set_phase("RETURNING / " + travel_error)
	else:
		match travel_operation:
			"vault":
				vault_host = travel_vault_host
				vault_path = str(travel_payload["path"])
				vault_parent = str(travel_payload.get("parent", ""))
				_render_vault(travel_payload["entries"], bool(travel_payload.get("truncated", false)))
				_activate_world("vault")
				camera.position = Vector3(0, 82, 250)
				camera.look_at(Vector3(0, 22, -20))
				travel_arrival_root = vault_root
				last_action = "entered " + (vault_host + ":" if vault_host != "" else "") + vault_path
			"ssh":
				# The SSH alias routes actions; the reported hostname is descriptive.
				remote_host = travel_destination
				_render_remote(travel_payload)
				_activate_world("remote")
				camera.position = Vector3(0, 120, 520)
				camera.look_at(Vector3(0, 35, 140))
				travel_arrival_root = remote_root
				last_action = "arrived at " + remote_host
			"leave_remote_vault":
				vault_host = ""
				_activate_world("remote")
				camera.position = Vector3(0, 120, 520)
				camera.look_at(Vector3(0, 35, 140))
				travel_arrival_root = remote_root
				last_action = "left remote vault"
			"home":
				remote_host = ""
				vault_host = ""
				_activate_world("world")
				camera.position = HOME_POS
				camera.look_at(Vector3(0, 24, 420))
				travel_arrival_root = world_root
				last_action = "returned home"
		travel_camera_end = camera.position
		travel_camera_start = travel_camera_end + Vector3(0, 12, 32)
		camera.position = travel_camera_start
		if is_instance_valid(travel_arrival_root):
			travel_arrival_root.position.y = -12.0
		if is_instance_valid(travel_overlay):
			travel_overlay.set_phase("DIRECTORY RECEIVED / MATERIALIZING" if travel_operation == "vault" else "REMOTE SNAPSHOT RECEIVED / ARRIVING" if travel_operation == "ssh" else "WORLD RESTORED / ARRIVING")
	travel_state = "arrive"
	travel_elapsed = 0.0
	_update_hud()


func _finish_travel() -> void:
	if is_instance_valid(travel_arrival_root):
		travel_arrival_root.position.y = 0.0
	if travel_error == "":
		camera.position = travel_camera_end
	camera.fov = travel_origin_fov
	yaw = camera.rotation.y
	pitch = camera.rotation.x
	travel_state = "idle"
	actions_need_release = true
	erase_hold_start = -1.0
	if is_instance_valid(travel_overlay):
		travel_overlay.finish()
	hud.visible = splash == null and farewell == null and arm_screen == null
	crosshair.visible = hud.visible
	hover_label.visible = hud.visible
	if mode == "remote":
		remote_tick_timer.start()
	_update_hud()


func _reject_travel(message: String) -> void:
	travel_error = message
	travel_ready = true


func _cancel_travel() -> void:
	if travel_state not in ["depart", "waiting"]:
		return
	list_http.cancel_request()
	ssh_http.cancel_request()
	travel_serial += 1  # late callbacks retain their old ticket
	_reject_travel("navigation cancelled")
	_commit_travel()


func _request_listing(path: String, host: String, ticket: int) -> Error:
	list_http.cancel_request()
	if listing_callback.is_valid() and list_http.request_completed.is_connected(listing_callback):
		list_http.request_completed.disconnect(listing_callback)
	listing_callback = _on_listing.bind(ticket)
	list_http.request_completed.connect(listing_callback, CONNECT_ONE_SHOT)
	var url := API + "/list?path=" + path.uri_encode()
	if host != "":
		url = API + "/ssh/list?host=" + host.uri_encode() + "&path=" + path.uri_encode()
	return list_http.request(url)


func _request_remote(host: String, ticket: int) -> Error:
	ssh_http.cancel_request()
	if remote_callback.is_valid() and ssh_http.request_completed.is_connected(remote_callback):
		ssh_http.request_completed.disconnect(remote_callback)
	remote_callback = _on_ssh_world.bind(ticket, host)
	ssh_http.request_completed.connect(remote_callback, CONNECT_ONE_SHOT)
	return ssh_http.request(API + "/ssh/world?host=" + host.uri_encode())


# ---------------------------------------------------------------- ssh travel

func _travel_to(host: String) -> void:
	if not _begin_travel("ssh", host, "ssh"):
		return
	var error := _request_remote(host, travel_serial)
	if error != OK:
		_reject_travel("could not request remote snapshot (%d)" % error)


func _on_ssh_world(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray, ticket: int = -1, requested_host: String = "") -> void:
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	var valid: bool = result == HTTPRequest.RESULT_SUCCESS and code == 200 and parsed is Dictionary and parsed.get("procs") is Array and parsed.has("host")
	if ticket == -1:
		# Refreshes must belong to the active routing namespace, not a hostname
		# supplied by the response (different SSH aliases may report the same one).
		if travel_state == "idle" and mode == "remote" and valid and requested_host != "" and requested_host == remote_host:
			_render_remote(parsed)
		return
	if ticket != travel_serial or travel_operation != "ssh" or travel_state not in ["depart", "waiting"]:
		return
	# Ticket-only calls remain supported by offline fixtures. Real requests bind
	# both their generation and destination in _request_remote().
	if requested_host != "" and requested_host != travel_destination:
		return
	if not valid:
		var message := str(parsed.get("error", "SSH transport failed (HTTP %d / result %d)" % [code, result])) if parsed is Dictionary else "invalid remote response"
		_reject_travel(message)
		return
	travel_payload = parsed
	travel_ready = true


func _refresh_remote() -> void:
	if travel_state == "idle" and mode == "remote" and remote_host != "" and ssh_http.get_http_client_status() == HTTPClient.STATUS_DISCONNECTED:
		_request_remote(remote_host, -1)


func _render_remote(parsed: Dictionary) -> void:
	for c in remote_root.get_children():
		c.queue_free()
	remote_procs = parsed.get("procs", [])
	var fm := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(4000, 4000)
	var fmat := ShaderMaterial.new()
	fmat.shader = preload("res://shaders/grid.gdshader")
	fmat.set_shader_parameter("seam_color", Color(0.05, 0.7, 0.4))
	fmat.set_shader_parameter("major_color", Color(0.2, 1.0, 0.6))
	fm.material_override = fmat
	fm.mesh = pm
	remote_root.add_child(fm)
	var mem_pct: float = float(parsed.get("mem", {}).get("percent", 0))
	var title := Label3D.new()
	title.text = "%s   load %s   mem %.0f%%" % [remote_host,
		" ".join(PackedStringArray(parsed.get("load", []))), mem_pct]
	title.font_size = 96
	title.pixel_size = 0.16
	title.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	title.modulate = Color(0.4, 1.0, 0.7)
	title.position = Vector3(0, 130, 0)
	remote_root.add_child(title)
	remote_monoliths.clear()
	remote_rogues.clear()
	for rp in parsed.get("enemies", []):
		remote_rogues[int(rp)] = true
	for p in remote_procs:
		var pid: int = int(p["pid"])
		var mem_mb: float = float(p["mem_rss"]) / 1048576.0
		var height: float = Art.process_height(mem_mb, pid)
		var h1 := (pid * 2654435761) % 4093
		var h2 := (pid * 40503) % 4099
		var pos: Vector3
		if pid == 1:
			pos = Vector3.ZERO
		elif int(p["ppid"]) == 2 or (int(p["ppid"]) == 1 and str(p["name"]).begins_with("[")):
			var ang := lerpf(0, TAU, float(h1 % 1000) / 1000.0)
			var rad := 110.0 + float(h2 % 100) * 0.6
			pos = Vector3(cos(ang) * rad, 0, sin(ang) * rad)
		else:
			pos = Vector3(float(h1 % 500) - 250.0, 0, 160.0 + float(h2 % 300))
		var body := StaticBody3D.new()
		var m := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(6, height, 6)
		m.mesh = bm
		var mat := StandardMaterial3D.new()
		mat.emission_enabled = true
		var color := Color(0.4, 1.0, 0.7)  # remote kin are jade
		if remote_rogues.has(pid):
			color = Color(1.0, 0.1, 0.1)  # ROGUE abroad
		elif pid == 1:
			color = Color(1.0, 0.85, 0.0)
		elif str(p["user"]) == "root":
			color = Color(0.2, 0.75, 0.45)
		elif str(p["state"]) == "T":
			color = Color(0.25, 0.28, 0.32)
		mat = Art.material(color, 0.2 + clampf(float(p["cpu"]) / 100.0, 0.0, 0.65))
		m.material_override = mat
		body.add_child(m)
		var cs := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = Vector3(6, height, 6)
		cs.shape = shape
		body.add_child(cs)
		body.position = Vector3(pos.x, height / 2.0, pos.z)
		body.collision_layer = 4
		remote_root.add_child(body)
		remote_monoliths[pid] = body
		if remote_rogues.has(pid):
			var tag := Label3D.new()
			tag.text = "▼ ROGUE @ %s ▼" % remote_host
			tag.font_size = 64
			tag.pixel_size = 0.02
			tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			tag.outline_size = 8
			tag.outline_modulate = Color(0, 0, 0, 0.9)
			tag.modulate = Color(1.0, 0.15, 0.15)
			tag.position = Vector3(pos.x, height + 16.0, pos.z)
			remote_root.add_child(tag)


func _return_home() -> void:
	if _begin_travel("ssh" if mode == "remote" else "vault", "LOCAL / " + str(world.get("host", {}).get("hostname", "HOME")), "home"):
		travel_ready = true


func _remote_proc(pid: int):
	for p in remote_procs:
		if int(p["pid"]) == pid:
			return p
	return null


func _update_remote_hover() -> void:
	hover_pid = -1
	var space := camera.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		camera.global_position,
		camera.global_position + camera.global_transform.basis.z * -1500.0)
	query.collision_mask = 4
	var hit := space.intersect_ray(query)
	if hit.is_empty() or not hit.has("collider"):
		hover_label.text = "REMOTE: %s — F/C/K act on this machine · Esc: return home" % remote_host
		return
	for pid in remote_monoliths:
		if remote_monoliths[pid] == hit["collider"]:
			hover_pid = pid
			break
	var p = null
	if hover_pid >= 0:
		p = _remote_proc(hover_pid)
	if p == null:
		hover_label.text = "REMOTE: %s — F/C/K act on this machine · Esc: return home" % remote_host
		return
	hover_label.add_theme_color_override("font_color", Color(0.4, 1.0, 0.7))
	var what: String = "ROGUE" if remote_rogues.has(int(p["pid"])) else str(_species(p)["name"])
	hover_label.text = "%s @ %s  ·  pid %d '%s'  ·  %s  ·  cpu %s%%  ·  %dMB  ·  %s" % [
		what, remote_host, p["pid"], p["name"], p["state"],
		p["cpu"], int(float(p["mem_rss"]) / 1048576.0), p["user"]]

func _enter_vault(path: String, host: String = "") -> void:
	var destination_host := vault_host if mode == "vault" and host == "" else host
	if not _begin_travel("vault", (destination_host + ":" if destination_host != "" else "") + path, "vault"):
		return
	travel_vault_host = destination_host
	var error := _request_listing(path, destination_host, travel_serial)
	if error != OK:
		_reject_travel("could not request directory (%d)" % error)


func _on_listing(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray, ticket: int = -1) -> void:
	if ticket != travel_serial or travel_operation != "vault" or travel_state not in ["depart", "waiting"]:
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if result != HTTPRequest.RESULT_SUCCESS or code != 200 or not parsed is Dictionary or not parsed.get("entries") is Array or not parsed.has("path"):
		var message := str(parsed.get("error", "directory transport failed (HTTP %d / result %d)" % [code, result])) if parsed is Dictionary else "invalid directory response"
		_reject_travel(message)
		return
	travel_payload = parsed
	travel_ready = true


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
	var fmat := ShaderMaterial.new()
	fmat.shader = preload("res://shaders/grid.gdshader")
	fmat.set_shader_parameter("cell_size", 26.0)
	fmat.set_shader_parameter("seam_color", Art.AMBER.darkened(0.45))
	fmat.set_shader_parameter("major_color", Art.AMBER.darkened(0.5))
	fmat.set_shader_parameter("plate_color", Color("0b1015"))
	fm.material_override = fmat
	fm.mesh = pm
	vault_root.add_child(fm)
	var title := Label3D.new()
	title.text = "%s   (%d entries%s)" % [vault_path, entries.size(),
		", truncated" if truncated else ""]
	title.font_size = 96
	title.pixel_size = 0.16
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
		mat = Art.material(color, 0.3)
		m.material_override = mat
		body.add_child(m)
		var cs := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		cs.shape = shape
		body.add_child(cs)
		body.position = Vector3(x, h / 2.0, z)
		m.scale = Vector3(10, h, 10)
		shape.size = Vector3(10, h, 10)
		body.collision_layer = 2
		vault_root.add_child(body)
		vault_bodies[body] = e


func _vault_hover() -> Dictionary:
	var space := camera.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		camera.global_position,
		camera.global_position + camera.global_transform.basis.z * -1500.0)
	query.collision_mask = 2
	var hit := space.intersect_ray(query)
	if hit.is_empty() or not hit.has("collider"):
		return {}
	if vault_bodies.has(hit["collider"]):
		return {"body": hit["collider"], "entry": vault_bodies[hit["collider"]]}
	return {}


func _vault_hover_text() -> void:
	var hit := _vault_hover()
	if hit.is_empty():
		hover_label.text = ""
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
		_enter_vault(vault_path.rstrip("/") + "/" + str(e["name"]), vault_host)


func _vault_leave() -> void:
	var to_remote := vault_host != ""
	if _begin_travel("vault", remote_host if to_remote else "LOCAL WORLD", "leave_remote_vault" if to_remote else "home"):
		travel_ready = true


func _vault_erase() -> void:
	if travel_state != "idle" or actions_need_release:
		return
	var hit := _vault_hover()
	if hit.is_empty():
		last_action = "nothing to erase under crosshair"
		return
	var e: Dictionary = hit["entry"]
	var full := vault_path.rstrip("/") + "/" + str(e["name"])
	if oracle_armed and vault_host == "":
		# armed: the Oracle erases as root — guardrails are its own now
		_oracle_verb("rm '%s'" % full)
		last_action = "ORACLE erasing %s..." % full
		return
	var payload := {"verb": "rm", "path": full, "confirm": true}
	if vault_host != "":
		payload["host"] = vault_host
	var body := JSON.stringify(payload)
	action_http.request(API + "/action", [], HTTPClient.METHOD_POST, body)
	last_action = "erasing %s..." % full


func _request_action(payload: Dictionary) -> Error:
	return action_http.request(API + "/action", [], HTTPClient.METHOD_POST, JSON.stringify(payload))


func _set_action_result(state: String, text: String) -> void:
	action_result = {"state": state, "text": text}
	action_result_expires = Time.get_ticks_msec() + 5500
	last_action = text
	_update_hud()


func _act(sig: int) -> void:
	if travel_state != "idle" or actions_need_release or not pending_shot.is_empty():
		return
	if action_http.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		_set_action_result("error", "BUSY / WAIT FOR THE CURRENT ACTION RESULT")
		return
	var bodies: Dictionary = remote_monoliths if mode == "remote" else monoliths
	if selected_pid < 0 or not bodies.has(selected_pid) or not is_instance_valid(bodies[selected_pid]):
		_set_action_result("error", "NO TARGET / LOCK A PROCESS FIRST")
		return
	var payload := {"verb": "kill", "pid": selected_pid, "sig": sig}
	var label := "FREEZE" if sig == 19 else "RESUME" if sig == 18 else "SMITE"
	var effect_verb := "freeze" if sig == 19 else "resume" if sig == 18 else "smite"
	var host := remote_host if mode == "remote" else "LOCAL"
	if mode == "remote":
		payload["host"] = remote_host
	elif oracle_armed and sig == 9:
		payload = {"verb": "oracle", "line": "kill %d 9" % selected_pid}
	pending_shot = {"pid": selected_pid, "host": host, "verb": label}
	var error := _request_action(payload)
	if error != OK:
		pending_shot = {}
		_set_action_result("error", "NOT FIRED / REQUEST QUEUE ERROR %d" % error)
		return
	if is_instance_valid(action_effects):
		action_effects.fire(camera, _process_target_surface(bodies[selected_pid]), effect_verb)
	_set_action_result("pending", "%s / PID %d @ %s / AWAITING DAEMON" % [label, selected_pid, host])


func _on_action(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var resp: Variant = JSON.parse_string(body.get_string_from_utf8())
	var ok: bool = result == HTTPRequest.RESULT_SUCCESS and code >= 200 and code < 300 and resp is Dictionary and bool(resp.get("ok", false))
	var message := "invalid action response"
	if resp is Dictionary:
		message = str(resp.get("syscall", resp.get("result", "action acknowledged"))) if ok else str(resp.get("error", "action refused"))
	elif result != HTTPRequest.RESULT_SUCCESS or code != 200:
		message = "transport failure (HTTP %d / result %d)" % [code, result]
	var prefix := "CONFIRMED" if ok else "REFUSED" if resp is Dictionary and result == HTTPRequest.RESULT_SUCCESS else "UNCONFIRMED"
	var context := ""
	if not pending_shot.is_empty():
		context = " / PID %d @ %s" % [int(pending_shot["pid"]), str(pending_shot["host"])]
		if is_instance_valid(action_effects):
			action_effects.resolve(ok, message)
	pending_shot = {}
	_set_action_result("ok" if ok else "error", prefix + context + " / " + message)
	if not ok and arm_screen != null and arm_status != null:
		arm_status.text = message

# ---------------------------------------------------------------- hud


func _update_hud() -> void:
	var selected: Variant = _remote_proc(selected_pid) if mode == "remote" else _proc(selected_pid)
	console.update_world(world, {
		"mode": mode, "remote_host": vault_host if mode == "vault" else remote_host,
		"vault_path": vault_path, "selected": selected if selected is Dictionary else {},
		"last_action": last_action, "oracle_armed": oracle_armed,
		"sim_playing": sim_playing, "sim_info": sim_info,
		"rogue_kills": rogue_kills, "rogue_frees": rogue_frees,
		"action_result": action_result if not pending_shot.is_empty() or Time.get_ticks_msec() < action_result_expires else {},
		"vault_entries": vault_bodies.size(), "vault_parent": vault_parent,
		"remote_procs": remote_procs.size(),
	})
