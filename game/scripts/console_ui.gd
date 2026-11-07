extends Control
## Presentation only. No inputs, telemetry requests, or gameplay side effects.

const NAVY := Color("070f18")
const CYAN := Color("72d9d4")
const IVORY := Color("e1e8e5")
const AMBER := Color("e6b673")
const DANGER := Color("f28b80")
const MUTED := Color("8aabae")
const RULE := Color("29474e")

var _font: SystemFont
var _built := false
var _header: Control
var _telemetry: Control
var _location: Control
var _target: Control
var _legend: Control
var _commands: Control
var _feedback: Control
var _labels: Dictionary = {}
var _metrics: Dictionary = {}
var _context: Dictionary = {}


class ConsolePlate extends Control:
	var accent := Color("72d9d4")
	var solid := false

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		resized.connect(queue_redraw)

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.025, 0.055, 0.082, 0.98 if solid else 0.91))
		draw_line(Vector2.ZERO, Vector2(size.x, 0), Color("29474e"), 1.0)
		draw_line(Vector2(0, size.y), size, Color("29474e"), 1.0)
		draw_line(Vector2.ZERO, Vector2(38, 0), accent, 2.0)
		draw_line(Vector2(size.x, size.y - 9), size, accent, 1.0)


class RadarGraphic extends Control:
	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		resized.connect(queue_redraw)

	func _draw() -> void:
		var center := size * Vector2(0.52, 0.46)
		var radius := minf(size.x * 0.42, size.y * 0.38)
		var line_color := Color(0.45, 0.85, 0.83, 0.19)
		for i in range(1, 5):
			draw_arc(center, radius * float(i) / 4.0, 0, TAU, 128, line_color, 1.0, true)
		for i in range(48):
			var axis := Vector2.from_angle(float(i) * TAU / 48.0)
			var inner := radius * (0.94 if i % 4 == 0 else 0.98)
			draw_line(center + axis * inner, center + axis * radius * 1.025, line_color, 1.0, true)
		draw_line(center - Vector2(radius * 1.15, 0), center + Vector2(radius * 1.15, 0), line_color)
		draw_line(center - Vector2(0, radius * 1.15), center + Vector2(0, radius * 1.15), line_color)
		for i in range(14):
			var angle := float(i) * 2.39996
			var point := center + Vector2.from_angle(angle) * radius * (0.22 + float(i % 5) * 0.14)
			var elbow := point + Vector2(16, -16)
			var end := elbow + Vector2(20 + i % 4 * 9, 0)
			draw_polyline(PackedVector2Array([point, elbow, end]), line_color, 1.0, true)
			draw_rect(Rect2(point - Vector2(2, 2), Vector2(4, 4)), Color("72d9d4") if i % 4 else Color("e6b673"))
		var sweep := center + Vector2.from_angle(-0.73) * radius
		draw_line(center, sweep, Color(0.45, 0.85, 0.83, 0.7), 1.0, true)
		draw_circle(center, 4, Color("72d9d4"))
		# Circuit traces continue below the radar, not a textured illustration.
		for i in range(7):
			var start := Vector2(size.x * 0.18 + i * 22, center.y + radius * 1.2)
			var bend := start + Vector2(0, 20 + (i % 3) * 16)
			var end := bend + Vector2(38, 38)
			draw_polyline(PackedVector2Array([start, bend, end, end + Vector2(40, 0)]), line_color, 1.0, true)


class OpeningScreen extends Control:
	var font: SystemFont
	var screen_title := ""
	var screen_sub := ""
	var screen_prompt := ""
	var nodes: Dictionary = {}
	var radar: Control
	var prompt_plate: Control

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		resized.connect(_layout)
		_layout()
		var pulse := create_tween().set_loops()
		pulse.tween_property(nodes["prompt"], "modulate:a", 0.42, 1.1)
		pulse.tween_property(nodes["prompt"], "modulate:a", 1.0, 1.1)

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color("070f18"))
		for x in range(0, int(size.x), 64):
			draw_line(Vector2(x, 0), Vector2(x, size.y), Color(0.2, 0.4, 0.45, 0.045))
		var margin := size.x * 0.05
		draw_line(Vector2(margin, 35), Vector2(size.x - margin, 35), Color("29474e"))
		draw_line(Vector2(margin, size.y - 64), Vector2(size.x - margin, size.y - 64), Color("29474e"))
		draw_line(Vector2(size.x * 0.64, 90), Vector2(size.x * 0.64, size.y - 100), Color(0.16, 0.28, 0.31, 0.5))

	func _layout() -> void:
		if nodes.is_empty():
			return
		var compact := size.x < 1300
		var margin := size.x * 0.05
		var left_width := size.x * 0.55
		var wopr := screen_title.replace(" ", "").to_upper() == "WOPR"
		_place(nodes["overline"], Rect2(margin, size.y * 0.085, left_width, 25))
		var title_label: Label = nodes["title"]
		title_label.add_theme_font_size_override("font_size", (108 if compact else 144) if wopr else (34 if compact else 46))
		_place(title_label, Rect2(margin - 6, size.y * 0.12, left_width, size.y * 0.23))
		_place(nodes["slogan"], Rect2(margin, size.y * 0.345, left_width, 35))
		_place(nodes["warning"], Rect2(margin, size.y * 0.425, left_width, 44))
		_place(nodes["sub"], Rect2(margin, size.y * 0.49, left_width, size.y * 0.27))
		_place(prompt_plate, Rect2(margin, size.y * 0.81, left_width, 48))
		_place(nodes["prompt"], Rect2(16, 0, left_width - 32, 48))
		_place(nodes["footer"], Rect2(margin, size.y - 51, size.x - margin * 2, 30))
		_place(radar, Rect2(size.x * 0.66, size.y * 0.14, size.x * 0.31, size.y * 0.65))
		_place(nodes["radar_title"], Rect2(size.x * 0.69, size.y * 0.12, size.x * 0.27, 30))
		_place(nodes["radar_footer"], Rect2(size.x * 0.69, size.y * 0.79, size.x * 0.27, 40))
		queue_redraw()

	func _place(node: Control, rect: Rect2) -> void:
		node.position = rect.position
		node.size = rect.size


func _get_font() -> SystemFont:
	if _font == null:
		_font = SystemFont.new()
		_font.font_names = PackedStringArray(["JetBrains Mono", "DejaVu Sans Mono", "Liberation Mono", "monospace"])
		_font.allow_system_fallback = true
	return _font


func _label(parent: Control, text: String, font_size: int = 13, color: Color = IVORY) -> Label:
	var label := Label.new()
	parent.add_child(label)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.text = text
	label.add_theme_font_override("font", _get_font())
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.clip_text = true
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return label


func _plate(parent: Control, accent: Color = CYAN) -> ConsolePlate:
	var plate := ConsolePlate.new()
	plate.accent = accent
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(plate)
	return plate


func _place(node: Control, x: float, y: float, width: float, height: float) -> void:
	node.position = Vector2(x, y)
	node.size = Vector2(maxf(width, 0), maxf(height, 0))


func build_hud() -> void:
	if _built:
		return
	_built = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_header = _plate(self)
	_labels.brand = _label(_header, "WOPR", 32, CYAN)
	_labels.mission = _label(_header, "STRATEGIC SYSTEMS  /  MISSION 01", 13, MUTED)
	_labels.host = _label(_header, "AWAITING TELEMETRY", 13, IVORY)
	_labels.safety = _label(_header, "LIVE / REAL SYSCALLS", 20, DANGER)
	_labels.safety.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_labels.safety_detail = _label(_header, "THIS MACHINE IS NOT A SANDBOX", 13, DANGER)
	_labels.safety_detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_telemetry = _plate(self)
	for key in ["CPU", "MEM", "SWAP", "GPU", "PROCS", "BRIDGES", "CITIES", "MOUNTS"]:
		var caption := _label(_telemetry, key, 13, MUTED)
		var value := _label(_telemetry, "—", 23, CYAN if key in ["CPU", "MEM", "SWAP", "GPU"] else IVORY)
		var track := ColorRect.new()
		track.color = RULE
		track.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_telemetry.add_child(track)
		var bar := ColorRect.new()
		bar.color = CYAN
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_telemetry.add_child(bar)
		_metrics[key] = {"caption": caption, "value": value, "track": track, "bar": bar, "ratio": 0.0}
	_location = _plate(self, AMBER)
	_labels.location = _label(_location, "LOCAL WORLD  /  NO DATA", 13, AMBER)
	_labels.warning = _label(_location, "", 13, DANGER)
	_target = _plate(self, AMBER)
	_labels.target_heading = _label(_target, "TARGET LOCK / NO SELECTION", 13, AMBER)
	_labels.target_name = _label(_target, "—", 24, IVORY)
	for key in ["identity", "resources", "relations", "cmdline", "target_action"]:
		_labels[key] = _label(_target, "", 13, MUTED if key == "cmdline" else IVORY)
	_legend = _plate(self)
	_labels.legend_heading = _label(_legend, "DISTRICT INDEX / MACHINE GEOGRAPHY", 13, CYAN)
	_labels.legend_a = _label(_legend, "00 KERNEL RING   01 CPU PLAINS   02 NETWORK HARBOR", 13, IVORY)
	_labels.legend_b = _label(_legend, "03 FILE VAULTS   04 GPU FORGE    05 MEMORY TIDE", 13, IVORY)
	_labels.hunt = _label(_legend, "HUNT OFF", 13, AMBER)
	_commands = _plate(self, DANGER)
	for key in ["movement", "navigation", "verbs", "modes", "action", "danger"]:
		_labels[key] = _label(_commands, "", 13, DANGER if key in ["verbs", "danger"] else IVORY)
	_labels.movement.text = "WASD move  Q/E descend/ascend  SHIFT sprint  MOUSE look  LMB lock/capture  RMB release"
	_labels.modes.text = "Y arm Oracle (sudo / 120s)   M safe replay / live   H hunt: off > local > +remote > off"
	_feedback = _plate(self, AMBER)
	_labels.feedback_caption = _label(_feedback, "SIGNAL / AWAITING RESULT", 13, AMBER)
	_labels.feedback_message = _label(_feedback, "", 15, IVORY)
	_feedback.visible = false
	resized.connect(_layout_hud)
	update_world({}, {})


func _layout_hud() -> void:
	if not _built:
		return
	var margin := 24.0 if size.x >= 1300 else 18.0
	var width := size.x - margin * 2.0
	_place(_header, margin, 20, width, 69)
	_place(_labels.brand, 15, 4, 112, 42)
	_place(_labels.mission, 143, 8, width - 625, 22)
	_place(_labels.host, 143, 32, width - 625, 24)
	_place(_labels.safety, width - 465, 8, 449, 29)
	_place(_labels.safety_detail, width - 465, 36, 449, 23)
	_place(_telemetry, margin, 101, width, 69)
	var cell := width / 8.0
	var index := 0
	for key in _metrics:
		var metric: Dictionary = _metrics[key]
		_place(metric.caption, index * cell + 15, 5, cell - 25, 20)
		_place(metric.value, index * cell + 15, 24, cell - 25, 31)
		_place(metric.track, index * cell + 15, 61, cell - 30, 2)
		_place(metric.bar, index * cell + 15, 61, (cell - 30) * float(metric.ratio), 2)
		index += 1
	_place(_location, margin, 180, width, 49)
	_place(_labels.location, 15, 3, width - 30, 22)
	_place(_labels.warning, 15, 24, width - 30, 21)
	var target_width := 350.0 if size.x >= 1300 else 304.0
	_place(_target, size.x - margin - target_width, 245, target_width, 220)
	_place(_labels.target_heading, 16, 8, target_width - 32, 24)
	_place(_labels.target_name, 16, 36, target_width - 32, 36)
	var row := 0
	for key in ["identity", "resources", "relations", "cmdline", "target_action"]:
		_place(_labels[key], 16, 79 + row * 25, target_width - 32, 23)
		row += 1
	var feedback_width := minf(760.0, width)
	_place(_feedback, (size.x - feedback_width) * 0.5, size.y * 0.5 + 55.0, feedback_width, 64)
	_place(_labels.feedback_caption, 16, 4, feedback_width - 32, 23)
	_place(_labels.feedback_message, 16, 29, feedback_width - 32, 27)
	_place(_commands, margin, size.y - 143, width, 125)
	row = 0
	for key in ["movement", "navigation", "verbs", "modes", "action", "danger"]:
		_place(_labels[key], 15, 3 + row * 20, width - 30, 20)
		row += 1
	_place(_legend, margin, size.y - 263, minf(610, width - target_width - 30), 105)
	row = 0
	for key in ["legend_heading", "legend_a", "legend_b", "hunt"]:
		_place(_labels[key], 15, 5 + row * 24, _legend.size.x - 30, 23)
		row += 1


func update_world(data: Dictionary, context: Dictionary) -> void:
	if not _built:
		build_hud()
	_context = context
	var mode := str(context.get("mode", "world"))
	var remote := str(context.get("remote_host", ""))
	var sim := bool(context.get("sim_playing", false))
	var armed := bool(context.get("oracle_armed", false))
	var safety_color := AMBER if sim else DANGER
	_labels.safety.text = "SIM / ALL VERBS FROZEN" if sim else ("ROOT ARMED / REAL SYSCALLS" if armed else "LIVE / REAL SYSCALLS")
	_labels.safety.add_theme_color_override("font_color", safety_color)
	_labels.safety_detail.add_theme_color_override("font_color", safety_color)
	var sim_info: Dictionary = context.get("sim_info", {})
	_labels.safety_detail.text = "REPLAY %s / %d OF %d" % [str(sim_info.get("name", "")), int(sim_info.get("idx", 0)), int(sim_info.get("length", 0))] if sim else ("K + HOLD X: ROOT ON LOCAL MACHINE" if armed else "THIS MACHINE IS NOT A SANDBOX")
	var host: Dictionary = data.get("host", {})
	_labels.host.text = "%s / %s / TICK %s" % [str(host.get("hostname", "OFFLINE")), str(host.get("os", "AWAITING TELEMETRY")), str(int(data.get("tick", 0))) if data.has("tick") else "—"]
	var cpu: Dictionary = data.get("cpu", {})
	var mem: Dictionary = data.get("mem", {})
	var hw: Dictionary = data.get("hw", {})
	var net: Dictionary = data.get("net", {})
	var swap_total := float(mem.get("swap_total", 0))
	var swap_percent := float(mem.get("swap_used", 0)) / maxf(swap_total, 1.0) * 100.0
	_set_metric("CPU", cpu.get("total", null), true)
	_set_metric("MEM", mem.get("percent", null), true)
	_set_metric("SWAP", swap_percent if not mem.is_empty() else null, true)
	_set_metric("GPU", hw.get("gpu_busy", null), true)
	_set_metric("PROCS", data.get("procs", []).size() if not data.is_empty() else null)
	_set_metric("BRIDGES", net.get("conns", []).size() if not net.is_empty() else null)
	_set_metric("CITIES", net.get("remote_hosts", []).size() if not net.is_empty() else null)
	_set_metric("MOUNTS", hw.get("mounts", []).size() if not hw.is_empty() else null)
	_labels.location.text = "LOCAL WORLD / %s" % str(host.get("hostname", "AWAITING TELEMETRY"))
	_labels.warning.text = "REAL PROCESS SIGNALS. K TERMINATES THE LOCKED TARGET."
	_labels.navigation.text = "ENTER enter vault / SSH gate   BACKSPACE parent (vault)   V remote files   ESC leave / exit"
	_labels.verbs.text = "F freeze [SIGSTOP]   C resume [SIGCONT]   K kill [SIGKILL]   HOLD X 1s erase [vault / real rm]"
	if mode == "remote":
		_labels.location.text = "REMOTE WORLD / %s / SSH" % remote
		_labels.warning.text = "F / C / K ACT ON THIS REMOTE MACHINE. ESC RETURNS HOME. LOCAL TELEMETRY ABOVE."
	elif mode == "vault":
		_labels.location.text = "FILE VAULT / %s%s" % [(remote + ":") if remote != "" else "", str(context.get("vault_path", ""))]
		_labels.warning.text = "HOLD X 1s: REAL FILE DELETION%s. ENTER DESCENDS / BACKSPACE PARENT / ESC LEAVE." % (" VIA SSH" if remote != "" else "")
	if sim:
		_labels.warning.text = "SIMULATION / ALL ACTION VERBS BLOCKED SERVER-SIDE. M RETURNS TO THE LIVE MACHINE."
	_labels.danger.text = "SAFE REPLAY / ALL VERBS FROZEN — M RETURNS TO LIVE." if sim else "DANGER / REAL SYSCALLS CAN DESTROY THIS MACHINE, INCLUDING ITS SNAPSHOTS."
	_labels.danger.add_theme_color_override("font_color", safety_color)
	_labels.action.text = "LAST / " + str(context.get("last_action", "NO ACTION ISSUED"))
	var level := clampi(int(data.get("enemies_level", 0)), 0, 2)
	_labels.hunt.text = "HUNT %s / %d ROGUES / %d KILLED / %d FREED" % [["OFF", "LOCAL", "LOCAL+REMOTE"][level], data.get("enemies", []).size(), int(context.get("rogue_kills", 0)), int(context.get("rogue_frees", 0))]
	# The caller supplies the selected process from the active machine. Never
	# resolve a remote PID against the local world: PID namespaces can collide.
	var selected: Dictionary = context.get("selected", {})
	_target.visible = not selected.is_empty() and mode != "vault"
	if not selected.is_empty():
		_labels.target_heading.text = "TARGET LOCK / " + (remote if mode == "remote" else "LOCAL")
		_labels.target_name.text = str(selected.get("name", "UNKNOWN"))
		_labels.identity.text = "PID %s / %s / %s" % [str(int(selected.get("pid", 0))), str(selected.get("user", "?")), str(selected.get("state", "?"))]
		_labels.resources.text = "CPU %.1f%% / RSS %.0f MiB" % [float(selected.get("cpu", 0)), float(selected.get("mem_rss", 0)) / 1048576.0]
		_labels.relations.text = "%s THREADS / %s CHILDREN / %ds" % [str(int(selected.get("threads", 0))), str(int(selected.get("children", 0))), int(selected.get("age", 0))]
		var command: Variant = selected.get("cmdline", "")
		_labels.cmdline.text = " ".join(PackedStringArray(command)) if command is Array else str(command).replace("\n", " ")
		_labels.target_action.text = "VERBS FROZEN IN SIM" if sim else ("K: ROOT SIGKILL / LOCAL" if armed and mode != "remote" else "F STOP / C CONTINUE / K KILL")
		_labels.target_action.add_theme_color_override("font_color", AMBER if sim else DANGER)
	_labels.legend_heading.text = "DISTRICT INDEX / MACHINE GEOGRAPHY"
	_labels.legend_a.text = "00 KERNEL RING   01 CPU PLAINS   02 NETWORK HARBOR"
	_labels.legend_b.text = "03 FILE VAULTS   04 GPU FORGE    05 MEMORY TIDE"
	if mode == "vault":
		_labels.legend_heading.text = "DIRECTORY INDEX / FILE VAULT"
		_labels.legend_a.text = "%d ENTRIES / %s" % [int(context.get("vault_entries", 0)), ("SSH: " + remote) if remote != "" else "LOCAL FILESYSTEM"]
		_labels.legend_b.text = "GOLD: DIRECTORY / AMBER: FILE / HEIGHT: SIZE"
		_labels.hunt.text = "PARENT / " + str(context.get("vault_parent", ""))
	elif mode == "remote":
		_labels.legend_heading.text = "SSH WORLD / " + remote
		_labels.legend_a.text = "%d REMOTE PROCESSES / ISOLATED PID NAMESPACE" % int(context.get("remote_procs", 0))
		_labels.legend_b.text = "V: REMOTE FILES / ESC: RETURN HOME"
	var feedback: Dictionary = context.get("action_result", {})
	_feedback.visible = not feedback.is_empty()
	if not feedback.is_empty():
		var state := str(feedback.get("state", "pending"))
		var color := Color("83dca1") if state == "ok" else DANGER if state == "error" else AMBER
		_feedback.accent = color
		_feedback.queue_redraw()
		_labels.feedback_caption.text = "SIGNAL / " + ("CONFIRMED" if state == "ok" else "REFUSED / UNCONFIRMED" if state == "error" else "AWAITING DAEMON ACKNOWLEDGEMENT")
		_labels.feedback_caption.add_theme_color_override("font_color", color)
		_labels.feedback_message.text = str(feedback.get("text", ""))
	_layout_hud()


func _set_metric(key: String, value: Variant, percent: bool = false) -> void:
	var metric: Dictionary = _metrics[key]
	var available := value != null and (not percent or float(value) >= 0)
	metric.value.text = (("%.0f%%" % float(value)) if percent else str(value)) if available else "—"
	metric.ratio = clampf(float(value) / 100.0, 0, 1) if available and percent else 0.0
	metric.bar.color = DANGER if float(metric.ratio) >= 0.9 else (AMBER if float(metric.ratio) >= 0.7 else CYAN)


func make_screen(title: String, sub: String, prompt: String) -> Control:
	var panel := OpeningScreen.new()
	panel.font = _get_font()
	panel.screen_title = title
	panel.screen_sub = sub
	panel.screen_prompt = prompt
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# The returned panel is deliberately unattached. Seed its dimensions now;
	# anchors are set again in _ready, once its real parent exists.
	panel.size = get_viewport_rect().size if is_inside_tree() else Vector2(1600, 900)
	panel.anchor_right = 1.0
	panel.anchor_bottom = 1.0
	var wopr := title.replace(" ", "").to_upper() == "WOPR"
	panel.nodes.overline = _label(panel, "WARGAMES / SYSTEM INTERFACE", 14, CYAN)
	panel.nodes.title = _label(panel, "WOPR" if wopr else title, 156 if wopr else 46, IVORY)
	panel.nodes.title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	panel.nodes.title.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
	panel.nodes.slogan = _label(panel, "THE MOST DANGEROUS GAME.", 23, CYAN)
	panel.nodes.warning = _label(panel, "REAL SYSCALLS. THIS MACHINE AND ITS SNAPSHOTS CAN BE DESTROYED." if wopr else "CONNECTION SUSPENDED / THE MACHINE REMAINS REAL.", 15, DANGER if wopr else AMBER)
	panel.nodes.warning.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	panel.nodes.sub = _label(panel, sub, 17, IVORY)
	panel.nodes.sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	panel.nodes.sub.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
	panel.nodes.sub.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	panel.prompt_plate = _plate(panel, CYAN)
	panel.nodes.prompt = _label(panel.prompt_plate, prompt, 17, CYAN)
	panel.nodes.footer = _label(panel, "WOPR / STRATEGIC SYSTEMS     •     LIVE MACHINE INTERFACE                                       ESC / DISCONNECT", 13, MUTED)
	panel.radar = RadarGraphic.new()
	panel.radar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(panel.radar)
	panel.nodes.radar_title = _label(panel, "SYS / TOPOLOGY RECONSTRUCTION", 13, MUTED)
	panel.nodes.radar_footer = _label(panel, "PROCESS / NETWORK / STORAGE\nSUBMERGED CIRCUIT CITY", 13, CYAN)
	panel._layout()
	return panel
