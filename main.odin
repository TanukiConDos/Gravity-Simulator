package main

import graphic "./Engine/Graphic"
import physic "./Engine/physic"
import foundation "./foundation"
import "core:log"
import "core:math/rand"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"

@(private)
g_physic_system: physic.PhysicSystem
@(private)
g_objects: ^[dynamic]physic.PhysicObject

@(private)
_read_json_scene :: proc(
	filename: string,
) -> (
	objects: ^[dynamic]physic.PhysicObject,
	success: bool,
) {
	data, err := os.read_entire_file(
		filename,
		context.temp_allocator,
	); if err != nil {return nil, false}
	text := string(data); objects = new([dynamic]physic.PhysicObject)
	pos := 0; _skip_whitespace(text, &pos)
	if pos >= len(text) || text[pos] != '[' {return objects, true}
	pos += 1
	for {
		_skip_whitespace(text, &pos)
		if pos >= len(text) {break}
		if text[pos] == ']' {break}
		if text[pos] == '{' {obj := _parse_object(text, &pos); append(objects, obj)} else {break}
		_skip_whitespace(text, &pos)
		if pos < len(text) && text[pos] == ',' {pos += 1}
	}
	return objects, true
}

@(private)
_skip_whitespace :: proc(text: string, pos: ^int) {for pos^ < len(text) {switch
		text[pos^] {case ' ', '\t', '\n', '\r':
			pos^ += 1; case:
			return}}}

@(private)
_parse_object :: proc(text: string, pos: ^int) -> physic.PhysicObject {
	obj: physic.PhysicObject; pos^ += 1
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
			arr := _parse_array(text, pos)
			if len(arr) >= 3 {obj.position = {f32(arr[0]), f32(arr[1]), f32(arr[2])}}
		case "radius":
			obj.radius = f32(_parse_number(text, pos))
		case "velocity":
			arr := _parse_array(text, pos)
			if len(arr) >= 3 {obj.velocity = {f32(arr[0]), f32(arr[1]), f32(arr[2])}}
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
	val, _ := strconv.parse_f64(text[start:pos^])
	return val}
@(private)
_parse_array :: proc(text: string, pos: ^int) -> [dynamic]f64 {arr := make([dynamic]f64)
	_skip_whitespace(text, pos)
	if pos^ >= len(text) || text[pos^] != '[' {return arr}
	pos^ += 1
	for {_skip_whitespace(text, pos); if pos^ >= len(text) {break}; if text[pos^] == ']' {pos^ += 1
			break}
		if text[pos^] == ',' {pos^ += 1; continue}
		append(&arr, _parse_number(text, pos))}
	return arr}
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

@(private)
_sim_init :: proc() {
	config := foundation.config_get()
	switch config.system_creation_mode {
	case .RANDOM:
		sim_random_init()
	case .FILE:
		sim_file_init()
	}
	g_physic_system = physic.physic_system_create(g_objects, config)
}

@(private)
_sim_end :: proc() {
	physic.physic_system_destroy(&g_physic_system)
	delete(g_objects^); g_objects = nil
}

@(private)
sim_file_init :: proc() {
	config := foundation.config_get()
	path := strings.concatenate({"./scenes/", config.filename}, context.temp_allocator)
	objects, success := _read_json_scene(path)
	if !success ||
	   objects ==
		   nil {log.errorf("Failed to load scene: %s", path); objects = new([dynamic]physic.PhysicObject)}
	g_objects = objects
}

@(private)
sim_random_init :: proc() {
	config := foundation.config_get(); objects := new([dynamic]physic.PhysicObject)
	append(objects, physic.physic_object_make({0, 0, 0}, {0, 0, 0}, 6e27, 12371e3))
	append(objects, physic.physic_object_make({0, 383400e3, 0}, {20e3, 0, 0}, 7.35e25, 6737e3))
	for i in 0 ..< config.num_objects {
		x := rand.float32_range(
			-1e10,
			1e10,
		); y := rand.float32_range(-1e10, 1e10); z := rand.float32_range(-1e10, 1e10)
		append(objects, physic.physic_object_make({x, y, z}, {0, 0, 0}, 6e27, 12371e3))
	}
	g_objects = objects
}

main :: proc() {
	lowest := log.Level.Info
	when ODIN_DEBUG {
		lowest = log.Level.Debug
	}
	logger := log.create_console_logger(lowest)
	context.logger = logger
	g_sim_logger = logger
	log.infof("Gravity Simulator - Odin Edition")

	config := foundation.config_load("./config.json")
	foundation.parallel_init(config.worker_threads)
	defer foundation.parallel_destroy()

	window, window_ok := graphic.window_create(1280, 720)
	if !window_ok {log.errorf("Failed to create window!"); return}
	defer graphic.window_destroy(window)

	_sim_init()
	defer _sim_end()

	ctx := SimulationContext {
		objects       = g_objects,
		physic_system = &g_physic_system,
		window        = window,
	}

	renderer, renderer_ok := graphic.renderer_create(
		window,
		g_objects,
		&g_physic_system,
		&ctx.delta_time,
	)
	if !renderer_ok {log.errorf("Failed to create renderer!"); return}
	defer graphic.renderer_destroy(renderer)
	ctx.renderer = renderer

	physics_thread, graphics_thread := parallel_start(&ctx)

	last_log := time.tick_now()
	for !graphic.window_should_close(window) {
		graphic.window_poll_events()

		if time.duration_seconds(time.tick_diff(last_log, time.tick_now())) >= 1.0 {
			last_log = time.tick_now()
			frame := sync.atomic_load(&ctx.frame_time)
			tick := sync.atomic_load(&ctx.tick_time)
			log.infof("[DEBUG] frametime: %.2f ms | ticktime: %.2f µs", frame, tick)
		}
	}

	sync.atomic_store(&ctx.exit, true)
	parallel_stop(physics_thread, graphics_thread)
}
