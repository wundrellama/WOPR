extends SceneTree
## Isolated visual test. Never starts, adopts, polls or stops a real daemon.
## All data below is explicitly synthetic test-fixture data, not telemetry.
## Run with an offscreen X server for real shader compilation / PNG capture.

class VisualWorld extends "res://scripts/main.gd":
	func _daemon_running() -> bool:
		return true

	func _spawn_daemon() -> void:
		assert(false, "Visual test must never spawn a daemon")

	func _shutdown_daemon() -> void:
		pass

	func _poll_world() -> void:
		pass

	func _request_listing(_path: String, _host: String, _ticket: int) -> Error:
		return OK

	func _request_remote(_host: String, _ticket: int) -> Error:
		return OK

	func _unhandled_input(_event: InputEvent) -> void:
		pass

	func _act(_sig: int) -> void:
		assert(false, "No syscalls in visual tests")

	func _oracle_verb(_line: String) -> void:
		assert(false, "No Oracle in visual tests")

	func _vault_erase() -> void:
		assert(false, "No file actions in visual tests")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var view := "world"
	var output := ""
	var snapshot := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--snapshot="):
			snapshot = arg.trim_prefix("--snapshot=")
		if arg.begins_with("--view="):
			view = arg.trim_prefix("--view=")
		if arg.begins_with("--output="):
			output = arg.trim_prefix("--output=")
	var game := VisualWorld.new()
	root.add_child(game)
	var data := _fixture()
	if view in ["hunt", "hunt-behind"]:
		data.enemies = [120, 121, 122]
	if snapshot != "":
		data = JSON.parse_string(FileAccess.get_file_as_string(snapshot))
		assert(data.has("procs"), "Invalid read-only snapshot")
	if view != "title":
		game._start_game()
		game._on_world(0, 200, PackedStringArray(), JSON.stringify(data).to_utf8_buffer())
		game.poll_timer.stop()
		if view == "hunt-behind":
			game.camera.rotate_y(PI)
			game.yaw = game.camera.rotation.y
		elif view == "target":
			game.selected_pid = 120
		elif view == "sim":
			game.sim_playing = true
		elif view == "remote":
			game._travel_to("test-remote")
			game._on_ssh_world(0, 200, PackedStringArray(), JSON.stringify({
				"host": "test-remote", "procs": data["procs"], "mem": data["mem"],
				"load": [0.2, 0.4, 0.5], "enemies": [120]
			}).to_utf8_buffer(), game.travel_serial)
			game._advance_travel(0.8)
			game._advance_travel(0.8)
			game._process(0)
			game.remote_tick_timer.stop()
			game.selected_pid = 120
		elif view == "vault":
			game._enter_vault("/TEST-FIXTURE/NOT-REAL-FILES")
			game._on_listing(0, 200, PackedStringArray(), JSON.stringify({
				"path": "/TEST-FIXTURE/NOT-REAL-FILES", "parent": "/TEST-FIXTURE",
				"entries": [{"name": "fixture-directory", "size": 4096, "dir": true, "mtime": 0},
					{"name": "fixture-file", "size": 1048576, "dir": false, "mtime": 0}]
			}).to_utf8_buffer(), game.travel_serial)
			game._advance_travel(0.8)
			game._advance_travel(0.8)
			game._process(0)
		elif view == "armed":
			game.oracle_armed = true
		elif view == "ritual":
			game._build_arm_screen()
		elif view == "farewell":
			game._show_farewell()
		game._update_hud()
	# Compile shaders and exercise _process(), not just the GDScript parser.
	for frame in 40:
		await process_frame
	if output != "" and DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		var error := root.get_texture().get_image().save_png(output)
		assert(error == OK, "Screenshot write failed")
		print("VISUAL_CAPTURE ", output)
	if view != "title":
		assert(game.monoliths.size() == data["procs"].size(), "Each process must have a tower")
		for pid in game.monoliths:
			var tower: StaticBody3D = game.monoliths[pid]
			assert(tower.get_child(0).scale.is_equal_approx(tower.get_child(1).shape.size), "Visible tower and pick shape must match")
		if view == "ritual":
			assert(game.arm_field.secret, "Oracle input must be masked")
		if view == "remote":
			assert(game.console._labels.target_heading.text.contains("test-remote"), "Target must show active remote namespace")
		if view == "sim":
			assert(game.console._labels.safety.text == "SIM / ALL VERBS FROZEN")
		if view == "armed":
			assert(game.console._labels.safety.text == "ROOT ARMED / REAL SYSCALLS")
	for request in [game.world_http, game.action_http, game.list_http, game.ssh_http]:
		assert(request.get_http_client_status() == HTTPClient.STATUS_DISCONNECTED, "Visual tests must not contact any server")
	print("VISUAL_SMOKE_OK view=", view, " processes=", data["procs"].size(),
		" draw_calls=", Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	game.queue_free()
	await process_frame
	quit()


static func _fixture() -> Dictionary:
	var procs: Array = []
	for i in 230:
		procs.append({"pid": i + 1, "ppid": 2 if i < 35 else 100,
			"name": "fixture-worker-%03d" % i, "user": "root" if i < 55 else "operator",
			"state": "T" if i % 23 == 0 else "S", "cpu": float(i % 35),
			"mem_rss": (8 + i % 180) * 1048576, "cpu_num": i % 16,
			"threads": 4, "children": 0, "age": 120,
			"cmdline": "TEST FIXTURE / not a running process"})
	return {"tick": 42, "host": {"hostname": "VISUAL TEST FIXTURE", "os": "Offline", "uptime": 3600},
		"me": {"user": "operator", "pid": -1}, "procs": procs,
		"cpu": {"count": 16, "total": 28, "per_core": [10, 20, 40, 15, 70, 30, 20, 50, 12, 34, 56, 10, 20, 30, 40, 50]},
		"mem": {"total": 34359738368, "used": 12025908428, "percent": 35,
			"swap_total": 8589934592, "swap_used": 0},
		"net": {"conns": [], "remote_hosts": [{"ip": "192.0.2.1", "count": 12},
			{"ip": "192.0.2.2", "count": 5}, {"ip": "192.0.2.3", "count": 20}]},
		"hw": {"gpu_busy": 34, "mounts": [{"path": "/TEST-FIXTURE", "percent": 64,
			"total": 1099511627776, "fstype": "test"}]},
		"ssh": {"hosts": [], "status": {}}, "enemies": [120], "enemies_level": 1,
		"oracle": {"armed": false}, "sim": {"playing": false, "length": 600, "idx": 40, "name": "visual fixture"}}
