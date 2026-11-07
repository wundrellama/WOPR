extends SceneTree
## Fixture-driven regression: never starts a daemon or sends an HTTP request.
const VisualTest = preload("res://tests/visual_smoke.gd")
var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func check(condition: bool, description: String) -> void:
	if not condition:
		failures.append(description)
		print("REGRESSION_FAIL ", description)


func _run() -> void:
	var game := VisualTest.VisualWorld.new()
	root.add_child(game)
	game._start_game()
	game.poll_timer.stop()
	var data := VisualTest._fixture()
	game._on_world(0, 200, [], JSON.stringify(data).to_utf8_buffer())
	game._enter_vault("/FIXTURE")
	game._on_listing(0, 200, [], JSON.stringify({"path": "/FIXTURE", "parent": "/",
		"entries": [{"name": "fixture-directory", "size": 4096, "dir": true, "mtime": 0}]
	}).to_utf8_buffer(), game.travel_serial)
	game._advance_travel(0.8)
	game._advance_travel(0.8)
	# Outdoor terrain and water must inherit the hidden local world's visibility.
	for child in game.get_children():
		if child is MeshInstance3D and child.mesh is PlaneMesh:
			check(not child.is_visible_in_tree(), "outdoor plane remains visible inside vault")
	check(not game.water.is_visible_in_tree(), "memory tide remains visible inside vault")
	# A hidden local collider deliberately intercepts the camera's vault ray.
	# Visibility does not remove StaticBody3D from physics.
	var obstruction := game._add_box(game.camera.position + -game.camera.basis.z * 12.0,
		Vector3(8, 8, 8), Color.RED, {"kind": "proc", "pid": 999999})
	var entry_body: StaticBody3D = game.vault_bodies.keys()[0]
	game.camera.look_at(entry_body.global_position)
	obstruction.position = game.camera.position + -game.camera.basis.z * 12.0
	await physics_frame
	await physics_frame
	check(not game._vault_hover().is_empty(), "hidden local collider blocks vault picking")
	var readable_title := false
	for child in game.vault_root.get_children():
		if child is Label3D and child.text.contains("FIXTURE"):
			readable_title = child.pixel_size * child.font_size >= 9.0
	check(readable_title, "vault title is microscopic at arrival distance")
	game.remote_host = "fixture-remote"
	game._render_remote({"procs": data.procs, "mem": {"percent": 10}, "load": [], "enemies": []})
	game._activate_world("remote")
	var remote_body: StaticBody3D = game.remote_monoliths[120]
	game.camera.position = remote_body.position + Vector3(0, 0, 40)
	game.camera.look_at(remote_body.global_position)
	obstruction.position = game.camera.position + -game.camera.basis.z * 12.0
	await physics_frame
	await physics_frame
	game._update_remote_hover()
	check(game.hover_pid >= 0, "hidden local collider blocks remote picking")
	check(not game.water.is_visible_in_tree(), "outdoor tide bleeds into SSH world")
	for request in [game.world_http, game.action_http, game.list_http, game.ssh_http]:
		check(request.get_http_client_status() == HTTPClient.STATUS_DISCONNECTED, "unexpected network request")
	game.queue_free()
	await process_frame
	if failures.is_empty():
		print("NAVIGATION_REGRESSION_OK")
	else:
		print("NAVIGATION_REGRESSION_FAILED count=", failures.size())
	quit(0 if failures.is_empty() else 1)
