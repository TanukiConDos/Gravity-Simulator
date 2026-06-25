package foundation

Algorithm :: enum {
	BRUTE_FORCE,
	OCTREE,
}

Mode :: enum {
	RANDOM,
	FILE,
}

Config :: struct {
	system_creation_mode: Mode,
	num_objects:          int,
	time:                 f32,
	filename:             string,
	collision_algorithm:  Algorithm,
	solver_algorithm:     Algorithm,
}

@(private)
_config: Config = {
	system_creation_mode = .FILE,
	num_objects          = 998,
	time                 = 1000,
	filename             = "tierra.json",
	collision_algorithm  = .BRUTE_FORCE,
	solver_algorithm     = .BRUTE_FORCE,
}

config_get :: proc() -> ^Config {
	return &_config
}
