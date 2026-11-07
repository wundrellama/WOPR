shader_type sky;
// Deep blue-black atmosphere with a quiet star field. No external textures.
float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}
void sky() {
	vec3 direction = normalize(EYEDIR);
	float horizon = pow(1.0 - abs(direction.y), 12.0);
	vec3 color = mix(vec3(0.002, 0.005, 0.013), vec3(0.028, 0.064, 0.085), horizon);
	vec2 uv = SKY_COORDS * vec2(1100.0, 550.0);
	vec2 cell = floor(uv);
	float star = step(0.998, hash(cell));
	float point = 1.0 - smoothstep(0.0, 0.24, length(fract(uv) - 0.5));
	color += vec3(0.38, 0.58, 0.65) * star * point * smoothstep(0.02, 0.3, direction.y);
	COLOR = color;
}
