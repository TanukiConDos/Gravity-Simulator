package app

import ecs "engine:ecs"
import foundation "engine:foundation"
import graphic "engine:graphics/front"
import hot "engine:hot"
import physics "engine:physics"
import physics_gpu "engine:physics/gpu"
import vk "engine:graphics/backend"
import "core:log"
import "core:time"

// The application runtime: it assembles the window, graphics backend/front,
// ECS world, physics, the optional GPU solver and the hot-reload services, then
// runs the fixed-step/free-running loops. The application supplies only `setup`
// (its world contents) and a title; everything else is engine capability.

// Event wait between main-loop iterations. The physics and graphics threads are
// independent; this only bounds input latency while the window is idle.
MAIN_LOOP_TIMEOUT_SEC :: 1.0 / 60.0

// With `-define:PROFILE=true`, the whole process is traced here.
PROFILE_TRACE_PATH :: "trace_app.spall"

Desc :: struct {
	title:       string,
	config_path: string,
	// Runs on the main thread after the world is created but before
	// `physics_init`, so it can reserve capacity and spawn the initial bodies.
	// `physics_init` then sizes the render snapshot from the resulting body
	// count. The world is not frozen yet, so custom pools/resources are allowed.
	setup:       proc(world: ^ecs.World, config: ^foundation.Config) -> bool,
}

// run brings up the engine, lets the application populate the world, and runs
// until the window closes or a thread reports a fatal error.
run :: proc(desc: Desc) -> bool {
	lowest := log.Level.Info
	when ODIN_DEBUG {
		lowest = log.Level.Debug
	}
	logger := log.create_console_logger(lowest)
	context.logger = logger
	if len(desc.title) > 0 {
		log.infof("%s", desc.title)
	}

	config_path := len(desc.config_path) > 0 ? desc.config_path : "./config.json"
	config := foundation.config_load(config_path)
	defer foundation.config_destroy()

	// Start tracing before the worker pool so that, at exit, parallel_destroy
	// runs first (LIFO defers) and the workers can release their buffers while
	// the context is still alive.
	when foundation.PROFILE_ENABLED {
		foundation.profile_start(PROFILE_TRACE_PATH)
		if len(desc.title) > 0 {foundation.profile_process_name(desc.title)}
		foundation.profile_thread_name("main")
		defer foundation.profile_stop()
		log.infof("profiling to %s (open it in the spall viewer)", PROFILE_TRACE_PATH)
	}

	foundation.parallel_init(config.worker_threads)
	defer foundation.parallel_destroy()

	world := ecs.world_create()
	defer ecs.world_destroy(world)

	if desc.setup != nil && !desc.setup(world, config) {
		log.errorf("Application setup failed")
		return false
	}
	// An empty scene still needs the Body pool: physics_init and the snapshot
	// sizing use body_count, which asserts a registered pool.
	_ = ecs.world_pool(world, physics.Body)
	// Reserve room for the hot-reloaded gameplay layer before physics sizes its
	// snapshot and pools. The app reserves its own initial capacity in `setup`.
	if config.hot_game {
		capacity := max(world.capacity, physics.body_count(world))
		ecs.world_reserve(world, capacity + hot.GAME_SPAWN_HEADROOM)
	}

	physics.physics_init(world, config^)
	scheduler := ecs.scheduler_create(foundation.default_job_system())
	defer ecs.scheduler_destroy(scheduler)
	physics.physics_register_systems(scheduler)

	window, window_ok := vk.window_init(1280, 720)
	if !window_ok {
		log.errorf("Failed to create window!")
		return false
	}
	defer vk.window_destroy(window)

	backend, backend_ok := vk.backend_init(window)
	if !backend_ok {
		log.errorf("Failed to create the graphics backend!")
		return false
	}
	defer vk.backend_destroy(backend)

	renderer, renderer_ok := graphic.renderer_init(backend, window, world)
	if !renderer_ok {
		log.errorf("Failed to create renderer!")
		return false
	}
	defer graphic.renderer_destroy(renderer)

	frame_source: Frame_Source
	frame_source_init(&frame_source, renderer, world)
	defer frame_source_destroy(&frame_source)

	graphic.graphic_register_systems(scheduler)
	if !ecs.scheduler_finalize(scheduler) {
		log.errorf("Failed to resolve the system schedule!")
		return false
	}

	// GPU gravity is a backend of the selected gravity solver (brute force or
	// octree). Install it before the world is frozen so the physics thread sees
	// it from the first tick; on any failure the CPU solver runs instead.
	gpu_solver: ^physics_gpu.Gpu_Gravity
	if config.gravity_backend == .GPU {
		capacity := max(world.capacity, physics.body_count(world))
		// The front owns the compute context (attached to the backend's device);
		// the runtime hands it to the solver and keeps it alive past the solver.
		compute := graphic.renderer_compute(renderer)
		if solver, solver_ok := physics_gpu.gpu_gravity_init(compute, world, config.algorithm, capacity); solver_ok {
			gpu_solver = solver
			graphic.renderer_set_stream_producer(
				renderer,
				physics_gpu.stream_handle(solver),
				physics_gpu.stream_ops(),
			)
			physics.physics_set_gravity_solver(world, physics_gpu.gpu_gravity_backend(solver))
			log.infof(
				"GPU gravity enabled (%v): %s",
				config.algorithm,
				physics_gpu.gpu_gravity_info(solver).device_name,
			)
		} else {
			log.warnf("GPU gravity unavailable; falling back to the CPU solver")
		}
	}
	defer if gpu_solver != nil {
		// Release the stream the backend holds, then destroy the solver.
		graphic.renderer_set_stream_producer(renderer, nil, {})
		physics_gpu.gpu_gravity_destroy(gpu_solver)
	}

	// Development reloading watches files on the main thread and hands requests
	// to the thread that owns the affected pipelines.
	reload := hot.reload_init(config.hot_reload, renderer, gpu_solver)
	defer hot.reload_destroy(&reload)

	// Gameplay hot reload registers its persistent state resource before the
	// freeze; the library itself is built and swapped in later.
	game := hot.game_init(
		config.hot_game,
		hot.Host {
			world = world,
			input = &window.input,
			reseed = frame_source_reseed_callback,
			reseed_user = rawptr(&frame_source),
			logger = logger,
		},
	)
	defer hot.game_destroy(game)

	ctx := Context {
		world     = world,
		scheduler = scheduler,
		game      = game,
	}

	// Every pool and resource the threads use now exists: freeze the registries
	// so the physics and graphics threads only ever perform concurrent reads.
	ecs.world_freeze(world)

	loop := foundation.loop_start(
		foundation.Loop_Desc {
			user = &ctx,
			physics_step = physics_step,
			graphics_frame = graphics_frame,
			config_applied = config_applied,
			logger = logger,
		},
	)
	defer foundation.loop_stop(loop)

	last_log := time.tick_now()
	for !vk.window_should_close(window) {
		{
			// Cheap mtime poll; compiles on this thread, reloads on the owner.
			foundation.profile_scope("app.hot_reload")
			hot.reload_poll(&reload)
			hot.game_poll(game)
		}

		{
			foundation.profile_scope("app.wait_events")
			vk.window_wait_events_timeout(MAIN_LOOP_TIMEOUT_SEC)
		}

		{
			// GLFW is only touched on this thread: refresh the input/window
			// snapshot the render phase consumes.
			foundation.profile_scope("app.pump")
			vk.window_pump(window)
		}

		{
			foundation.profile_scope("app.tick")
			if time.duration_seconds(time.tick_diff(last_log, time.tick_now())) >= 1.0 {
				last_log = time.tick_now()
				frame := foundation.loop_frame_time(loop)
				tick := foundation.loop_tick_time(loop)
				log.infof("[DEBUG] frametime: %.2f ms | ticktime: %.2f µs", frame, tick)
			}
		}
	}
	return true
}
