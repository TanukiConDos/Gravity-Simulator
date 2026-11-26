package hot

import ecs "engine:ecs"
import foundation "engine:foundation"
import game_api "engine:game_api"
import gfx "engine:graphics/shared"
import "core:dynlib"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// Gameplay hot reload. `game/` is compiled to a shared library in the background
// and swapped in on the physics thread at a fixed-step boundary. The host world
// and the `Game_State` blob survive the swap; library globals do not.
//
// The build runs on its own thread so the main loop never blocks on the Odin
// compiler. A failed build/load logs the compiler output and leaves the running
// library untouched.

GAME_POLL_MS :: 250.0
GAME_BUILD_DIR :: "build"
GAME_PACKAGE :: "game"
// Extra entity slots reserved before `world_freeze`, so gameplay can spawn
// bodies at runtime without growing pool columns.
GAME_SPAWN_HEADROOM :: 1024

@(private)
Game_Library :: struct {
	api_version: proc() -> u32 `dynlib:"game_api_version"`,
	init:        proc(ctx: ^game_api.Game_Context) -> bool `dynlib:"game_init"`,
	reload:      proc(ctx: ^game_api.Game_Context) -> bool `dynlib:"game_reload"`,
	tick:        proc(ctx: ^game_api.Game_Context, dt: f32) `dynlib:"game_tick"`,
	shutdown:    proc(ctx: ^game_api.Game_Context) `dynlib:"game_shutdown"`,
	_lib:        dynlib.Library,
}

// Host wiring the package needs from the application. It deliberately avoids
// importing `package main`: the app supplies its frame-source reseed callback
// and the opaque pointer it wants back.
Host :: struct {
	world:       ^ecs.World,
	input:       ^gfx.Input_State,
	// Called on the physics thread after a spawn/despawn; the app marks its
	// renderer's static columns dirty. `reseed_user` is passed back unchanged.
	reseed:      proc(user: rawptr),
	reseed_user: rawptr,
	// Used by the background build thread (threads start with a default context).
	logger:      log.Logger,
}

Game :: struct {
	enabled:      bool,
	world:        ^ecs.World,
	state:        ^game_api.Game_State,
	input:        ^gfx.Input_State,
	reseed:       proc(user: rawptr),
	reseed_user:  rawptr,
	logger:       log.Logger,
	// Atomic snapshot handed to the library; the raw pointer belongs to the main
	// thread and must not be read field-by-field from the physics thread.
	input_snapshot: gfx.Input_State,

	lib:          Game_Library,
	loaded:       bool,
	first_load:   bool,
	tick_index:   u64,
	current_path: string,

	watches:   [dynamic]foundation.File_Watch,
	last_poll: time.Tick,


	builder:         ^thread.Thread,
	build_mutex:     sync.Mutex,
	build_cond:      sync.Cond,
	build_requested: bool,
	build_stop:      bool,

	pending_mutex: sync.Mutex,
	pending_path:  string,
	pending_ready: bool,

	generation:    int,
	last_revision: u64,
}

game_init :: proc(enabled: bool, host: Host) -> ^Game {
	if !enabled {return nil}
	h := new(Game)
	h.world = host.world
	h.input = host.input
	h.reseed = host.reseed
	h.reseed_user = host.reseed_user
	h.logger = host.logger
	h.enabled = true
	h.first_load = true
	h.last_poll = time.tick_now()
	// Must run before `world_freeze`; the callback-based ABI keeps this resource
	// alive across library swaps.
	h.state = ecs.world_resource(host.world, game_api.Game_State)
	if h.state == nil {
		log.errorf("[GAME] Cannot register Game_State; hot gameplay disabled")
		h.enabled = false
		return h
	}

	_game_watch_dir(h, GAME_PACKAGE)
	_game_watch_dir(h, "engine/game_api")

	if err := os.make_directory(GAME_BUILD_DIR); err != nil &&
	   err != .Exist {
		log.errorf("[GAME] Cannot create %s: %v", GAME_BUILD_DIR, err)
	}

	h.builder = thread.create(_game_builder_thread, .Normal, "game-build")
	h.builder.data = h
	thread.start(h.builder)

	_game_request_build(h)
	log.infof("[GAME] Hot gameplay enabled; building %s in the background", GAME_PACKAGE)
	return h
}

game_destroy :: proc(h: ^Game) {
	if h == nil {return}
	if h.builder != nil {
		sync.lock(&h.build_mutex)
		h.build_stop = true
		sync.cond_signal(&h.build_cond)
		sync.unlock(&h.build_mutex)
		thread.join(h.builder)
		thread.destroy(h.builder)
		h.builder = nil
	}
	if h.loaded {
		ctx := _game_context(h)
		if h.lib.shutdown != nil {h.lib.shutdown(&ctx)}
		if h.lib._lib != nil {dynlib.unload_library(h.lib._lib)}
		h.lib = {}
		h.loaded = false
	}
	for &w in h.watches {delete(w.path)}
	delete(h.watches)
	if len(h.current_path) > 0 {
		_ = os.remove(h.current_path)
		delete(h.current_path)
	}
	delete(h.pending_path)
	free(h)
}

// game_poll runs on the main thread: cheap mtime checks plus a coalesced
// build request. The swap itself happens on the physics thread.
game_poll :: proc(h: ^Game) {
	if h == nil || !h.enabled {return}
	if time.duration_milliseconds(time.tick_diff(h.last_poll, time.tick_now())) < GAME_POLL_MS {
		return
	}
	h.last_poll = time.tick_now()

	changed := false
	for &w in h.watches {
		if foundation.watch_poll(&w) {changed = true}
	}
	if !changed {return}

	sync.lock(&h.build_mutex)
	already := h.build_requested
	if !already {h.build_requested = true}
	sync.unlock(&h.build_mutex)
	if already {return}
	sync.cond_signal(&h.build_cond)
	log.infof("[GAME] source changed; rebuilding")
}

// game_physics_tick runs on the physics thread inside the fixed-step loop.
// It consumes a finished build at a clean boundary, then calls the live tick.
game_physics_tick :: proc(h: ^Game, dt: f32) {
	if h == nil || !h.enabled {return}
	if path := _game_take_pending(h); len(path) > 0 {
		_game_swap(h, path)
	}
	if !h.loaded || h.lib.tick == nil {return}
	h.tick_index += 1
	ctx := _game_context(h)
	h.lib.tick(&ctx, dt)
}

// game_after_flush runs on the physics thread after deferred structural
// changes have been applied. Any spawn/despawn bumps the world revision; refresh
// the renderer's static columns once per changed revision so a body removed by
// `world_flush` stops occupying a draw slot on the next frame.
game_after_flush :: proc(h: ^Game) {
	if h == nil || !h.enabled || !h.loaded || h.reseed == nil {return}
	if h.world.revision == h.last_revision {return}
	h.last_revision = h.world.revision
	h.reseed(h.reseed_user)
}

// --- host callbacks -------------------------------------------------------

@(private)
_game_context :: proc(h: ^Game) -> game_api.Game_Context {
	if h.input != nil {
		h.input_snapshot = gfx.Input_State {
			keys       = sync.atomic_load(&h.input.keys),
			mouse_down = sync.atomic_load(&h.input.mouse_down),
			cursor_u   = sync.atomic_load(&h.input.cursor_u),
			cursor_v   = sync.atomic_load(&h.input.cursor_v),
			fb_width   = sync.atomic_load(&h.input.fb_width),
			fb_height  = sync.atomic_load(&h.input.fb_height),
			fb_valid   = sync.atomic_load(&h.input.fb_valid),
		}
	}
	return game_api.Game_Context {
		abi_version   = game_api.ABI_VERSION,
		world         = h.world,
		config        = foundation.config_get(),
		state         = h.state,
		input         = h.input == nil ? nil : &h.input_snapshot,
		tick          = h.tick_index,
		reseed_render = h.reseed,
		user          = h.reseed_user,
	}
}

// --- watching / building --------------------------------------------------

@(private)
_game_request_build :: proc(h: ^Game) {
	sync.lock(&h.build_mutex)
	h.build_requested = true
	sync.unlock(&h.build_mutex)
	sync.cond_signal(&h.build_cond)
}

@(private)
_game_watch_dir :: proc(h: ^Game, dir: string) {
	files, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		log.warnf("[GAME] Cannot watch %s: %v", dir, err)
		return
	}
	for fi in files {
		if fi.type == .Directory {continue}
		if !strings.has_suffix(fi.name, ".odin") {continue}
		append(&h.watches, foundation.watch_file(strings.clone(fi.fullpath)))
	}
	// The directory's own mtime catches files being added/removed.
	append(&h.watches, foundation.watch_file(strings.clone(dir)))
}

@(private)
_game_builder_thread :: proc(th: ^thread.Thread) {
	h := cast(^Game)th.data
	context.logger = h.logger
	for {
		sync.lock(&h.build_mutex)
		for !h.build_requested && !h.build_stop {
			sync.cond_wait(&h.build_cond, &h.build_mutex)
		}
		if h.build_stop {
			sync.unlock(&h.build_mutex)
			break
		}
		h.build_requested = false
		sync.unlock(&h.build_mutex)

		_game_build_once(h)
	}
}

@(private)
_game_build_once :: proc(h: ^Game) {
	h.generation += 1
	out := fmt.aprintf(
		"%s/game_%d.%s",
		GAME_BUILD_DIR,
		h.generation,
		dynlib.LIBRARY_FILE_EXTENSION,
	)
	tmp := fmt.aprintf("%s.partial", out)
	defer delete(tmp)

	out_flag := strings.concatenate({"-out:", tmp}, context.temp_allocator)
	args := []string {
		"odin",
		"build",
		GAME_PACKAGE,
		"-collection:engine=engine",
		"-build-mode:shared",
		"-debug",
		out_flag,
	}
	start := time.tick_now()
	state, stdout, stderr, err := os.process_exec(
		os.Process_Desc{command = args},
		context.temp_allocator,
	)
	elapsed := time.duration_milliseconds(time.tick_diff(start, time.tick_now()))
	if err != nil {
		log.errorf("[GAME] Cannot run the Odin compiler: %v", err)
		_ = os.remove(tmp)
		delete(out)
		return
	}
	if !state.success {
		if len(stderr) > 0 {
			log.errorf("[GAME] Build failed (%.0f ms):\n%s", elapsed, string(stderr))
		} else {
			log.errorf("[GAME] Build failed (exit %d, %.0f ms)", state.exit_code, elapsed)
		}
		_ = os.remove(tmp)
		delete(out)
		return
	}
	if rename_err := os.rename(tmp, out); rename_err != nil {
		log.errorf("[GAME] Cannot publish %s: %v", out, rename_err)
		_ = os.remove(tmp)
		delete(out)
		return
	}
	if len(stdout) > 0 {log.debugf("[GAME] odin: %s", string(stdout))}

	sync.lock(&h.pending_mutex)
	if h.pending_path != "" {
		_ = os.remove(h.pending_path)
		delete(h.pending_path)
	}
	h.pending_path = out
	h.pending_ready = true
	sync.unlock(&h.pending_mutex)
	log.infof("[GAME] Built %s in %.0f ms", out, elapsed)
}

@(private)
_game_take_pending :: proc(h: ^Game) -> string {
	sync.lock(&h.pending_mutex)
	path := h.pending_path
	h.pending_path = ""
	h.pending_ready = false
	sync.unlock(&h.pending_mutex)
	return path
}

@(private)
_game_swap :: proc(h: ^Game, path: string) {
	next: Game_Library
	count, resolved := dynlib.initialize_symbols(&next, path, "", "_lib")
	if !resolved || count <= 0 {
		log.errorf("[GAME] Cannot load %s; keeping the running library", path)
		if next._lib != nil {dynlib.unload_library(next._lib)}
		delete(path)
		return
	}
	if next.api_version == nil || next.tick == nil {
		log.errorf("[GAME] %s is missing api_version/tick; keeping the running library", path)
		dynlib.unload_library(next._lib)
		delete(path)
		return
	}
	if version := next.api_version(); version != game_api.ABI_VERSION {
		log.errorf(
			"[GAME] ABI mismatch (library %d, host %d); keeping the running library",
			version,
			game_api.ABI_VERSION,
		)
		dynlib.unload_library(next._lib)
		delete(path)
		return
	}

	ctx := _game_context(h)
	accepted := true
	if h.first_load {
		accepted = next.init == nil ? false : next.init(&ctx)
	} else if next.reload != nil {
		accepted = next.reload(&ctx)
	} else if next.init != nil {
		accepted = next.init(&ctx)
	}
	if !accepted {
		log.errorf("[GAME] %s rejected by init/reload; keeping the running library", path)
		dynlib.unload_library(next._lib)
		delete(path)
		return
	}

	old := h.lib
	had_old := h.loaded
	h.lib = next
	h.loaded = true
	h.first_load = false

	if had_old {
		shutdown_ctx := _game_context(h)
		if old.shutdown != nil {old.shutdown(&shutdown_ctx)}
		if old._lib != nil {dynlib.unload_library(old._lib)}
		if len(h.current_path) > 0 {
			_ = os.remove(h.current_path)
			delete(h.current_path)
		}
	}
	h.current_path = path
	log.infof("[GAME] Hot-swapped gameplay library (%s)", path)
}
