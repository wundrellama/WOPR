shader_type spatial;
// Memory is a quiet glass sea, not an opaque blue overlay.
render_mode blend_mix, depth_draw_never, cull_disabled;

uniform vec4 deep_color : source_color = vec4(0.02, 0.12, 0.35, 0.35);
uniform vec4 crest_color : source_color = vec4(0.15, 0.75, 1.0, 0.9);

varying vec2 world_xz;

void vertex() {
	world_xz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
	// gentle swell
	VERTEX.y += sin(world_xz.x * 0.02 + TIME * 1.2) * 1.6
	         + sin(world_xz.y * 0.017 - TIME * 0.9) * 1.2;
}

void fragment() {
	float bands = sin(world_xz.x * 0.025 + sin(world_xz.y * 0.02 + TIME * 0.2) * 2.0 + TIME * 0.5);
	bands = pow(max(0.0, bands), 24.0);
	vec3 col = mix(deep_color.rgb, crest_color.rgb, bands * 0.32);
	float dist = length(world_xz) / 2600.0;
	col *= 1.0 - clamp(dist, 0.0, 0.9);
	ALBEDO = col * 0.25;
	EMISSION = col * 0.18;
	ROUGHNESS = 0.28;
	METALLIC = 0.6;
	ALPHA = (0.10 + bands * 0.12) * (1.0 - clamp(dist, 0.0, 0.9));
}
