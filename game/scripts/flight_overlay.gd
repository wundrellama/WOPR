extends Control
## Fine flight-instrument linework; never intercepts gameplay input.
var viewer: Camera3D
var target: Node3D
var hunt_targets: Dictionary = {}
var junk_targets: Dictionary = {}
var ink := Color("93bdbd")
var mono := SystemFont.new()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mono.font_names = PackedStringArray(["JetBrains Mono", "DejaVu Sans Mono"])


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	var center := size * 0.5
	var locked := is_instance_valid(target)
	var color := Color("e6b673") if locked else Color("a8dddd")
	for side in [-1.0, 1.0]:
		draw_line(center + Vector2(side * 7, 0), center + Vector2(side * 17, 0), color * Color(1, 1, 1, 0.7), 1.0, true)
		draw_line(center + Vector2(0, side * 7), center + Vector2(0, side * 11), color * Color(1, 1, 1, 0.7), 1.0, true)
	draw_circle(center, 1.2, color)
	if not is_instance_valid(viewer):
		return
	# Heading is the actual camera bearing, not decorative random telemetry.
	var heading := fposmod(-rad_to_deg(viewer.rotation.y), 360.0)
	var top := 250.0
	for i in 13:
		var x := center.x + (float(i) - 6.0) * 25.0
		var major := i % 3 == 0
		draw_line(Vector2(x, top), Vector2(x, top + (7.0 if major else 3.0)), Color(ink, 0.35), 1.0)
	draw_string(mono, Vector2(center.x - 31, top - 9), "%03d°" % int(heading), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(ink, 0.8))
	draw_colored_polygon(PackedVector2Array([Vector2(center.x - 3, top + 13), Vector2(center.x + 3, top + 13), Vector2(center.x, top + 9)]), Color(ink, 0.7))
	_draw_hunt_markers()
	if not locked or viewer.is_position_behind(target.global_position):
		return
	var point := viewer.unproject_position(target.global_position)
	if not Rect2(Vector2(36, 172), size - Vector2(72, 320)).has_point(point):
		return
	var radius := 22.0
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			var corner := point + Vector2(sx * radius, sy * radius)
			draw_line(corner, corner - Vector2(sx * 7, 0), color, 1.0, true)
			draw_line(corner, corner - Vector2(0, sy * 7), color, 1.0, true)
	var distance := viewer.global_position.distance_to(target.global_position)
	draw_string(mono, point + Vector2(radius + 7, 5), "LOCK / %.0fm" % distance, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, color)

func hunt_marker(world_position: Vector3) -> Dictionary:
	var center := size * 0.5
	var top := minf(285.0, size.y * 0.34)
	var bottom := maxf(top + 60.0, size.y - 300.0)
	var safe := Rect2(Vector2(48, top), Vector2(maxf(60.0, size.x - 96.0), bottom - top))
	var eye := viewer.to_local(world_position)
	var on_camera_plane := absf(eye.z) < 0.0001
	var behind := viewer.is_position_behind(world_position) or on_camera_plane
	var point := center if on_camera_plane else viewer.unproject_position(world_position)
	var direction := point - center
	if behind:
		direction = Vector2(eye.x, -eye.y)
	if direction.length_squared() < 0.001:
		direction = Vector2.DOWN
	direction = direction.normalized()
	var offscreen := behind or not safe.has_point(point)
	if offscreen:
		var half := safe.size * 0.5
		var scale_x := half.x / maxf(absf(direction.x), 0.001)
		var scale_y := half.y / maxf(absf(direction.y), 0.001)
		point = safe.get_center() + direction * minf(scale_x, scale_y)
	return {"point": point, "behind": behind, "offscreen": offscreen,
		"direction": direction, "distance": viewer.global_position.distance_to(world_position)}


func hunt_label_rect(point: Vector2, text_size: Vector2, occupied: Array) -> Rect2:
	var label_size := text_size + Vector2(8, 3)
	var x := point.x + 13.0
	if x + label_size.x > size.x - 32.0:
		x = point.x - label_size.x - 13.0
	x = clampf(x, 24.0, maxf(24.0, size.x - label_size.x - 24.0))
	var top := minf(260.0, size.y * 0.32)
	var bottom := maxf(top + label_size.y, size.y - 300.0)
	var candidate := Rect2(Vector2(x, point.y - 26.0), label_size)
	for row in [0, -1, 1, -2, 2, -3, 3, -4, 4]:
		candidate.position.y = clampf(point.y - 26.0 + float(row) * (label_size.y + 6.0), top, bottom - label_size.y)
		var overlaps := false
		for previous: Rect2 in occupied:
			if previous.grow(3).intersects(candidate):
				overlaps = true
				break
		if not overlaps:
			return candidate
	return candidate


static func junk_display_name(full_name: String) -> String:
	# Keep a distinguishing suffix, but never alter registry/path/wire values.
	return full_name if full_name.length() <= 20 else full_name.left(12) + "…" + full_name.right(7)


func _draw_hunt_markers() -> void:
	var occupied: Array = []
	var markers: Array = []
	for pid in hunt_targets:
		markers.append({"body": hunt_targets[pid], "text": "ROGUE %d" % int(pid), "color": Color("ff8976")})
	for id in junk_targets:
		var body: Variant = junk_targets[id]
		if not is_instance_valid(body):
			continue
		var record: Dictionary = body.get_meta("junk", {})
		var label := "VAULT " + junk_display_name(str(record.get("parent", ""))) if body.has_meta("junk_vault_beacon") else "%s LINK %s" % ["JUNK NEST" if bool(record.get("dir", false)) else "JUNK FILE", junk_display_name(str(record.get("name", id)))]
		markers.append({"body": body, "text": label, "color": Color("ff65c5")})
	for item: Dictionary in markers:
		var body: Variant = item.body
		if not is_instance_valid(body):
			continue
		var color: Color = item.color
		var marker := hunt_marker(body.global_position)
		var point: Vector2 = marker["point"]
		if marker["offscreen"]:
			var direction: Vector2 = marker["direction"]
			var tangent := direction.orthogonal()
			draw_colored_polygon(PackedVector2Array([point + direction * 7, point - direction * 5 + tangent * 5, point - direction * 5 - tangent * 5]), color)
		else:
			for sx in [-1.0, 1.0]:
				for sy in [-1.0, 1.0]:
					var corner := point + Vector2(sx * 11, sy * 11)
					draw_line(corner, corner - Vector2(sx * 5, 0), color, 1.5, true)
					draw_line(corner, corner - Vector2(0, sy * 5), color, 1.5, true)
		var text := "%s / %.0fm%s" % [str(item.text), float(marker["distance"]), " / BEHIND" if marker["behind"] else ""]
		var text_size := mono.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13)
		var label_rect := hunt_label_rect(point, text_size, occupied)
		occupied.append(label_rect)
		var attachment := Vector2(clampf(point.x, label_rect.position.x, label_rect.end.x), clampf(point.y, label_rect.position.y, label_rect.end.y))
		draw_line(point, attachment, Color(color, 0.5), 1.0, true)
		draw_rect(label_rect, Color(0.018, 0.035, 0.05, 0.94))
		draw_string(mono, label_rect.position + Vector2(4, 14), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, color)
