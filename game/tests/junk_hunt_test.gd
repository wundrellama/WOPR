extends SceneTree
## Synthetic wire data only. No daemon, HTTP, SSH, signals or filesystem actions.
const VisualTest = preload("res://tests/visual_smoke.gd")
const HOME_FOLDER := "/home/FIXTURE-USER/Documents"
var failures: Array[String] = []

class JunkWorld extends VisualTest.VisualWorld:
	var sent: Array[Dictionary] = []
	var listings: Array[Dictionary] = []
	var queue_error := OK
	func _request_action(payload: Dictionary) -> Error:
		sent.append(payload.duplicate(true))
		return queue_error
	func _request_listing(path: String, host: String, _ticket: int) -> Error:
		listings.append({"path": path, "host": host})
		return OK
	func _vault_erase() -> void:
		fixture_erase()

func _initialize() -> void: call_deferred("_run")

func check(condition: bool, description: String) -> void:
	if not condition:
		failures.append(description)
		print("JUNK_FAIL ", description)

static func nest(id: String = "shared", directory: bool = false) -> Dictionary:
	return {"id": id, "path": HOME_FOLDER + "/" + ("nest" if directory else "junk.bin"),
		"parent": HOME_FOLDER, "name": "nest" if directory else "junk.bin", "dir": directory,
		"size": 4096, "pid": 120, "state": "active", "respawns": 0}

func _run() -> void:
	var game := JunkWorld.new()
	root.add_child(game)
	game._start_game()
	game.poll_timer.stop()
	game.set_process(false)
	var data := VisualTest._fixture()
	data.hw.mounts.append({"path": "/home", "percent": 20, "total": 1000000, "fstype": "fixture"})
	data.hw.mounts.append({"path": "/home/FIXTURE-USER", "percent": 30, "total": 1000000, "fstype": "fixture"})
	data.hw.mounts.append({"path": "/home/FIXTURE-USER/Doc", "percent": 30, "total": 1000000, "fstype": "fixture"})
	data.junk = [nest(), nest("folder", true)]
	game._on_world(0, 200, [], JSON.stringify(data).to_utf8_buffer())
	_malformed_acknowledgements(game, data)
	data.junk = [nest(), nest("folder", true)]
	game._on_world(0, 200, [], JSON.stringify(data).to_utf8_buffer())
	var bodies: Variant = game.get("local_junk_bodies")
	check(bodies is Dictionary, "local JSON junk creates persistent artifact bodies")
	if bodies is Dictionary:
		check(bodies.size() == 2, "file and folder have separate IDs even with same writer PID")
		var original: Node3D = bodies.get("shared")
		check(original != null, "opaque ID, not PID, indexes the artifact")
		if original != null:
			var entrance: Node3D = null
			for candidate in game.pickables:
				var info: Dictionary = game.pickables[candidate]
				if info.get("kind") == "mount" and info.mnt.path == "/home/FIXTURE-USER": entrance = candidate
			check(entrance != null and original.position.distance_to(entrance.position) < 180, "beacon anchors to longest boundary-matching mount entrance, never CPU plains")
			check(not original.has_node("JunkLabel") and original.get_child(0).mesh is TorusMesh, "outdoor destination is a ring beacon, never file/folder geometry")
			var label: Label3D = original.get_node_or_null("VaultBeaconLabel")
			check(label != null and label.text.contains("VAULT") and label.text.contains(HOME_FOLDER), "outdoor label names truthful exposed-parent VAULT destination")
			check(label != null and label.pixel_size * label.font_size >= 8, "label readable at gameplay distance")
			var next_label: Label3D = bodies.folder.get_node_or_null("VaultBeaconLabel")
			check(label != null and next_label != null and absf(label.global_position.y - next_label.global_position.y) >= 35, "beacons for the same vault stagger their destination labels")
		data.junk[0].pid = 0
		data.junk[0].state = "respawning"
		data.enemies = []
		game._on_world(0, 200, [], JSON.stringify(data).to_utf8_buffer())
		check(game.get("local_junk_bodies").get("shared") == original, "writer death does not remove or recreate artifact identity")
		game.remote_host = "requested-alias"
		game._render_remote(JSON.parse_string(JSON.stringify({"host": "reported-host", "procs": [], "junk": [nest()], "enemies": []})))
		game._activate_world("remote")
		game._process(0)
		var remote: Variant = game.get("remote_junk_bodies")
		check(remote is Dictionary and remote.has("shared"), "remote JSON junk creates its own ID namespace")
		if remote is Dictionary and remote.has("shared"):
			check(remote.shared != original and remote.shared.get_parent() == game.remote_root, "colliding host IDs never share bodies")
			check(remote.shared.position.x > 700 and remote.shared.has_node("VaultBeaconLabel"), "remote artifact has dedicated east-side FILE VAULT gateway")
			var remote_label: Label3D = remote.shared.get_node_or_null("VaultBeaconLabel")
			check(remote_label != null and remote_label.text.contains("requested-alias"), "remote gateway names requested alias, never reported hostname")
		check(game.crosshair.get("junk_targets") is Dictionary, "junk provides presentation-only direction/range markers")
		game._activate_world("vault")
		game._process(0)
		check(game.crosshair.get("junk_targets") == {}, "outdoor junk locators never leak into vault")
		data.junk = [nest("folder", true)]
		game._on_world(0, 200, [], JSON.stringify(data).to_utf8_buffer())
		data.junk.append(nest("replacement"))
		game._on_world(0, 200, [], JSON.stringify(data).to_utf8_buffer())
		check(not game.get("local_junk_bodies").folder.position.is_equal_approx(game.get("local_junk_bodies").replacement.position), "new nest cannot occupy a surviving nest's slot after another ID disappears")
		data.junk = []
		game._on_world(0, 200, [], JSON.stringify(data).to_utf8_buffer())
		check(game.get("local_junk_bodies").is_empty(), "authoritative record deletion removes artifact")
		check(game.get("remote_junk_bodies").has("shared"), "local cleanup cannot delete colliding remote artifact")
	await _navigation_and_erase(game, data)
	await _link_folder_style(game, data)
	_malformed_acknowledgements(game, data)
	for request in [game.world_http, game.action_http, game.list_http, game.ssh_http]:
		check(request.get_http_client_status() == HTTPClient.STATUS_DISCONNECTED, "test remains disconnected")
	game.queue_free()
	await process_frame
	print("JUNK_HUNT_OK" if failures.is_empty() else "JUNK_HUNT_FAILED")
	quit(0 if failures.is_empty() else 1)

func _navigation_and_erase(game: JunkWorld, data: Dictionary) -> void:
	data.junk = [nest()]
	game._on_world(0, 200, [], JSON.stringify(data).to_utf8_buffer())
	game._activate_world("world")
	var body: StaticBody3D = game.get("local_junk_bodies").shared
	game.camera.position = body.position + Vector3(0, 0, 100)
	game.camera.look_at(body.global_position)
	await physics_frame
	await physics_frame
	game._update_hover()
	check(game.hover_label.text.contains("VAULT") and game.hover_label.text.contains("Enter"), "aimed outdoor beacon advertises parent-vault navigation")
	var enter := InputEventKey.new()
	enter.keycode = KEY_ENTER
	enter.pressed = true
	game.fixture_input(enter)
	check(game.listings == [{"path": HOME_FOLDER, "host": ""}], "Enter opens exposed local home parent, not backing payload")
	if game.listings.is_empty():
		return
	game._on_listing(0, 200, [], JSON.stringify({"path": HOME_FOLDER, "parent": "/home/FIXTURE-USER", "entries": [
		{"name": "junk.bin", "dir": false, "size": 4096, "mtime": 0},
		{"name": "ordinary", "dir": false, "size": 0, "mtime": 0}]}).to_utf8_buffer(), game.travel_serial)
	game._advance_travel(0.8)
	game._advance_travel(0.8)
	game.actions_need_release = false
	var marked: StaticBody3D = null
	for candidate: StaticBody3D in game.vault_bodies:
		if game.vault_bodies[candidate].name == "junk.bin": marked = candidate
	check(marked != null and marked.has_node("JunkLabel"), "exact absolute path marks matching vault entry")
	if marked == null: return
	game.camera.position = marked.position + Vector3(0, 0, 80)
	game.camera.look_at(marked.global_position)
	await physics_frame
	await physics_frame
	game._vault_hover_text()
	check(game.hover_label.text.contains("respawn"), "marked vault explains erase disables respawn")
	game._process(0)
	var locators: Dictionary = game.crosshair.get("junk_targets")
	check(locators.size() == 1 and locators.values()[0] == marked, "vault locator tracks marked entry, not outdoor object")
	game.oracle_armed = true
	var held := InputEventKey.new()
	held.keycode = KEY_X
	held.pressed = true
	Input.parse_input_event(held)
	Input.flush_buffered_events()
	game._process(0)
	check(game.sent.is_empty(), "hold X does not erase on initial keypress")
	while Time.get_ticks_msec() - game.erase_hold_start < game.ERASE_HOLD_MS + 10:
		await process_frame
	game._process(0)
	held = held.duplicate()
	held.pressed = false
	Input.parse_input_event(held)
	Input.flush_buffered_events()
	check(game.sent == [{"verb": "junk_rm", "id": "shared", "confirm": true}], "ROOT ARMED junk erasure uses ID-confirmed request, never Oracle/path rm")
	check(game.get("local_junk_bodies").has("shared") and game.vault_bodies.has(marked), "queued erase is not success; keep geometry until real ack")
	game.fixture_erase()
	check(game.sent.size() == 1, "pending erase cannot duplicate while X is held")
	check(not game._begin_travel("ssh", "other-alias", "ssh"), "pending junk erase blocks namespace-changing travel")
	game._on_action(0, 403, [], JSON.stringify({"ok": false, "error": "fixture refused"}).to_utf8_buffer())
	check(game.get("local_junk_bodies").has("shared"), "failed erase preserves artifact")
	game.actions_need_release = false
	game.sim_playing = true
	game.fixture_erase()
	check(game.sent.size() == 1, "SIM cannot send junk erase even ROOT ARMED")
	game.sim_playing = false
	game.actions_need_release = false
	game.fixture_erase()
	game._on_action(0, 200, [], JSON.stringify({"ok": true}).to_utf8_buffer())
	check(game.get("local_junk_bodies").has("shared") and game.last_action.contains("UNCONFIRMED"), "missing acknowledgement ID never confirms/removes junk")
	game.actions_need_release = false
	game.fixture_erase()
	game._on_action(0, 200, [], JSON.stringify({"ok": true, "id": "wrong-id"}).to_utf8_buffer())
	check(game.get("local_junk_bodies").has("shared") and game.last_action.contains("UNCONFIRMED"), "wrong acknowledgement ID never confirms/removes junk")
	game.actions_need_release = false
	game.fixture_erase()
	game._on_action(0, 200, [], JSON.stringify({"ok": true, "id": "shared", "result": "fixture erased"}).to_utf8_buffer())
	check(not game.get("local_junk_bodies").has("shared") and not game.vault_bodies.has(marked), "confirmed erase removes only acknowledged local artifact and vault entry")
	check(game.get("remote_junk_bodies").has("shared"), "local ack preserves colliding remote ID")
	game.remote_host = "requested-alias"
	game._activate_world("remote")
	game.actions_need_release = false
	var remote: StaticBody3D = game.get("remote_junk_bodies").shared
	game.camera.position = remote.position + Vector3(0, 0, 100)
	game.camera.look_at(remote.global_position)
	await physics_frame
	await physics_frame
	game._update_remote_hover()
	game.fixture_input(enter)
	check(game.listings.back() == {"path": HOME_FOLDER, "host": "requested-alias"}, "remote Enter routes exposed home parent through requested alias, not reported hostname")
	game._on_listing(0, 200, [], JSON.stringify({"path": HOME_FOLDER, "parent": "/home/FIXTURE-USER", "entries": [
		{"name": "junk.bin", "dir": false, "size": 4096, "mtime": 0}]}).to_utf8_buffer(), game.travel_serial)
	game._advance_travel(0.8)
	game._advance_travel(0.8)
	game.actions_need_release = false
	marked = game.vault_bodies.keys()[0]
	game.camera.position = marked.position + Vector3(0, 0, 80)
	game.camera.look_at(marked.global_position)
	await physics_frame
	await physics_frame
	game.fixture_erase()
	check(game.sent.back() == {"verb": "junk_rm", "id": "shared", "confirm": true, "host": "requested-alias"}, "remote erasure retains requested alias and stable ID")
	game._on_action(0, 200, [], "not-json".to_utf8_buffer())
	check(game.get("remote_junk_bodies").has("shared"), "malformed reply never removes remote artifact")
	game.actions_need_release = false
	game.queue_error = ERR_BUSY
	game.fixture_erase()
	check(game.get("pending_junk") == {} and game.get("remote_junk_bodies").has("shared"), "queue failure preserves artifact and clears pending request")
	game.queue_error = OK
	game.actions_need_release = false
	game.fixture_erase()
	game._on_action(0, 200, [], JSON.stringify({"ok": true, "id": "shared"}).to_utf8_buffer())
	check(game.get("remote_junk_bodies").is_empty(), "confirmed remote erasure removes remote artifact")
	game._render_remote({"host": "reported-host", "procs": [], "junk": [nest()], "enemies": []})
	game._render_vault([{"name": "junk.bin", "dir": false, "size": 4096, "mtime": 0}], false)
	var cleanup := JSON.stringify({"host": "reported-host", "procs": [], "junk": [], "enemies": []}).to_utf8_buffer()
	game._on_ssh_world(0, 200, [], cleanup, -1, "other-alias")
	check(game.get("remote_junk_bodies").has("shared"), "same reported hostname cannot cross requested alias during vault refresh")
	game._on_ssh_world(0, 200, [], cleanup, -1, "requested-alias")
	check(game.get("remote_junk_bodies").is_empty() and game.vault_bodies.is_empty(), "remote cleanup refresh removes marked vault entries without leaking outdoor geometry")
	game._render_remote({"host": "reported-host", "procs": [], "junk": [nest()], "enemies": []})
	game.vault_path = "/OTHER-FIXTURE"
	game._render_vault([{"name": "junk.bin", "dir": false, "size": 4096, "mtime": 0}], false)
	check(game._junk_targets().is_empty(), "same basename in a different absolute parent is not junk")
	game.vault_path = HOME_FOLDER
	game.vault_host = "other-alias"
	game._render_vault([{"name": "junk.bin", "dir": false, "size": 4096, "mtime": 0}], false)
	check(game._junk_targets().is_empty(), "same absolute path in a different alias cannot inherit junk marking")

func _malformed_acknowledgements(game: JunkWorld, data: Dictionary) -> void:
	game._activate_world("world")
	data.junk = [nest()]
	game._on_world(0, 200, [], JSON.stringify(data).to_utf8_buffer())
	var replies := [{"ok": "false"}, {"ok": "true"}, {"ok": 0}, {"ok": 1}, {"ok": null}, {}]
	for reply: Dictionary in replies:
		reply.id = "shared"
		for junk_action in [true, false]:
			game.pending_junk = {"id": "shared", "host": ""} if junk_action else {}
			game.pending_shot = {} if junk_action else {"pid": 120, "host": "LOCAL", "verb": "SMITE"}
			game._on_action(0, 200, [], JSON.stringify(reply).to_utf8_buffer())
			var context := "malformed ok=%s / junk=%s" % [JSON.stringify(reply.get("ok")), junk_action]
			check(game.pending_junk.is_empty() and game.pending_shot.is_empty(), context + " clears pending state")
			check(game.local_junk.has("shared"), context + " preserves artifact")
			check(game.last_action.contains("UNCONFIRMED") and game.last_action.contains("invalid"), context + " reports invalid/unconfirmed")
			check(game._begin_travel("vault", HOME_FOLDER, "vault"), context + " unblocks travel")
			if game.travel_state != "idle":
				game._cancel_travel()
				game._advance_travel(1.0)
			game.actions_need_release = false
			game.pending_junk = {}
			game.pending_shot = {}

func _link_folder_style(game: JunkWorld, data: Dictionary) -> void:
	game.vault_host = ""
	game.vault_path = HOME_FOLDER
	game._activate_world("vault")
	var folder := nest("0123456789abcdef0123456789abcdef", true)
	folder.name = "wopr-0123456789abcdef0123456789abcdef-nest.link"
	folder.path = HOME_FOLDER + "/" + str(folder.name)
	data.junk = [folder]
	game._on_world(0, 200, [], JSON.stringify(data).to_utf8_buffer())
	# nofollow listing reports symlinks as files, even for backing folders.
	game._render_vault([{"name": folder.name, "dir": false, "size": 4096, "mtime": 0},
		{"name": "ordinary-journal.txt", "dir": false, "size": 4096, "mtime": 0}], false)
	var marked: StaticBody3D
	for body: StaticBody3D in game.vault_bodies:
		if game.vault_bodies[body].name == folder.name:
			marked = body
			var label: Label3D = body.get_node("JunkLabel")
			check(label.text.contains("JUNK LINK") and label.text.contains("FOLDER"), "directory-backed link clearly labels JUNK LINK / NEST FOLDER despite listing dir=false")
			check(label.text.contains("…") and not label.text.contains(str(folder.name)), "realistic long link name is ellipsized in world-space labels")
			var shape: BoxShape3D = body.get_child(1).shape
			check(shape.size.x > shape.size.y, "folder-link geometry follows authoritative junk type, not nofollow listing")
		else:
			check(not body.has_meta("junk") and not body.has_node("JunkLabel"), "ordinary neighboring real file stays unmarked and dangerous")
	game.camera.position = marked.position + Vector3(0, 0, 80)
	game.camera.look_at(marked.global_position)
	await physics_frame
	await physics_frame
	game._vault_hover_text()
	check(game.hover_label.text.contains("JUNK LINK") and game.hover_label.text.contains("FOLDER"), "folder link hover explains backing type")
	check(game.hover_label.text.contains(str(folder.name)), "hover preserves full authoritative exposed name")
	check(game.crosshair.has_method("junk_display_name"), "markers use bounded display names without changing wire values")
	game.oracle_armed = true
	game.actions_need_release = false
	game.fixture_erase()
	check(game.sent.back() == {"verb": "junk_rm", "id": folder.id, "confirm": true}, "ROOT ARMED folder symlink erase never follows symlink via generic rm/Oracle")
	game._on_action(0, 200, [], JSON.stringify({"ok": true, "id": folder.id}).to_utf8_buffer())
