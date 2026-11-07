extends SceneTree
## Exercises the real shot controller with an offline transport seam.
const Fixture = preload("res://tests/visual_smoke.gd")
var failures: Array[String] = []

class SafeWorld extends "res://scripts/main.gd":
	var sent: Array = []
	var send_error: Error = OK
	func _daemon_running() -> bool: return true
	func _spawn_daemon() -> void: assert(false, "No daemon")
	func _shutdown_daemon() -> void: pass
	func _poll_world() -> void: pass
	func _request_action(payload: Dictionary) -> Error:
		sent.append(payload.duplicate(true))
		return send_error

func _initialize() -> void: call_deferred("_run")

func check(condition: bool, description: String) -> void:
	if not condition:
		failures.append(description)
		print("ACTION_FAIL ", description)

func reply(game: SafeWorld, code: int, payload: Variant) -> void:
	game._on_action(0, code, [], JSON.stringify(payload).to_utf8_buffer())

func _run() -> void:
	var game := SafeWorld.new()
	root.add_child(game)
	game._start_game()
	game.poll_timer.stop()
	game.set_process(false)
	var data := Fixture._fixture()
	game._on_world(0, 200, [], JSON.stringify(data).to_utf8_buffer())
	if game.get("action_result") == null:
		check(false, "shots need visible pending/confirmed/refused feedback driven by real replies")
		game.queue_free()
		await process_frame
		quit(1)
		return
	game.hover_pid = 120
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	# The dummy display cannot capture a mouse; exercise the lock operation
	# directly here. The rendered sequence additionally exercises _pick().
	game._lock_hovered_target()
	check(game.selected_pid == 120, "target selection still locks the hovered process")
	check(game.get("action_effects").get_child_count() > 0, "targeting renders a lock pulse")
	for sig in [19, 18, 9]:
		game._act(sig)
		check(game.sent[-1].sig == sig and game.sent[-1].pid == 120, "beam preserves the requested real signal")
		check(game.get("action_result").state == "pending", "fire is pending, not a fake successful hit")
		var tower: StaticBody3D = game.monoliths[120]
		var half_size: Vector3 = tower.get_child(1).shape.size * 0.5
		var local_impact := tower.to_local(game.get("action_effects").get("_last_impact"))
		check(not AABB(-half_size, half_size * 2.0).has_point(local_impact), "beam/result pulse must land on the visible surface, not be buried inside the tower")
		var count := game.sent.size()
		game._act(sig)
		game._act(18 if sig != 18 else 19)
		game._act(9 if sig != 9 else 19)
		check(game.sent.size() == count, "a burst of distinct signals cannot overwrite the pending response")
		check(game.get("action_effects").get_child_count() > 0, "firing creates transient beam geometry")
		reply(game, 200, {"ok": true, "syscall": "FIXTURE ACK signal %d" % sig})
		check(game.get("action_result").state == "ok", "successful daemon reply confirms the shot")
		check(game.last_action.contains("FIXTURE ACK"), "actual returned result is displayed")
		check(game.get("pending_shot").is_empty(), "completed request releases shot lock")
	game._act(9)
	reply(game, 403, {"ok": false, "error": "FIXTURE protected process"})
	check(game.get("action_result").state == "error" and game.last_action.contains("FIXTURE protected process"), "refused signal is visibly refused")
	game._act(9)
	reply(game, 500, null)
	check(game.get("action_result").state == "error", "malformed response fails honestly without a crash")
	game.oracle_armed = true
	game._act(9)
	check(game.sent[-1].verb == "oracle" and game.sent[-1].line == "kill 120 9", "armed local smite retains the Oracle verb")
	reply(game, 200, {"ok": true, "result": "FIXTURE root acknowledgement"})
	var original_camera_position := game.camera.position
	game.camera.position = game.monoliths[120].position
	check(game._process_target_surface(game.monoliths[120]).is_finite(), "flying inside a target still gives a finite effect endpoint")
	game.camera.position = original_camera_position
	game.remote_host = "test-remote"
	game._render_remote({"procs": data.procs, "mem": {}, "load": [], "enemies": []})
	game._activate_world("remote")
	game.selected_pid = 120
	game._act(9)
	check(game.sent[-1].verb == "kill" and game.sent[-1].host == "test-remote", "remote shot is never redirected through local Oracle")
	reply(game, 200, {"ok": true, "syscall": "FIXTURE remote kill"})
	game.send_error = ERR_BUSY
	game._act(19)
	check(game.get("action_result").state == "error" and game.get("pending_shot").is_empty(), "transport queue failure does not claim a fired shot")
	game.send_error = OK
	game._act(19)
	check(not game._begin_travel("ssh", "another-host", "ssh"), "travel cannot redirect a pending shot result")
	reply(game, 200, {"ok": true, "syscall": "FIXTURE done"})
	for request in [game.world_http, game.action_http, game.list_http, game.ssh_http]:
		check(request.get_http_client_status() == HTTPClient.STATUS_DISCONNECTED, "no test request reaches a real server")
	game.get("action_effects").clear()
	await process_frame
	check(game.get("action_effects").get_child_count() == 0, "expired/cleared shot geometry is cleaned up")
	game.queue_free()
	await process_frame
	print("ACTION_FEEDBACK_OK" if failures.is_empty() else "ACTION_FEEDBACK_FAILED")
	quit(0 if failures.is_empty() else 1)
