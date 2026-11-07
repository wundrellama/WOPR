shader_type spatial;
// Tron floor: dark plates with glowing seams; major lines every 10 cells.

uniform vec4 seam_color : source_color = vec4(0.10, 0.55, 0.85, 1.0);
uniform vec4 major_color : source_color = vec4(0.20, 0.90, 1.0, 1.0);
uniform vec4 plate_color : source_color = vec4(0.012, 0.022, 0.045, 1.0);
uniform float cell_size : hint_range(5.0, 200.0) = 50.0;
uniform float pulse_speed : hint_range(0.0, 5.0) = 0.6;

varying vec2 world_xz;

void vertex() {
	world_xz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
}

float grid_line(float coord, float width) {
	float f = abs(fract(coord / cell_size - 0.5) - 0.5) * cell_size;
	return 1.0 - smoothstep(0.0, width, f);
}

void fragment() {
	float minor = max(grid_line(world_xz.x, 1.2), grid_line(world_xz.y, 1.2));
	float major = max(grid_line(world_xz.x, 2.6), grid_line(world_xz.y, 2.6));
	// major lines every 10 cells
	float f10x = abs(fract(world_xz.x / (cell_size * 10.0) - 0.5) - 0.5) * cell_size * 10.0;
	float f10y = abs(fract(world_xz.y / (cell_size * 10.0) - 0.5) - 0.5) * cell_size * 10.0;
	float major10 = max(1.0 - smoothstep(0.0, 4.0, f10x), 1.0 - smoothstep(0.0, 4.0, f10y));
	// slow travelling pulse so the floor breathes
	float pulse = 0.75 + 0.25 * sin(TIME * pulse_speed + (world_xz.x + world_xz.y) * 0.004);

	vec3 col = plate_color.rgb;
	col += seam_color.rgb * minor * 0.55 * pulse;
	col += major_color.rgb * major * 0.5 * pulse;
	col += major_color.rgb * major10 * 1.2;

	float dist = length(world_xz) / 2600.0;
	col *= 1.0 - clamp(dist, 0.0, 0.85);  // fade to void at the horizon

	ALBEDO = col;
	EMISSION = col;
	ROUGHNESS = 0.4;
}
