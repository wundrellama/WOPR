extends SceneTree
## Reproducible moving captures from offline fixtures, never real system actions.
const Fixture = preload("res://tests/visual_smoke.gd")
const Shots = preload("res://tests/action_feedback_test.gd")

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var kind := "vault"
	var output := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--kind="): kind = arg.trim_prefix("--kind=")
		if arg.begins_with("--output-dir="): output = arg.trim_prefix("--output-dir=")
	var game
	if kind == "shots":
		game = Shots.SafeWorld.new()
	else:
		game = Fixture.VisualWorld.new()
	root.add_child(game)
	game._start_game()
	game.poll_timer.stop()
	game.set_process(false)
	var data := Fixture._fixture()
	game._on_world(0, 200, [], JSON.stringify(data).to_utf8_buffer())
	if output != "":
		DirAccess.make_dir_recursive_absolute(output)
	if kind == "shots":
		# Use one unobstructed fixture tower so the capture tests the effect,
		# not occlusion by unrelated workers in the dense process fixture.
		for pid in game.monoliths.keys():
			if pid != 120:
				game.monoliths[pid].visible = false
		var target: Node3D = game.monoliths[120]
		target.position = Vector3(0, target.position.y, 200)
		game.targets[120] = target.position
		game.camera.position = target.position + Vector3(16, 16, 65)
		game.camera.look_at(target.position)
		game.pitch = game.camera.rotation.x
		game.yaw = game.camera.rotation.y
		game.hover_pid = 120
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		if DisplayServer.get_name() == "headless":
			game._lock_hovered_target()
		else:
			game._pick()
	elif kind == "ssh":
		game._travel_to("test-remote")
	else:
		game._enter_vault("/VISUAL-TEST-FIXTURE")
	for frame in 96:
		if kind == "shots":
			if frame == 12: game._act(19)
			if frame == 20: game._on_action(0, 200, [], JSON.stringify({"ok": true, "syscall": "FIXTURE ACK / SIGSTOP"}).to_utf8_buffer())
			if frame == 36: game._act(18)
			if frame == 44: game._on_action(0, 200, [], JSON.stringify({"ok": true, "syscall": "FIXTURE ACK / SIGCONT"}).to_utf8_buffer())
			if frame == 60: game._act(9)
			if frame == 68: game._on_action(0, 403, [], JSON.stringify({"ok": false, "error": "FIXTURE REFUSAL / protected process"}).to_utf8_buffer())
		elif frame == 25:
			if kind == "ssh":
				game._on_ssh_world(0, 200, [], JSON.stringify({"host": "test-remote", "procs": data.procs, "mem": data.mem, "load": [], "enemies": []}).to_utf8_buffer(), game.travel_serial)
			else:
				var entries: Array = []
				for i in 21:
					entries.append({"name": "fixture-%02d" % i, "dir": i % 3 == 0, "size": 4096 * (i + 1), "mtime": 0})
				game._on_listing(0, 200, [], JSON.stringify({"path": "/VISUAL-TEST-FIXTURE", "parent": "/", "entries": entries}).to_utf8_buffer(), game.travel_serial)
		game._process(1.0 / 30.0)
		game._update_hud()
		game.remote_tick_timer.stop()
		await process_frame
		if output != "" and DisplayServer.get_name() != "headless" and frame % 3 == 0:
			await RenderingServer.frame_post_draw
			assert(root.get_texture().get_image().save_png(output.path_join("%03d.png" % frame)) == OK)
	for request in [game.world_http, game.action_http, game.list_http, game.ssh_http]:
		assert(request.get_http_client_status() == HTTPClient.STATUS_DISCONNECTED, "No live network in animation captures")
	assert(game.travel_state == "idle", "Capture must include completed arrival")
	if kind == "shots":
		assert(game.sent.size() == 3 and game.action_result.state == "error", "Capture must exercise all three shots and the refusal reply")
	print("PRESENTATION_SEQUENCE_OK kind=", kind)
	game.queue_free()
	await process_frame
	quit()
