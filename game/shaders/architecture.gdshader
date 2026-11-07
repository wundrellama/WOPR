shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never;
// A second material pass: light lives in the edges and circuitry, not the walls.
uniform vec4 signal_color : source_color = vec4(0.3, 0.9, 1.0, 1.0);
uniform float activity : hint_range(0.0, 2.0) = 0.25;

void vertex() {
	VERTEX += NORMAL * 0.001;
}

void fragment() {
	// BoxMesh packs its six faces into a 3 x 2 UV atlas.
	vec2 face_uv = fract(UV * vec2(3.0, 2.0));
	vec2 fw = max(fwidth(UV * vec2(3.0, 2.0)), vec2(0.0005));
	vec2 edge_distance = min(face_uv, vec2(1.0) - face_uv);
	vec2 edges = vec2(1.0) - smoothstep(fw * 0.7, fw * 1.8, edge_distance);
	float edge = max(edges.x, edges.y);
	float floors = pow(max(0.0, sin(face_uv.y * 75.398)), 32.0);
	float columns = step(0.72, fract(face_uv.x * 5.0));
	float heartbeat = 0.65 + 0.35 * sin(TIME * 1.4 + UV.y * 7.0);
	float windows = floors * columns * (0.15 + activity * 0.45);
	float crown = smoothstep(0.91, 0.95, face_uv.y) * (1.0 - smoothstep(0.96, 0.99, face_uv.y));
	float light = edge * 0.65 + windows + crown * (0.4 + activity * heartbeat);
	// ALBEDO supplies unshaded output on both Compatibility and Forward+.
	ALBEDO = signal_color.rgb * light * 1.4;
	EMISSION = signal_color.rgb * light * 0.6;
	ALPHA = clamp(light * 1.4, 0.0, 1.0);
}
