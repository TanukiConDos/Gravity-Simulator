package main

import app "engine:app"
import ecs "engine:ecs"
import foundation "engine:foundation"
import physics "engine:physics"
import "core:log"
import "core:math/rand"
import "core:os"
import "core:strconv"
import "core:strings"

// Application entry point: a gravity/planet simulation. Everything reusable
// (window, Vulkan, renderer, ECS/physics assembly, hot reload, loops) lives
// under `engine/`; this package only describes the planets to simulate.

// Initial conditions read from a scene file, before they become ECS bodies.
@(private)
_Scene_Body :: struct {
	position: [3]f32,
	velocity: [3]f32,
	mass:     f64,
	radius:   f32,
}

@(private)
_read_json_scene :: proc(
	filename: string,
) -> (
	bodies: ^[dynamic]_Scene_Body,
	success: bool,
) {
	data, err := os.read_entire_file(
		filename,
		context.temp_allocator,
	); if err != nil {return nil, false}
	text := string(data); bodies = new([dynamic]_Scene_Body)
	pos := 0; _skip_whitespace(text, &pos)
	if pos >= len(text) || text[pos] != '[' {return bodies, true}
	pos += 1
	for {
		_skip_whitespace(text, &pos)
		if pos >= len(text) {break}
		if text[pos] == ']' {break}
		if text[pos] == '{' {obj := _parse_object(text, &pos); append(bodies, obj)} else {break}
		_skip_whitespace(text, &pos)
		if pos < len(text) && text[pos] == ',' {pos += 1}
	}
	return bodies, true
}

@(private)
_skip_whitespace :: proc(text: string, pos: ^int) {for pos^ < len(text) {switch
		text[pos^] {case ' ', '\t', '\n', '\r':
			pos^ += 1; case:
			return}}}

@(private)
_parse_object :: proc(text: string, pos: ^int) -> _Scene_Body {
	obj: _Scene_Body; pos^ += 1
	for {
		_skip_whitespace(text, pos); if pos^ >= len(text) {break}
		if text[pos^] == '}' {pos^ += 1; break}
		if text[pos^] == ',' {pos^ += 1; continue}
		key := _parse_string(text, pos)
		_skip_whitespace(text, pos)
		if pos^ < len(text) && text[pos^] == ':' {pos^ += 1}
		switch key {
		case "mass":
			obj.mass = _parse_number(text, pos)
		case "position":
			buf: [8]f64
			n := _parse_array(text, pos, buf[:])
			if n >= 3 {obj.position = {f32(buf[0]), f32(buf[1]), f32(buf[2])}}
		case "radius":
			obj.radius = f32(_parse_number(text, pos))
		case "velocity":
			buf: [8]f64
			n := _parse_array(text, pos, buf[:])
			if n >= 3 {obj.velocity = {f32(buf[0]), f32(buf[1]), f32(buf[2])}}
		case:
			_skip_value(text, pos)
		}
	}
	return obj
}

@(private)
_parse_string :: proc(text: string, pos: ^int) -> string {_skip_whitespace(text, pos); if pos^ >=
		   len(text) ||
	   text[pos^] != '"' {return ""}
	pos^ += 1
	start := pos^
	for pos^ < len(text) && text[pos^] != '"' {pos^ += 1}
	result := text[start:pos^]
	if pos^ < len(text) {pos^ += 1}
	return result}
@(private)
_parse_number :: proc(text: string, pos: ^int) -> f64 {_skip_whitespace(text, pos); start := pos^
	for pos^ <
	    len(
		    text,
	    ) {c := text[pos^]; if (c >= '0' && c <= '9') || c == '-' || c == '+' || c == '.' || c == 'e' || c == 'E' {pos^ += 1} else {break}}
	val, parse_ok := strconv.parse_f64(text[start:pos^])
	if !parse_ok {log.warnf("[SCENE] Malformed number in scene file: %q", text[start:pos^])}
	return val}
@(private)
// Parses a JSON number array into `out` and returns how many values were
// present. The caller supplies a stack buffer so the parser allocates nothing;
// only the first three components are consumed, and any extra values are counted
// but dropped (with a warning) so the cursor still advances past them.
_parse_array :: proc(text: string, pos: ^int, out: []f64) -> int {count := 0
	_skip_whitespace(text, pos)
	if pos^ >= len(text) || text[pos^] != '[' {return 0}
	pos^ += 1
	for {_skip_whitespace(text, pos); if pos^ >= len(text) {break}; if text[pos^] == ']' {pos^ += 1
			break}
		if text[pos^] == ',' {pos^ += 1; continue}
		value := _parse_number(text, pos)
		if count < len(out) {out[count] = value}
		count += 1}
	if count > len(out) {log.warnf("[SCENE] array has %d values; keeping the first %d", count, len(out))}
	return count}
@(private)
_skip_value :: proc(text: string, pos: ^int) {_skip_whitespace(text, pos); if pos^ >=
	   len(text) {return}
	switch
	text[pos^] {case '"':
		_parse_string(text, pos); case '[':
		depth := 1; pos^ += 1; for pos^ < len(text) && depth > 0 {switch text[pos^] {case '[':
				depth += 1; case ']':
				depth -= 1}; pos^ += 1}; case '{':
		depth := 1; pos^ += 1; for pos^ < len(text) && depth > 0 {switch text[pos^] {case '{':
				depth += 1; case '}':
				depth -= 1}; pos^ += 1}; case:
		for pos^ < len(text) {c := text[pos^]; if c == ',' ||
			   c == '}' ||
			   c == ']' ||
			   c == ' ' ||
			   c == '\t' ||
			   c == '\n' ||
			   c == '\r' {break}
			pos^ += 1}}}

// setup populates the world from the configured scene or the random generator.
// It runs before physics_init, so body pools are created on demand and the render
// snapshot is sized from the final body count.
@(private)
_setup :: proc(world: ^ecs.World, config: ^foundation.Config) -> bool {
	switch config.system_creation_mode {
	case .RANDOM:
		sim_random_init(world, config)
	case .FILE:
		sim_file_init(world, config)
	}
	return true
}

@(private)
sim_file_init :: proc(world: ^ecs.World, config: ^foundation.Config) {
	path := strings.concatenate({"./scenes/", config.filename}, context.temp_allocator)
	bodies, success := _read_json_scene(path)
	if !success || bodies == nil {
		log.errorf("Failed to load scene: %s", path)
		bodies = new([dynamic]_Scene_Body)
	}
	defer {delete(bodies^); free(bodies)}
	ecs.world_reserve(world, len(bodies^) + 1)
	for body in bodies {
		physics.body_spawn(
			world,
			body.position,
			body.velocity,
			body.mass,
			body.radius,
		)
	}
}

@(private)
sim_random_init :: proc(world: ^ecs.World, config: ^foundation.Config) {
	ecs.world_reserve(world, config.num_objects + 2)
	physics.body_spawn(world, {0, 0, 0}, {0, 0, 0}, 6e27, 12371e3)
	physics.body_spawn(world, {0, 383400e3, 0}, {20e3, 0, 0}, 7.35e25, 6737e3)
	for i in 0 ..< config.num_objects {
		x := rand.float32_range(
			-1e10,
			1e10,
		); y := rand.float32_range(-1e10, 1e10); z := rand.float32_range(-1e10, 1e10)
		physics.body_spawn(world, {x, y, z}, {0, 0, 0}, 6e27, 12371e3)
	}
}

main :: proc() {
	if !app.run(
		app.Desc {
			title = "Gravity Simulator - Odin Edition",
			config_path = "./config.json",
			setup = _setup,
		},
	) {
		log.errorf("Simulation exited with an error")
	}
}
