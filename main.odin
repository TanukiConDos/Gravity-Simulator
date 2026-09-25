package main

import graphic "./Engine/Graphic"
import physic "./Engine/physic"
import ecs "./Engine/ecs"
import foundation "./foundation"
import "core:log"
import "core:math/rand"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"

@(private)
g_world: ^ecs.World
@(private)
g_scheduler: ^ecs.Scheduler

// Main-loop event wait. The loop has nothing to do between events, so it blocks
// instead of polling; the timeout keeps input latency bounded if the window
// stays idle. The physics thread paces itself and the graphics thread is
// independent, so this only affects event handling.
MAIN_LOOP_TIMEOUT_SEC :: 1.0 / 60.0

// Built with `-define:PROFILE=true`, the whole app (physics, graphics and main
// threads) is traced to this file. Without the flag it is never touched.
PROFILE_TRACE_PATH :: "trace_app.spall"

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
	val, parse_ok := strconv.parse_f64(text[start:pos^])
	if !parse_ok {log.warnf("[SCENE] Malformed number in scene file: %q", text[start:pos^])}
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
	g_world = ecs.world_create()
	switch config.system_creation_mode {
	case .RANDOM:
		sim_random_init()
	case .FILE:
		sim_file_init()
	}
	physic.physic_init(g_world, config^)
	g_scheduler = ecs.scheduler_create()
	physic.physic_register_systems(g_scheduler)
}

@(private)
_sim_end :: proc() {
	ecs.scheduler_destroy(g_scheduler); g_scheduler = nil
	ecs.world_destroy(g_world); g_world = nil
}

@(private)
sim_file_init :: proc() {
	config := foundation.config_get()
	path := strings.concatenate({"./scenes/", config.filename}, context.temp_allocator)
	bodies, success := _read_json_scene(path)
	if !success || bodies == nil {
		log.errorf("Failed to load scene: %s", path)
		bodies = new([dynamic]_Scene_Body)
	}
	defer {delete(bodies^); free(bodies)}
	ecs.world_reserve(g_world, len(bodies^) + 1)
	for body in bodies {
		physic.body_spawn(
			g_world,
			body.position,
			body.velocity,
			body.mass,
			body.radius,
		)
	}
}

@(private)
sim_random_init :: proc() {
	config := foundation.config_get()
	ecs.world_reserve(g_world, config.num_objects + 2)
	physic.body_spawn(g_world, {0, 0, 0}, {0, 0, 0}, 6e27, 12371e3)
	physic.body_spawn(g_world, {0, 383400e3, 0}, {20e3, 0, 0}, 7.35e25, 6737e3)
	for i in 0 ..< config.num_objects {
		x := rand.float32_range(
			-1e10,
			1e10,
		); y := rand.float32_range(-1e10, 1e10); z := rand.float32_range(-1e10, 1e10)
		physic.body_spawn(g_world, {x, y, z}, {0, 0, 0}, 6e27, 12371e3)
	}
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

	// Start tracing before the worker pool so that, at exit, parallel_destroy
	// runs first (LIFO defers) and the workers can release their buffers while
	// the context is still alive.
	when foundation.PROFILE_ENABLED {
		foundation.profile_start(PROFILE_TRACE_PATH)
		foundation.profile_process_name("Gravity-Simulator")
		foundation.profile_thread_name("main")
		defer foundation.profile_stop()
		log.infof("profiling to %s (open it in the spall viewer)", PROFILE_TRACE_PATH)
	}

	foundation.parallel_init(config.worker_threads)
	defer foundation.parallel_destroy()

	window, window_ok := graphic.window_init(1280, 720)
	if !window_ok {log.errorf("Failed to create window!"); return}
	defer graphic.window_destroy(window)

	_sim_init()
	defer _sim_end()

	ctx := SimulationContext {
		world     = g_world,
		scheduler = g_scheduler,
		window    = window,
	}

	renderer, renderer_ok := graphic.renderer_init(window, g_world)
	if !renderer_ok {log.errorf("Failed to create renderer!"); return}
	defer graphic.renderer_destroy(renderer)
	graphic.graphic_register_systems(g_scheduler)

	// Every pool and resource the threads use now exists: freeze the registries
	// so the physics and graphics threads only ever perform concurrent reads.
	ecs.world_freeze(g_world)

	physics_thread, graphics_thread := parallel_start(&ctx)

	last_log := time.tick_now()
	for !graphic.window_should_close(window) {
		{
			foundation.profile_scope("main.wait_events")
			graphic.window_wait_events_timeout(MAIN_LOOP_TIMEOUT_SEC)
		}

		{
			foundation.profile_scope("main.tick")
			if time.duration_seconds(time.tick_diff(last_log, time.tick_now())) >= 1.0 {
				last_log = time.tick_now()
				frame := sync.atomic_load(&ctx.frame_time)
				tick := sync.atomic_load(&ctx.tick_time)
				log.infof("[DEBUG] frametime: %.2f ms | ticktime: %.2f µs", frame, tick)
			}
		}
	}

	sync.atomic_store(&ctx.exit, true)
	parallel_stop(physics_thread, graphics_thread)
}
