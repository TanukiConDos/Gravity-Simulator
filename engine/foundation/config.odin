package foundation

import "core:log"
import "core:strconv"
import "core:strings"
import "core:sync"

Algorithm :: enum {
	BRUTE_FORCE,
	OCTREE,
}

// Which solve runs for the brute-force algorithm: the built-in CPU loop or the
// out-of-package GPU backend. Octree keeps its CPU solve in M1/M2.
Gravity_Backend :: enum {
	CPU,
	GPU,
}

Mode :: enum {
	RANDOM,
	FILE,
}

Config :: struct {
	system_creation_mode:  Mode,
	num_objects:           int,
	time:                  f32,
	filename:              string,
	algorithm:             Algorithm,
	gravity_backend:       Gravity_Backend,
	theta:                 f32,
	tree_rebuild_interval: f32,
	max_depth:             int,
	min_half_size:         f32,
	worker_threads:        int,
	auto_adjust:           bool,
	target_tickrate:       f32,
	theta_min:             f32,
	theta_max:             f32,
	// Development-only reloading (shaders, frame graph, config). On by default in
	// debug builds; an optimized build must opt in.
	hot_reload:            bool,
	// Hot-swaps the gameplay shared library (see engine/game_api). Requires the
	// `game` package and the Odin compiler at runtime.
	hot_game:              bool,
}

@(private)
_CONFIG_DEFAULTS: Config = {
	system_creation_mode  = .FILE,
	num_objects           = 998,
	time                  = 1000,
	filename              = "tierra.json",
	algorithm             = .BRUTE_FORCE,
	gravity_backend       = .CPU,
	theta                 = 0.5,
	tree_rebuild_interval = 50.0,
	max_depth             = 48,
	min_half_size         = 1e-4,
	worker_threads        = 8,
	auto_adjust           = false,
	target_tickrate       = 60.0,
	theta_min             = 0.2,
	theta_max             = 1.2,
	hot_reload            = ODIN_DEBUG,
	hot_game              = false,
}

// The live singleton. Only the main thread writes it during startup; after the
// threads start, only the physics thread replaces it (`config_apply_pending`),
// which also makes it the only reader of the tuning fields.
@(private)
_config: Config = _CONFIG_DEFAULTS

config_get :: proc() -> ^Config {
	return &_config
}

// The `filename` field may point at a heap clone when a config file supplied
// one. Track that so teardown can free it without freeing the default literal.
@(private)
_config_filename_owned: bool

// A reload parsed on the main thread and waiting for the physics thread to
// apply it at a tick boundary. Guarded because the two threads meet here.
@(private)
_config_pending: Config
@(private)
_config_pending_ready: bool
@(private)
_config_pending_mutex: sync.Mutex

// Releases configuration memory. Call once at process teardown (the config is a
// singleton otherwise held for the whole run).
config_destroy :: proc() {
	if _config_filename_owned {
		delete(_config.filename)
		_config_filename_owned = false
	}
	_config = _CONFIG_DEFAULTS
	sync.lock(&_config_pending_mutex)
	if _config_pending_ready {
		delete(_config_pending.filename)
		_config_pending_ready = false
	}
	_config_pending = {}
	sync.unlock(&_config_pending_mutex)
}

config_load :: proc(path: string) -> ^Config {
	data, ok := read_entire_file(path)
	if !ok {
		log.warnf("[CONFIG] File not found: %s — using defaults", path)
		return &_config
	}
	cfg, parsed := config_parse(string(data))
	if !parsed {
		log.warnf("[CONFIG] Cannot parse %s — using defaults", path)
		return &_config
	}
	config_apply(cfg)
	log.infof("[CONFIG] Loaded configuration from %s", path)
	return &_config
}

// config_parse builds a Config from `text`, starting at the defaults. The result
// owns its `filename`; the caller must either apply it or destroy it with
// `config_destroy_value`.
config_parse :: proc(text: string) -> (result: Config, ok: bool) {
	result = _CONFIG_DEFAULTS
	result.filename = strings.clone(_CONFIG_DEFAULTS.filename)
	if !_apply_config(text, &result) {
		config_destroy_value(&result)
		return {}, false
	}
	return result, true
}

config_destroy_value :: proc(cfg: ^Config) {
	if cfg == nil {return}
	delete(cfg.filename)
	cfg.filename = ""
}

// config_apply moves an owned Config into the singleton.
@(private)
config_apply :: proc(cfg: Config) {
	if _config_filename_owned {delete(_config.filename)}
	_config = cfg
	_config_filename_owned = true
}

// config_reload_from_disk parses a new file on the main thread and queues it for
// the physics thread. Parsing into a temporary means a bad file never disturbs
// the running simulation. Returns false if the file could not be read/parsed.
config_reload_from_disk :: proc(path: string) -> bool {
	data, ok := read_entire_file(path)
	if !ok {
		log.warnf("[CONFIG] Reload: file not found: %s", path)
		return false
	}
	cfg, parsed := config_parse(string(data))
	if !parsed {
		log.errorf("[CONFIG] Reload: cannot parse %s; keeping the live config", path)
		return false
	}
	sync.lock(&_config_pending_mutex)
	if _config_pending_ready {delete(_config_pending.filename)}
	_config_pending = cfg
	_config_pending_ready = true
	sync.unlock(&_config_pending_mutex)
	return true
}

// config_apply_pending installs the queued Config on the calling (physics)
// thread and logs fields that only take effect after a restart.
config_apply_pending :: proc() -> bool {
	sync.lock(&_config_pending_mutex)
	if !_config_pending_ready {
		sync.unlock(&_config_pending_mutex)
		return false
	}
	next := _config_pending
	_config_pending = {}
	_config_pending_ready = false
	sync.unlock(&_config_pending_mutex)

	if next.system_creation_mode != _config.system_creation_mode ||
	   next.num_objects != _config.num_objects ||
	   next.filename != _config.filename ||
	   next.algorithm != _config.algorithm ||
	   next.gravity_backend != _config.gravity_backend ||
	   next.worker_threads != _config.worker_threads {
		log.warnf(
			"[CONFIG] Reload changed restart-only fields (scene/algorithm/backend/threads); they apply on the next launch",
		)
	}
	config_apply(next)
	return true
}

@(private)
_apply_config :: proc(text: string, cfg: ^Config) -> bool {
	pos := 0
	_skip_whitespace(text, &pos)
	if pos >= len(text) || text[pos] != '{' {return false}
	pos += 1
	closed := false
	for {
		_skip_whitespace(text, &pos)
		if pos >= len(text) {break}
		if text[pos] == '}' {closed = true; break}
		if text[pos] == ',' {pos += 1; continue}
		key := _parse_string(text, &pos)
		_skip_whitespace(text, &pos)
		if pos < len(text) && text[pos] == ':' {pos += 1}
		switch key {
		case "system_creation_mode":
			mode := _parse_string(text, &pos)
			if mode == "RANDOM" {cfg.system_creation_mode = .RANDOM} else if mode == "FILE" {cfg.system_creation_mode = .FILE}
		case "num_objects":
			value, parsed := _parse_number(text, &pos); if !parsed {return false}
			cfg.num_objects = int(value)
		case "time":
			value, parsed := _parse_number(text, &pos); if !parsed {return false}
			cfg.time = f32(value)
		case "filename":
			filename := _parse_string(text, &pos)
			if len(filename) > 0 {
				delete(cfg.filename)
				cfg.filename = strings.clone(filename)
			}
		case "algorithm":
			algo := _parse_string(text, &pos)
			if algo == "OCTREE" {cfg.algorithm = .OCTREE} else if algo == "BRUTE_FORCE" {cfg.algorithm = .BRUTE_FORCE}
		case "gravity_backend":
			backend := _parse_string(text, &pos)
			if backend == "GPU" {cfg.gravity_backend = .GPU} else if backend == "CPU" {cfg.gravity_backend = .CPU}
		case "theta":
			value, parsed := _parse_number(text, &pos); if !parsed {return false}
			cfg.theta = f32(value)
		case "tree_rebuild_interval":
			value, parsed := _parse_number(text, &pos); if !parsed {return false}
			cfg.tree_rebuild_interval = f32(value)
		case "max_depth":
			value, parsed := _parse_number(text, &pos); if !parsed {return false}
			cfg.max_depth = int(value)
		case "min_half_size":
			value, parsed := _parse_number(text, &pos); if !parsed {return false}
			cfg.min_half_size = f32(value)
		case "worker_threads":
			value, parsed := _parse_number(text, &pos); if !parsed {return false}
			cfg.worker_threads = int(value)
		case "auto_adjust":
			cfg.auto_adjust = _parse_bool(text, &pos)
		case "target_tickrate":
			value, parsed := _parse_number(text, &pos); if !parsed {return false}
			cfg.target_tickrate = f32(value)
		case "theta_min":
			value, parsed := _parse_number(text, &pos); if !parsed {return false}
			cfg.theta_min = f32(value)
		case "theta_max":
			value, parsed := _parse_number(text, &pos); if !parsed {return false}
			cfg.theta_max = f32(value)
		case "hot_reload":
			cfg.hot_reload = _parse_bool(text, &pos)
		case "hot_game":
			cfg.hot_game = _parse_bool(text, &pos)
		case:
			_skip_value(text, &pos)
		}
	}
	return closed
}

@(private)
_skip_whitespace :: proc(text: string, pos: ^int) {for pos^ < len(text) {switch text[pos^] {case ' ','\t','\n','\r': pos^+=1; case: return}}}

@(private)
_parse_string :: proc(text: string, pos: ^int) -> string {_skip_whitespace(text, pos); if pos^>=len(text)||text[pos^]!='"' {return ""}; pos^+=1; start:=pos^; for pos^<len(text)&&text[pos^]!='"' {pos^+=1}; result:=text[start:pos^]; if pos^<len(text){pos^+=1}; return result}

@(private)
_parse_number :: proc(text: string, pos: ^int) -> (f64, bool) {
	_skip_whitespace(text, pos)
	start := pos^
	for pos^ < len(text) {
		c := text[pos^]
		if (c >= '0' && c <= '9') || c == '-' || c == '+' || c == '.' || c == 'e' || c == 'E' {
			pos^ += 1
		} else {
			break
		}
	}
	if start == pos^ {
		log.warnf("[CONFIG] Missing number value")
		return 0, false
	}
	value, parsed := strconv.parse_f64(text[start:pos^])
	if !parsed {
		log.warnf("[CONFIG] Malformed number %q", text[start:pos^])
		return 0, false
	}
	return value, true
}

@(private)
_parse_bool :: proc(text: string, pos: ^int) -> bool {
	_skip_whitespace(text, pos)
	if pos^ >= len(text) {return false}
	if text[pos^] == '"' {return _parse_string(text, pos) == "true"}
	start := pos^
	for pos^ < len(text) {
		c := text[pos^]
		if c == ',' || c == '}' || c == ']' || c == ' ' || c == '\t' || c == '\n' || c == '\r' {break}
		pos^ += 1
	}
	return text[start:pos^] == "true"
}

@(private)
_skip_value :: proc(text: string, pos: ^int) {_skip_whitespace(text,pos); if pos^>=len(text){return}; switch text[pos^] {case '"': _parse_string(text,pos); case '[': depth:=1;pos^+=1; for pos^<len(text)&&depth>0 {switch text[pos^]{case '[': depth+=1; case ']': depth-=1}; pos^+=1}; case '{': depth:=1;pos^+=1; for pos^<len(text)&&depth>0 {switch text[pos^]{case '{': depth+=1; case '}': depth-=1}; pos^+=1}; case: for pos^<len(text) {c:=text[pos^]; if c==','||c=='}'||c==']'||c==' '||c=='\t'||c=='\n'||c=='\r' {break}; pos^+=1}}}
