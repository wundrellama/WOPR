shader_type spatial;
// Memory tide: translucent moving sheet with a bright leading edge.
render_mode blend_add;

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
	float bands = sin(world_xz.x * 0.05 + world_xz.y * 0.03 + TIME * 1.6);
	bands = smoothstep(0.55, 1.0, bands);
	vec3 col = mix(deep_color.rgb, crest_color.rgb, bands * 0.7);
	float dist = length(world_xz) / 2600.0;
	col *= 1.0 - clamp(dist, 0.0, 0.9);
	ALBEDO = vec3(0.0);
	EMISSION = col * 0.5;
	ALPHA = deep_color.a * (0.6 + bands * 0.4) * (1.0 - clamp(dist, 0.0, 0.9));
}
