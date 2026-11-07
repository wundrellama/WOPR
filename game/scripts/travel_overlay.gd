extends Control
## Presentation only: the controller owns navigation, network replies, coverage
## tweens and keyboard locking. No requests, action handlers or claimed progress.

const NAVY := Color("070f18")
const CYAN := Color("72d9d4")
const AMBER := Color("e6b673")
const IVORY := Color("e1e8e5")
const MUTED := Color("8aabae")

## Tween 0 -> 1, hold for the real reply, then tween 1 -> 0 before finish().
## The base rectangle has no aperture: coverage == 1 conceals EVERY scene pixel.
var coverage: float = 0.0:
	set(value):
		coverage = clampf(value, 0.0, 1.0)
		if is_instance_valid(_text):
			_text.modulate.a = coverage
		queue_redraw()

var elapsed: float = 0.0

var _kind := "vault"
var _accent := AMBER
var _font: SystemFont
var _text: Control
var _overline: Label
var _destination: Label
var _phase: Label
var _warning: Label


func _init() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	clip_contents = true
	_build_text()
	resized.connect(_layout)
	_layout()


func begin(kind: String, destination: String) -> void:
	_kind = "ssh" if kind == "ssh" else "vault"
	_accent = CYAN if _kind == "ssh" else AMBER
	elapsed = 0.0
	coverage = 0.0
	_build_text()
	_overline.text = "SSH TRANSIT / LINK ESTABLISHMENT" if _kind == "ssh" else "FILE VAULT / DESCENDING"
	_overline.add_theme_color_override("font_color", _accent)
	# Keep an arbitrary path/host on one line, including embedded control chars.
	_destination.text = _single_line(destination)
	set_phase("AWAITING REMOTE SNAPSHOT" if _kind == "ssh" else "AWAITING DIRECTORY")
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = true
	_layout()
	queue_redraw()


func set_phase(message: String) -> void:
	_build_text()
	_phase.text = _single_line(message)


func finish() -> void:
	visible = false


func _process(delta: float) -> void:
	if not visible:
		return
	elapsed += delta
	queue_redraw()


func _single_line(value: String) -> String:
	return value.replace("\r", " ").replace("\n", " ").replace("\t", " ")


func _build_text() -> void:
	if is_instance_valid(_text):
		return
	_font = SystemFont.new()
	_font.font_names = PackedStringArray(["JetBrains Mono", "DejaVu Sans Mono", "Liberation Mono", "monospace"])
	_font.allow_system_fallback = true
	_text = Control.new()
	_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_text.modulate.a = coverage
	add_child(_text)
	_text.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overline = _label("", 14, _accent)
	_destination = _label("", 32, IVORY)
	_phase = _label("", 14, MUTED)
	_warning = _label("NAVIGATION ONLY / ACTION INPUT SUSPENDED", 12, MUTED)


func _label(value: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.focus_mode = Control.FOCUS_NONE
	label.text = value
	label.add_theme_font_override("font", _font)
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_OFF
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.clip_text = true
	_text.add_child(label)
	return label


func _layout() -> void:
	if not is_instance_valid(_text):
		return
	var compact := size.x < 1300.0
	var width := minf(size.x * 0.76, 1100.0)
	var left := (size.x - width) * 0.5
	_overline.add_theme_font_size_override("font_size", 12 if compact else 14)
	_destination.add_theme_font_size_override("font_size", 25 if compact else 32)
	_phase.add_theme_font_size_override("font_size", 13 if compact else 14)
	_warning.add_theme_font_size_override("font_size", 11 if compact else 12)
	_place(_overline, Rect2(left, size.y * 0.355, width, 28.0))
	_place(_destination, Rect2(left, size.y * 0.410, width, 48.0))
	_place(_phase, Rect2(left, size.y * 0.525, width, 28.0))
	_place(_warning, Rect2(size.x * 0.06, size.y * 0.865, size.x * 0.88, 28.0))
	queue_redraw()


func _place(node: Control, rect: Rect2) -> void:
	node.position = rect.position
	node.size = rect.size


func _ink(alpha: float) -> Color:
	return Color(_accent, alpha * coverage)


func _draw() -> void:
	if coverage <= 0.0 or size.x <= 0.0 or size.y <= 0.0:
		return
	# Never punch out the centre, even while the visual tunnel is open.
	draw_rect(Rect2(Vector2.ZERO, size), Color(NAVY, coverage))
	if _kind == "ssh":
		_draw_ssh()
	else:
		_draw_vault()
	_draw_text_scrim()
	_draw_framing()
	_draw_waiting_mark()


func _draw_vault() -> void:
	# Perspective descends towards a lower rectangular aperture. Rings slide
	# continuously downward/inward; their wrap is invisible at either end.
	var far_center := size * Vector2(0.5, 0.70)
	var near_center := size * Vector2(0.5, 0.43)
	var inner := size * Vector2(0.035, 0.026)
	var outer := size * Vector2(0.78, 0.80)
	for corner in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
		draw_line(far_center + inner * corner, near_center + outer * corner, _ink(0.11), 1.0, true)
	for index in range(12):
		var travel := fposmod(float(index) / 12.0 - elapsed * 0.065, 1.0)
		var depth := pow(travel, 1.75)
		var center := far_center.lerp(near_center, depth)
		var half := inner.lerp(outer, depth)
		var fade := sin(travel * PI)
		var rect := Rect2(center - half, half * 2.0)
		draw_rect(rect, _ink(fade * 0.24), false, 1.0)
		# Short warm shoulders make the architecture feel machined, not a grid.
		var shoulder := minf(half.x * 0.24, 48.0)
		for side: float in [-1.0, 1.0]:
			var edge := center + Vector2(side * half.x, -half.y)
			draw_line(edge, edge - Vector2(side * shoulder, 0), _ink(fade * 0.54), 1.5, true)
	# Vertical descent light-lines on either side of the central typography.
	for side: float in [-1.0, 1.0]:
		for lane in range(3):
			var x := size.x * (0.5 + side * (0.34 + float(lane) * 0.055))
			draw_line(Vector2(x, size.y * 0.18), Vector2(x, size.y * 0.80), _ink(0.065), 1.0)
			for index in range(3):
				var travel := fposmod(elapsed * 0.16 + float(index) / 3.0 + float(lane) * 0.19, 1.0)
				var point := Vector2(x, size.y * lerpf(0.18, 0.80, travel))
				var fade := sin(travel * PI)
				draw_line(point - Vector2(0, size.y * 0.065), point, _ink(fade * 0.36), 1.5, true)
				draw_line(point - Vector2(0, 7), point, _ink(fade * 0.65), 2.0, true)


func _draw_ssh() -> void:
	var center := size * Vector2(0.5, 0.57)
	var inner := size * Vector2(0.022, 0.020)
	var outer := size * Vector2(0.80, 0.86)
	var rails := [
		Vector2(-1, -1), Vector2(-0.42, -1), Vector2(0.42, -1), Vector2(1, -1),
		Vector2(1, 0), Vector2(1, 1), Vector2(0.42, 1), Vector2(-0.42, 1),
		Vector2(-1, 1), Vector2(-1, 0),
	]
	for index in range(rails.size()):
		var axis: Vector2 = rails[index]
		var start := center + inner * axis
		var end := center + outer * axis
		draw_line(start, end, _ink(0.14), 1.0, true)
		# Tracers indicate motion only: never counts, packets received or state.
		for packet in range(2):
			var travel := fposmod(float(index) * 0.137 + float(packet) * 0.5 - elapsed * 0.14, 1.0)
			var depth := pow(travel, 1.65)
			var tail := pow(minf(travel + 0.055, 1.0), 1.65)
			var point := start.lerp(end, depth)
			var fade := sin(travel * PI)
			draw_line(point, start.lerp(end, tail), _ink(fade * 0.20), 3.0, true)
			draw_line(point, start.lerp(end, lerpf(depth, tail, 0.42)), _ink(fade * 0.76), 1.5, true)
	for index in range(11):
		var travel := fposmod(float(index) / 11.0 - elapsed * 0.075, 1.0)
		var half := inner.lerp(outer, pow(travel, 1.85))
		var fade := sin(travel * PI)
		draw_rect(Rect2(center - half, half * 2.0), _ink(fade * 0.21), false, 1.0)
		for side: float in [-1.0, 1.0]:
			var point := center + Vector2(side * half.x, half.y)
			draw_line(point, point - Vector2(side * minf(half.x * 0.2, 34.0), 0), _ink(fade * 0.40), 1.0, true)


func _draw_text_scrim() -> void:
	# A soft horizontal quiet zone, not a modal plate or a transparent hole.
	# All text remains on the same opaque veil as the perimeter architecture.
	var top := size.y * 0.28
	var height := size.y * 0.39
	for index in range(48):
		var t := (float(index) + 0.5) / 48.0
		var alpha := pow(sin(t * PI), 0.75) * 0.97 * coverage
		draw_rect(Rect2(0, top + height * float(index) / 48.0, size.x, height / 48.0 + 0.5), Color(NAVY, alpha))


func _draw_framing() -> void:
	var margin := size.x * 0.055
	var upper := size.y * 0.095
	var lower := size.y * 0.835
	# Interrupted hairlines and corner cuts borrow the flight console's ink.
	for side: float in [-1.0, 1.0]:
		var x := margin if side < 0.0 else size.x - margin
		var direction := -side
		draw_line(Vector2(x, upper), Vector2(x + direction * size.x * 0.24, upper), _ink(0.21), 1.0)
		draw_line(Vector2(x, upper), Vector2(x, upper + 22), _ink(0.46), 1.0)
		draw_line(Vector2(x, lower), Vector2(x + direction * size.x * 0.13, lower), _ink(0.21), 1.0)
		for tick in range(5):
			var y := size.y * (0.43 + float(tick) * 0.035)
			draw_line(Vector2(x, y), Vector2(x + direction * (12.0 if tick == 2 else 5.0), y), _ink(0.29), 1.0)
	var middle := Vector2(size.x * 0.5, upper)
	draw_line(middle - Vector2(26, 0), middle - Vector2(7, 0), _ink(0.40), 1.0)
	draw_line(middle + Vector2(7, 0), middle + Vector2(26, 0), _ink(0.40), 1.0)
	draw_circle(middle, 2.0, _ink(0.70), true, -1.0, true)


func _draw_waiting_mark() -> void:
	# Deliberately not a progress bar: fixed length, a slow breathing glint.
	var center := size * Vector2(0.5, 0.608)
	var breath := 0.5 + 0.5 * sin(elapsed * 1.65)
	draw_line(center - Vector2(64, 0), center + Vector2(64, 0), _ink(0.16), 1.0, true)
	draw_line(center - Vector2(15, 0), center + Vector2(15, 0), _ink(0.38 + breath * 0.25), 1.5, true)
	draw_circle(center, 2.0, _ink(0.55 + breath * 0.25), true, -1.0, true)
