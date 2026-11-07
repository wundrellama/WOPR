extends Control
## Fine flight-instrument linework; never intercepts gameplay input.
var viewer: Camera3D
var target: Node3D
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
