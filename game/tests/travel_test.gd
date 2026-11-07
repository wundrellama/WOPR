extends SceneTree
## Navigation state-machine tests: transport seams are offline, not real HTTP.
const Fixture = preload("res://tests/visual_smoke.gd")
var failures: Array[String] = []

class SafeWorld extends "res://scripts/main.gd":
	var requests: Array = []
	var act_calls := 0
	var held_action := false
	var sent_actions: Array = []
	var hovered_entry: Dictionary = {}
	func _daemon_running() -> bool: return true
	func _spawn_daemon() -> void: assert(false, "No daemon")
	func _shutdown_daemon() -> void: pass
	func _poll_world() -> void: pass
	func _request_listing(path: String, host: String, ticket: int) -> Error:
		requests.append({"kind": "vault", "path": path, "host": host, "ticket": ticket})
		return OK
	func _request_remote(host: String, ticket: int) -> Error:
		requests.append({"kind": "ssh", "host": host, "ticket": ticket})
		return OK
	func _action_key_held() -> bool: return held_action
	func _request_action(payload: Dictionary) -> Error:
		act_calls += 1
		sent_actions.append(payload.duplicate(true))
		return OK
	func _vault_hover() -> Dictionary: return hovered_entry

func _initialize() -> void: call_deferred("_run")

func check(condition: bool, description: String) -> void:
	if not condition:
		failures.append(description)
		print("TRAVEL_FAIL ", description)

func key(game: SafeWorld, code: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	game._unhandled_input(event)

func advance(game: SafeWorld, delta: float) -> void:
	game.call("_advance_travel", delta)

func directory() -> PackedByteArray:
	return JSON.stringify({"path": "/FIXTURE", "parent": "/", "entries": [
		{"name": "folder", "dir": true, "size": 4096, "mtime": 0}]}).to_utf8_buffer()

func _run() -> void:
	var game := SafeWorld.new()
	root.add_child(game)
	game._start_game()
	game.poll_timer.stop()
	game.set_process(false)
	game._on_world(0, 200, [], JSON.stringify(Fixture._fixture()).to_utf8_buffer())
	if game.get("travel_state") == null:
		check(false, "navigation must have an animated, input-gated state machine instead of teleporting")
		game.queue_free()
		await process_frame
		quit(1)
		return
	game.selected_pid = 120
	game._enter_vault("/FIXTURE")
	check(game.get("travel_state") == "depart", "vault starts departure animation")
	check(game.travel_overlay.visible, "departure displays the animated overlay")
	check(game.mode == "world", "origin remains visible until covered and response succeeds")
	game._enter_vault("/DUPLICATE")
	check(game.requests.size() == 1, "repeated Enter cannot issue duplicate navigation")
	key(game, KEY_K)
	check(game.act_calls == 0, "action key is blocked in departure")
	advance(game, 0.7)
	check(game.get("travel_state") == "waiting", "covered transition waits for real response")
	check(game.travel_overlay.coverage == 1.0, "origin/destination swap is fully concealed")
	check(game.mode == "world", "waiting is not a fake successful arrival")
	var ticket: int = game.requests[-1].ticket
	game.call("_on_listing", 0, 200, PackedStringArray(), directory(), ticket + 99)
	advance(game, 0.01)
	check(game.mode == "world", "stale/unrelated replies cannot change worlds")
	game.call("_on_listing", 0, 200, PackedStringArray(), directory(), ticket)
	advance(game, 0.01)
	check(game.mode == "vault" and game.get("travel_state") == "arrive", "successful reply builds vault under full cover")
	check(game.selected_pid == -1, "arrival clears old-machine target lock")
	check(not game.water.is_visible_in_tree(), "arrival hides outdoor tide")
	game.held_action = true
	advance(game, 1.0)
	game._process(0)
	check(bool(game.get("actions_need_release")), "held action keys must be released after arrival")
	game.held_action = false
	game._process(0)
	check(not bool(game.get("actions_need_release")), "released controls rearm normally")
	check(not game.travel_overlay.visible and game.hud.visible, "arrival hides transit and restores the HUD")
	game._vault_leave()
	advance(game, 0.7)
	advance(game, 1.0)
	check(game.mode == "world" and game.world_root.visible and not game.vault_root.visible, "leaving vault animates home and hides the hall")
	game._process(0)
	game._travel_to("test-remote")
	advance(game, 0.7)
	ticket = game.requests[-1].ticket
	var remote := {"host": "fixture-server01", "procs": Fixture._fixture().procs, "mem": {"percent": 35}, "load": [], "enemies": []}
	game.call("_on_ssh_world", 0, 200, PackedStringArray(), JSON.stringify(remote).to_utf8_buffer(), ticket + 99, "test-remote")
	check(not game.travel_ready, "stale SSH generation cannot satisfy travel")
	game.call("_on_ssh_world", 0, 200, PackedStringArray(), JSON.stringify(remote).to_utf8_buffer(), ticket, "other-alias")
	check(not game.travel_ready, "another alias cannot satisfy the current SSH request")
	game.call("_on_ssh_world", 0, 200, PackedStringArray(), JSON.stringify(remote).to_utf8_buffer(), ticket, "test-remote")
	advance(game, 0.01)
	advance(game, 1.0)
	game._process(0)
	check(game.mode == "remote" and game.remote_host == "test-remote", "SSH arrival preserves the requested alias despite a different reported hostname")
	check(not game.water.is_visible_in_tree() and not game.vault_root.visible, "remote world is isolated")
	game._refresh_remote()
	check(game.requests[-1].host == "test-remote" and game.requests[-1].ticket == -1, "periodic GET uses the SSH alias, not the reported hostname")
	var refreshed: Dictionary = remote.duplicate(true)
	refreshed.procs[0].cpu = 73
	game.call("_on_ssh_world", 0, 200, PackedStringArray(), JSON.stringify(refreshed).to_utf8_buffer(), -1, "other-alias")
	check(game.remote_procs[0].cpu != 73, "stale other-alias refresh is ignored even with the same reported hostname")
	game.call("_on_ssh_world", 0, 200, PackedStringArray(), JSON.stringify(refreshed).to_utf8_buffer(), -1)
	check(game.remote_procs[0].cpu != 73, "unbound periodic snapshots cannot update the remote world")
	game.call("_on_ssh_world", 0, 200, PackedStringArray(), JSON.stringify(refreshed).to_utf8_buffer(), -1, "test-remote")
	check(game.remote_procs[0].cpu == 73 and game.remote_host == "test-remote", "bound periodic snapshot updates data without changing the routing alias")
	game.selected_pid = 120
	game._act(9)
	check(game.sent_actions.size() == 1 and game.sent_actions[0].host == "test-remote" and game.sent_actions[0].pid == 120, "post-arrival kill payload retains the SSH alias")
	game._on_action(0, 200, [], JSON.stringify({"ok": true, "syscall": "FIXTURE remote kill"}).to_utf8_buffer())
	game._travel_to("refused-host")
	advance(game, 0.7)
	ticket = game.requests[-1].ticket
	game.call("_on_ssh_world", 0, 403, PackedStringArray(), JSON.stringify({"error": "fixture refused"}).to_utf8_buffer(), ticket)
	advance(game, 0.01)
	advance(game, 1.0)
	check(game.mode == "remote" and game.remote_host == "test-remote", "refused SSH restores original world and host")
	check(game.last_action.contains("fixture refused"), "refusal is reported, never a success animation")
	game._process(0)
	key(game, KEY_V)
	check(game.requests[-1].host == "test-remote" and game.requests[-1].path == "~", "remote vault listing uses the SSH alias")
	advance(game, 0.7)
	ticket = game.requests[-1].ticket
	game.call("_on_listing", 0, 200, PackedStringArray(), directory(), ticket)
	advance(game, 0.01)
	advance(game, 1.0)
	game._process(0)
	game.hovered_entry = {"entry": {"name": "folder", "dir": true}}
	game._vault_open_hovered()
	game.hovered_entry = {}
	check(game.requests[-1].host == "test-remote" and game.requests[-1].path == "/FIXTURE/folder", "nested directory listing retains the SSH alias")
	ticket = game.requests[-1].ticket
	game.call("_on_listing", 0, 200, PackedStringArray(), JSON.stringify({"path": "/FIXTURE/folder", "parent": "/FIXTURE", "entries": []}).to_utf8_buffer(), ticket)
	advance(game, 0.7)
	advance(game, 1.0)
	game._process(0)
	key(game, KEY_BACKSPACE)
	check(game.requests[-1].host == "test-remote" and game.requests[-1].path == "/FIXTURE", "parent directory listing retains the SSH alias")
	var cancelled_ticket: int = game.requests[-1].ticket
	game.call("_cancel_travel")
	advance(game, 1.0)
	game._process(0)
	var original_path := game.vault_path
	game._enter_vault("/NEW", "test-remote")
	game.call("_on_listing", 0, 200, PackedStringArray(), directory(), cancelled_ticket)
	advance(game, 0.7)
	check(game.vault_path == original_path and game.get("travel_state") == "waiting", "cancelled response cannot satisfy a newer request")
	advance(game, 21.0)
	advance(game, 1.0)
	check(game.mode == "vault" and game.vault_host == "test-remote", "timeout preserves the current remote vault")
	check(game.last_action.contains("timed out"), "timeout reports an uncompleted journey")
	game._process(0)
	game._vault_leave()
	advance(game, 0.7)
	advance(game, 1.0)
	game._process(0)
	check(game.mode == "remote" and game.remote_host == "test-remote", "remote vault exits back to its remote world")
	game._refresh_remote()
	check(game.requests[-1].host == "test-remote", "remote vault return refresh retains the SSH alias")
	game.call("_on_ssh_world", 0, 200, PackedStringArray(), JSON.stringify(remote).to_utf8_buffer(), -1, "test-remote")
	check(game.get("travel_state") == "idle", "periodic remote snapshots do not restart travel animation")
	game._return_home()
	advance(game, 0.7)
	advance(game, 1.0)
	game.held_action = true
	key(game, KEY_K)
	check(game.act_calls == 1, "held shot cannot carry through the return journey")
	game.held_action = false
	game._process(0)
	check(game.mode == "world" and not game.remote_root.visible and not game.vault_root.visible, "SSH return restores only the local world")
	for request in [game.world_http, game.action_http, game.list_http, game.ssh_http]:
		check(request.get_http_client_status() == HTTPClient.STATUS_DISCONNECTED, "tests never contact a server")
	game.queue_free()
	await process_frame
	print("TRAVEL_TEST_OK" if failures.is_empty() else "TRAVEL_TEST_FAILED")
	quit(0 if failures.is_empty() else 1)
