package shader

import "core:log"
import "core:os"
import "core:strings"

// Single source of truth for the GLSL -> SPIR-V build. The engine's hot-reload
// path and `tools/shader_build` both read this table, so a shader added here is
// compiled by the command line, by the runtime watcher and by the pipeline
// definitions without a second edit.
//
// Paths are relative to the repository root, which is also the process working
// directory the engine assumes for every other asset (`config.json`,
// `engine/graphics/frame_graph.json`, ...).

SHADER_DIR :: "engine/graphics/shader/"
TARGET_ENV :: "vulkan1.4"
TARGET_ENV_FLAG :: "--target-env=" + TARGET_ENV

// One compiled shader. `defines` are passed as `-D<value>` and are how the
// single `tree_build.comp` source becomes six different stages.
Job :: struct {
	name:    string,
	source:  string,
	output:  string,
	defines: []string,
}

JOBS := [?]Job {
	{name = "main.vert", source = "vertexShader.vert", output = "vert.spv"},
	{name = "main.frag", source = "fragmentShader.frag", output = "frag.spv"},
	{name = "compute_probe", source = "compute_probe.comp", output = "compute_probe.spv"},
	{name = "physics_brute", source = "physics_brute.comp", output = "physics_brute.spv"},
	{name = "physics_tree", source = "physics_tree.comp", output = "physics_tree.spv"},
	{name = "instance_pack", source = "instance_pack.comp", output = "instance_pack.spv"},
	{name = "tree_build_0", source = "tree_build.comp", output = "tree_build_0.spv", defines = []string{"TREE_BUILD_STAGE=0"}},
	{name = "tree_build_1", source = "tree_build.comp", output = "tree_build_1.spv", defines = []string{"TREE_BUILD_STAGE=1"}},
	{name = "tree_build_2", source = "tree_build.comp", output = "tree_build_2.spv", defines = []string{"TREE_BUILD_STAGE=2"}},
	{name = "tree_build_3", source = "tree_build.comp", output = "tree_build_3.spv", defines = []string{"TREE_BUILD_STAGE=3"}},
	{name = "tree_build_4", source = "tree_build.comp", output = "tree_build_4.spv", defines = []string{"TREE_BUILD_STAGE=4"}},
	{name = "tree_build_5", source = "tree_build.comp", output = "tree_build_5.spv", defines = []string{"TREE_BUILD_STAGE=5"}},
}

// Every distinct GLSL source. The runtime watcher registers one watch per entry
// and recompiles all jobs that share it.
SOURCES := [?]string {
	"vertexShader.vert",
	"fragmentShader.frag",
	"compute_probe.comp",
	"physics_brute.comp",
	"physics_tree.comp",
	"instance_pack.comp",
	"tree_build.comp",
}

find :: proc(name: string) -> (job: Job, ok: bool) {
	for job in JOBS {
		if job.name == name {return job, true}
	}
	return {}, false
}

// target_env_flag honors VULKAN_TARGET_ENV (the previous build scripts used it)
// and falls back to the manifest's default.
@(private)
target_env_flag :: proc() -> string {
	if env, ok := os.lookup_env("VULKAN_TARGET_ENV", context.temp_allocator); ok && len(env) > 0 {
		return strings.concatenate({"--target-env=", env}, context.temp_allocator)
	}
	return TARGET_ENV_FLAG
}

source_file_path :: proc(source: string) -> string {
	return strings.concatenate({SHADER_DIR, source}, context.temp_allocator)
}

source_path :: proc(job: Job) -> string {
	return source_file_path(job.source)
}

output_path :: proc(job: Job) -> string {
	return strings.concatenate({SHADER_DIR, job.output}, context.temp_allocator)
}

// glslc_available probes the toolchain once. The runtime reloader falls back to
// watching the compiled `.spv` files when it is missing, so an external build
// script still works without shaderc installed in the app's PATH.
glslc_available :: proc() -> bool {
	state, _, _, err := os.process_exec(
		os.Process_Desc{command = []string{"glslc", "--version"}},
		context.temp_allocator,
	)
	return err == nil && state.success
}

// compile rebuilds one job into its canonical `.spv` path. The compiler writes
// a temporary file that is renamed only on success, so a pipeline reload never
// reads a partially written module.
compile :: proc(job: Job) -> bool {
	return compile_to(job, output_path(job))
}

// compile_to writes a job to an arbitrary destination using the same
// temp-then-rename discipline. `compile_source` uses it to stage every stage of
// a multi-output source before publishing any of them.
compile_to :: proc(job: Job, dst: string) -> bool {
	src := source_path(job)
	tmp := strings.concatenate({dst, ".tmp"}, context.temp_allocator)

	args := make([dynamic]string, 0, 4 + len(job.defines), context.temp_allocator)
	append(&args, "glslc")
	append(&args, target_env_flag())
	for define in job.defines {
		append(&args, strings.concatenate({"-D", define}, context.temp_allocator))
	}
	append(&args, src)
	append(&args, "-o")
	append(&args, tmp)

	_ = os.remove(tmp)
	state, _, stderr, err := os.process_exec(os.Process_Desc{command = args[:]}, context.temp_allocator)
	if err != nil {
		log.errorf("[SHADER] Cannot run glslc for %s: %v", job.name, err)
		return false
	}
	if !state.success {
		if len(stderr) > 0 {
			log.errorf("[SHADER] %s failed:\n%s", job.name, string(stderr))
		} else {
			log.errorf("[SHADER] %s failed (glslc exit %d)", job.name, state.exit_code)
		}
		_ = os.remove(tmp)
		return false
	}
	if rename_err := os.rename(tmp, dst); rename_err != nil {
		log.errorf("[SHADER] Cannot publish %s: %v", dst, rename_err)
		_ = os.remove(tmp)
		return false
	}
	return true
}

@(private)
staged_path :: proc(job: Job) -> string {
	return strings.concatenate({output_path(job), ".staged"}, context.temp_allocator)
}

// compile_source rebuilds every job that shares `source`. A source can produce
// several stages (`tree_build.comp`), so all of them are compiled to staging
// files first and only published when the whole set succeeded. A syntax error
// therefore leaves every live `.spv` untouched.
compile_source :: proc(source: string) -> (compiled, failed: int) {
	for job in JOBS {
		if job.source != source {continue}
		_ = os.remove(staged_path(job))
		if !compile_to(job, staged_path(job)) {failed += 1}
	}
	if failed > 0 {
		for job in JOBS {
			if job.source == source {_ = os.remove(staged_path(job))}
		}
		return 0, failed
	}
	for job in JOBS {
		if job.source != source {continue}
		if os.rename(staged_path(job), output_path(job)) == nil {
			compiled += 1
		} else {
			failed += 1
			_ = os.remove(staged_path(job))
		}
	}
	return
}
