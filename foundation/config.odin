package foundation

import "core:log"
import "core:strconv"
import "core:strings"

Algorithm :: enum {
	BRUTE_FORCE,
	OCTREE,
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
	collision_algorithm:   Algorithm,
	solver_algorithm:      Algorithm,
	theta:                 f32,
	tree_rebuild_interval: f32,
}

@(private)
_config: Config = {
	system_creation_mode  = .FILE,
	num_objects           = 998,
	time                  = 1000,
	filename              = "tierra.json",
	collision_algorithm   = .BRUTE_FORCE,
	solver_algorithm      = .BRUTE_FORCE,
	theta                 = 0.5,
	tree_rebuild_interval = 50.0,
}

config_get :: proc() -> ^Config {
	return &_config
}

config_load :: proc(path: string) -> ^Config {
	data, ok := read_entire_file(path)
	if !ok {
		log.warnf("[CONFIG] File not found: %s — using defaults", path)
		return &_config
	}
	text := string(data)
	_apply_config(text)
	log.infof("[CONFIG] Loaded configuration from %s", path)
	return &_config
}

@(private)
_apply_config :: proc(text: string) {
	pos := 0
	_skip_whitespace(text, &pos)
	if pos >= len(text) || text[pos] != '{' {return}
	pos += 1
	for {
		_skip_whitespace(text, &pos); if pos >= len(text) {break}
		if text[pos] == '}' {break}
		if text[pos] == ',' {pos += 1; continue}
		key := _parse_string(text, &pos)
		_skip_whitespace(text, &pos)
		if pos < len(text) && text[pos] == ':' {pos += 1}
		switch key {
		case "system_creation_mode":
			mode := _parse_string(text, &pos)
			if mode == "RANDOM" {_config.system_creation_mode = .RANDOM} else if mode == "FILE" {_config.system_creation_mode = .FILE}
		case "num_objects":
			_config.num_objects = int(_parse_number(text, &pos))
		case "time":
			_config.time = f32(_parse_number(text, &pos))
		case "filename":
			_config.filename = strings.clone(_parse_string(text, &pos))
		case "collision_algorithm":
			algo := _parse_string(text, &pos)
			if algo == "OCTREE" {_config.collision_algorithm = .OCTREE} else if algo == "BRUTE_FORCE" {_config.collision_algorithm = .BRUTE_FORCE}
		case "solver_algorithm":
			algo := _parse_string(text, &pos)
			if algo == "OCTREE" {_config.solver_algorithm = .OCTREE} else if algo == "BRUTE_FORCE" {_config.solver_algorithm = .BRUTE_FORCE}
		case "theta":
			_config.theta = f32(_parse_number(text, &pos))
		case "tree_rebuild_interval":
			_config.tree_rebuild_interval = f32(_parse_number(text, &pos))
		case:
			_skip_value(text, &pos)
		}
	}
}

@(private)
_skip_whitespace :: proc(text: string, pos: ^int) {for pos^ < len(text) {switch text[pos^] {case ' ','\t','\n','\r': pos^+=1; case: return}}}

@(private)
_parse_string :: proc(text: string, pos: ^int) -> string {_skip_whitespace(text, pos); if pos^>=len(text)||text[pos^]!='"' {return ""}; pos^+=1; start:=pos^; for pos^<len(text)&&text[pos^]!='"' {pos^+=1}; result:=text[start:pos^]; if pos^<len(text){pos^+=1}; return result}

@(private)
_parse_number :: proc(text: string, pos: ^int) -> f64 {_skip_whitespace(text, pos); start:=pos^; for pos^<len(text) {c:=text[pos^]; if (c>='0'&&c<='9')||c=='-'||c=='+'||c=='.'||c=='e'||c=='E' {pos^+=1} else {break}}; val,_:=strconv.parse_f64(text[start:pos^]); return val}

@(private)
_skip_value :: proc(text: string, pos: ^int) {_skip_whitespace(text,pos); if pos^>=len(text){return}; switch text[pos^] {case '"': _parse_string(text,pos); case '[': depth:=1;pos^+=1; for pos^<len(text)&&depth>0 {switch text[pos^]{case '[': depth+=1; case ']': depth-=1}; pos^+=1}; case '{': depth:=1;pos^+=1; for pos^<len(text)&&depth>0 {switch text[pos^]{case '{': depth+=1; case '}': depth-=1}; pos^+=1}; case: for pos^<len(text) {c:=text[pos^]; if c==','||c=='}'||c==']'||c==' '||c=='\t'||c=='\n'||c=='\r' {break}; pos^+=1}}}
