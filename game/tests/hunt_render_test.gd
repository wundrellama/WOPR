extends SceneTree
## Offline regression: feed the same JSON serialization boundary as the daemon.
const VisualTest = preload("res://tests/visual_smoke.gd")
var failures: Array[String] = []

func _initialize() -> void: call_deferred("_run")

func check(condition: bool, description: String) -> void:
	if not condition:
		failures.append(description)
		print("HUNT_FAIL ", description)

func _run() -> void:
	var data := VisualTest._fixture()
	var wire: Variant = JSON.parse_string(JSON.stringify(data))
	print("HUNT_JSON enemy_type=", typeof(wire.enemies[0]), " proc_pid_type=", typeof(wire.procs[119].pid),
		" int_membership=", int(wire.procs[119].pid) in wire.enemies)
	var game := VisualTest.VisualWorld.new()
	root.add_child(game)
	game._start_game()
	game.poll_timer.stop()
	game._on_world(0, 200, [], JSON.stringify(data).to_utf8_buffer())
	var pid := 120
	var p: Variant = game._proc(pid)
	check(p != null, "hunt PID has a real process in the snapshot")
	check(game._species(p).name == "ROGUE", "JSON enemy PID is recognized as a rogue")
	check(game.rogue_tags.has(pid), "recognized rogue gets a visible targeting label")
	var position: Vector3 = game._district_pos(p)
	check(absf(position.z - game.PLAINS_Z) < 450.0, "rogue uses roaming CPU-plains geography")
	if game.rogue_tags.has(pid):
		var tag: Label3D = game.rogue_tags[pid]
		check(tag.pixel_size * tag.font_size >= 8.0, "rogue tag remains readable at gameplay distance")
	game._process(0)
	var locators: Variant = game.crosshair.get("hunt_targets")
	check(locators is Dictionary, "hunt provides on-screen/off-screen rogue locators")
	if locators is Dictionary:
		check(locators.has(pid), "active local rogue has a locator")
		game.camera.position = game.monoliths[pid].global_position + Vector3(0, 12, 90)
		game.camera.look_at(game.monoliths[pid].global_position)
		var marker: Dictionary = game.crosshair.call("hunt_marker", game.monoliths[pid].global_position)
		check(not marker.behind and not marker.offscreen, "visible rogue marker tracks its actual body")
		game.camera.rotate_y(PI)
		marker = game.crosshair.call("hunt_marker", game.monoliths[pid].global_position)
		check(marker.behind and marker.offscreen and marker.point.is_finite(), "behind-camera rogue has a finite edge direction marker")
		marker = game.crosshair.call("hunt_marker", game.camera.global_position)
		check(marker.point.is_finite(), "coincident camera/rogue marker has a finite position")
		marker = game.crosshair.call("hunt_marker", game.camera.global_position + game.camera.global_basis.x * 10.0)
		check(marker.point.is_finite(), "camera-plane rogue has a finite edge marker")
		check(game.crosshair.has_method("hunt_label_rect"), "clustered edge labels have collision-aware layout")
		if game.crosshair.has_method("hunt_label_rect"):
			var first: Rect2 = game.crosshair.call("hunt_label_rect", Vector2(740, 600), Vector2(280, 20), [])
			var second: Rect2 = game.crosshair.call("hunt_label_rect", Vector2(780, 600), Vector2(280, 20), [first])
			check(not first.grow(3).intersects(second), "nearby off-screen rogue labels do not overlap")
	# Same PID on another host is not the same process or hunt target.
	game.remote_host = "fixture-remote"
	game._render_remote({"procs": [p], "mem": {}, "load": [], "enemies": []})
	game._activate_world("remote")
	var remote_body: StaticBody3D = game.remote_monoliths[pid]
	game.camera.position = remote_body.position + Vector3(0, 0, 40)
	game.camera.look_at(remote_body.global_position)
	await physics_frame
	await physics_frame
	game._update_remote_hover()
	check(not game.hover_label.text.begins_with("ROGUE"), "a local rogue PID cannot label a normal remote process")
	game._process(0)
	check(game.crosshair.hunt_targets.is_empty(), "local rogue locators cannot leak into the remote namespace")
	game._render_remote({"procs": [p], "mem": {}, "load": [], "enemies": [float(pid)]})
	game._process(0)
	check(game.crosshair.hunt_targets.has(pid), "remote JSON rogue receives its own locator")
	for child in game.remote_root.get_children():
		if child is Label3D and child.text.contains("ROGUE"):
			check(child.pixel_size * child.font_size >= 8.0, "remote rogue label is readable too")
	game._activate_world("vault")
	check(game._hunt_targets().is_empty(), "outdoor hunt markers do not leak into a file vault")
	data.enemies = []
	game._on_world(0, 200, [], JSON.stringify(data).to_utf8_buffer())
	check(game.local_rogues.is_empty() and not game.rogue_tags.has(pid), "dead/disabled rogue loses cached identity and tag on the next snapshot")
	check(game._species(game._proc(pid)).name != "ROGUE", "a reused/normal PID is not permanently marked hostile")
	for request in [game.world_http, game.action_http, game.list_http, game.ssh_http]:
		check(request.get_http_client_status() == HTTPClient.STATUS_DISCONNECTED, "no live network or spawning during hunt tests")
	game.queue_free()
	await process_frame
	print("HUNT_RENDER_OK" if failures.is_empty() else "HUNT_RENDER_FAILED")
	quit(0 if failures.is_empty() else 1)
