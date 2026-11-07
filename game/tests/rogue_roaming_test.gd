extends SceneTree
## Pure presentation and disconnected fixture only; no live action boundaries.
const VisualTest = preload("res://tests/visual_smoke.gd")
var failures: Array[String] = []

func _initialize() -> void: call_deferred("_run")

func check(value: bool, description: String) -> void:
	if not value:
		failures.append(description)
		print("ROAM_FAIL ", description)

func _run() -> void:
	var game := VisualTest.VisualWorld.new()
	root.add_child(game)
	game._start_game()
	game.set_process(false)
	var data := VisualTest._fixture()
	game._on_world(0, 200, [], JSON.stringify(data).to_utf8_buffer())
	check(game.has_method("_rogue_roam_pos"), "deterministic broad-field rogue route exists")
	if game.has_method("_rogue_roam_pos"):
		for network in [false, true]:
			var visited := {}
			var previous: Vector3 = game.call("_rogue_roam_pos", 120, 0.0, network)
			for step in 1500:
				var pos: Vector3 = game.call("_rogue_roam_pos", 120, float(step), network)
				check(pos.is_finite() and absf(pos.x) <= 1400 and absf(pos.z) <= 1200, "finite playable bounds")
				check(pos.distance_to(previous) < 35, "catchable smooth speed below walking speed")
				check(network or pos.x >= -300, "local-only hunt excludes harbor and SSH gate footprint")
				if pos.length() < 180: visited.center = true
				if pos.z > 650: visited.cpu = true
				if pos.x > 850: visited.vault = true
				if pos.z < -650: visited.gpu = true
				if pos.x < -850: visited.harbor = true
				previous = pos
			check(visited.has("center") and visited.has("cpu") and visited.has("vault") and visited.has("gpu"), "route reaches kernel, CPU, vaults and GPU")
			check(visited.has("harbor") == network, "network region is opt-in only")
	var local: StaticBody3D = game.monoliths[120]
	var ordinary: Vector3 = game.monoliths[121].position
	var start := local.position
	for frame in 120: game._process(1.0 / 30.0)
	check(local.position.distance_to(start) > 0.1, "local rogue moves between snapshots")
	check(Vector2(game.monoliths[121].position.x, game.monoliths[121].position.z).distance_to(Vector2(ordinary.x, ordinary.z)) < 0.01, "ordinary process district remains unchanged")
	data.procs[119].state = "T"
	game._on_world(0, 200, [], JSON.stringify(data).to_utf8_buffer())
	start = local.position
	for frame in 120: game._process(1.0 / 30.0)
	check(local.position.is_equal_approx(start), "frozen local rogue stops moving")
	game.remote_host = "fixture-alias"
	game._render_remote({"procs": [data.procs[119]], "enemies": [120]})
	var remote: StaticBody3D = game.remote_monoliths[120]
	start = remote.position
	for frame in 120: game._process(1.0 / 30.0)
	check(remote.position.is_equal_approx(start), "frozen remote rogue stops moving")
	data.procs[119].state = "S"
	game._render_remote({"procs": [data.procs[119]], "enemies": [120]})
	remote = game.remote_monoliths[120]
	start = remote.position
	for frame in 120: game._process(1.0 / 30.0)
	check(remote.position.distance_to(start) > 0.1, "remote rogue moves between snapshots in its own namespace")
	check(local.position.is_equal_approx(game.monoliths[120].position) and local != remote, "colliding PID bodies remain independent")
	var before_refresh := remote.position
	game._render_remote({"procs": [data.procs[119]], "enemies": [120]})
	check(game.remote_monoliths[120].position.is_equal_approx(before_refresh), "remote refresh preserves roaming position without teleport")
	for request in [game.world_http, game.action_http, game.list_http, game.ssh_http]:
		check(request.get_http_client_status() == HTTPClient.STATUS_DISCONNECTED, "roaming has no network side effects")
	game.queue_free()
	await process_frame
	print("ROGUE_ROAMING_OK" if failures.is_empty() else "ROGUE_ROAMING_FAILED")
	quit(0 if failures.is_empty() else 1)