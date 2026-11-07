extends SceneTree
## Run the actual production probe against an ephemeral loopback listener.
## Only its hardcoded endpoint is rebound; no daemon startup/shutdown or API use.
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func check(condition: bool, description: String) -> void:
	if not condition:
		failures.append(description)
		print("DAEMON_PROBE_FAIL ", description)

func _run() -> void:
	var tcp := StreamPeerTCP.new()
	print("TCP_API disconnect_from_host=", tcp.has_method("disconnect_from_host"), " close=", tcp.has_method("close"))
	var server := TCPServer.new()
	var error := server.listen(0, "127.0.0.1")
	if error != OK:
		check(false, "could not create isolated TCP listener")
		quit(1)
		return
	var port := server.get_local_port()
	check(port > 0 and port != 8765, "test must not bind the live daemon port")
	var source := FileAccess.get_file_as_string("res://scripts/main.gd")
	var start := source.find("func _daemon_running()")
	var end := source.find("\nfunc _spawn_daemon()", start)
	check(start >= 0 and end > start, "production probe must be found")
	var script := GDScript.new()
	script.source_code = "extends RefCounted\n" + source.substr(start, end - start).replace("8765", str(port))
	error = script.reload()
	check(error == OK, "isolated production probe must compile")
	if error != OK:
		server.stop()
		quit(1)
		return
	var probe = script.new()
	check(probe.call("_daemon_running") == true, "connected probe returns true without a runtime error")
	if server.is_connection_available():
		var accepted := server.take_connection()
		accepted.disconnect_from_host()
	server.stop()
	check(probe.call("_daemon_running") == false, "closed endpoint returns false without a runtime error")
	print("DAEMON_PROBE_OK" if failures.is_empty() else "DAEMON_PROBE_FAILED")
	quit(0 if failures.is_empty() else 1)
