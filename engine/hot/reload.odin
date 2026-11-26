package hot

import foundation "engine:foundation"
import graphic "engine:graphics/front"
import shader "engine:graphics/shader"
import physics_gpu "engine:physics/gpu"
import "core:log"
import "core:strings"
import "core:time"

// Shader hot reload. The main thread owns the watches and runs `glslc`; the
// graphics and physics threads consume the reload requests at their next safe
// point (frame start and solve start respectively). Compiling here keeps the
// render thread from blocking on the toolchain during a frame.
//
// When glslc is unavailable the watcher falls back to the compiled `.spv` files,
// so running `engine/graphics/shader/build.sh` in another terminal still works.
RELOAD_POLL_MS :: 250.0

Reload :: struct {
	enabled:           bool,
	use_shader_tool:   bool,
	source_watches:    [dynamic]Source_Watch,
	output_watches:    [dynamic]Output_Watch,
	config_watch:      foundation.File_Watch,
	frame_graph_watch: foundation.File_Watch,
	last_poll:         time.Tick,
	renderer:          ^graphic.Renderer,
	gpu_solver:        ^physics_gpu.Gpu_Gravity,
}

@(private)
Source_Watch :: struct {
	watch:  foundation.File_Watch,
	source: string,
}

@(private)
Output_Watch :: struct {
	watch: foundation.File_Watch,
	job:   shader.Job,
}

reload_init :: proc(
	enabled: bool,
	renderer: ^graphic.Renderer,
	gpu_solver: ^physics_gpu.Gpu_Gravity,
) -> Reload {
	h := Reload {
		enabled    = enabled,
		renderer   = renderer,
		gpu_solver = gpu_solver,
		last_poll  = time.tick_now(),
	}
	if !enabled {return h}

	h.config_watch = foundation.watch_file(strings.clone("./config.json"))
	h.frame_graph_watch = foundation.watch_file(
		strings.clone("engine/graphics/frame_graph.json"),
	)
	h.use_shader_tool = shader.glslc_available()
	if h.use_shader_tool {
		for source in shader.SOURCES {
			path := shader.source_file_path(source)
			append(
				&h.source_watches,
				Source_Watch {
					watch = foundation.watch_file(strings.clone(path)),
					source = strings.clone(source),
				},
			)
		}
		log.infof("[HOT] Watching %d shader sources (in-app glslc)", len(h.source_watches))
	} else {
		for job in shader.JOBS {
			path := shader.output_path(job)
			append(
				&h.output_watches,
				Output_Watch {
					watch = foundation.watch_file(strings.clone(path)),
					job = job,
				},
			)
		}
		log.warnf(
			"[HOT] glslc not found; watching compiled SPIR-V (run engine/graphics/shader/build.sh)",
		)
	}
	return h
}

reload_destroy :: proc(h: ^Reload) {
	if h == nil {return}
	for &sw in h.source_watches {
		delete(sw.watch.path)
		delete(sw.source)
	}
	delete(h.source_watches)
	for &ow in h.output_watches {delete(ow.watch.path)}
	delete(h.output_watches)
	delete(h.config_watch.path)
	delete(h.frame_graph_watch.path)
	h^ = {}
}

reload_poll :: proc(h: ^Reload) {
	if h == nil || !h.enabled || h.renderer == nil {return}
	if time.duration_milliseconds(time.tick_diff(h.last_poll, time.tick_now())) < RELOAD_POLL_MS {
		return
	}
	h.last_poll = time.tick_now()

	if foundation.watch_poll(&h.config_watch) {
		if foundation.config_reload_from_disk("./config.json") {
			log.infof("[HOT] config.json parsed; applying on the next physics tick")
		}
	}
	if foundation.watch_poll(&h.frame_graph_watch) {
		graphic.renderer_request_frame_graph_reload(h.renderer)
		log.infof("[HOT] frame_graph.json changed; reload requested")
	}

	reload := false
	if h.use_shader_tool {
		for &sw in h.source_watches {
			if !foundation.watch_poll(&sw.watch) {continue}
			compiled, failed := shader.compile_source(sw.source)
			if failed == 0 && compiled > 0 {
				reload = true
			} else {
				log.errorf(
					"[HOT] %s: %d compiled, %d failed; keeping the live shaders",
					sw.source,
					compiled,
					failed,
				)
			}
		}
	} else {
		for &ow in h.output_watches {
			if foundation.watch_poll(&ow.watch) {reload = true}
		}
	}
	if !reload {return}

	graphic.renderer_request_shader_reload(h.renderer)
	if h.gpu_solver != nil {
		physics_gpu.gpu_gravity_request_shader_reload(h.gpu_solver)
	}
	log.infof("[HOT] Shader change detected; reload requested")
}
