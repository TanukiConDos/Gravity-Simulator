package main

import shader "engine:graphics/shader"
import "core:fmt"
import "core:os"

// Builds the shader jobs declared in `engine/graphics/shader/manifest.odin`.
//
// Usage (from the repository root):
//   odin run tools/shader_build -collection:engine=engine --            # all jobs
//   odin run tools/shader_build -collection:engine=engine -- tree_build_3
//
// `shader/build.sh` and `compilar.bat` forward to this tool so the shell build,
// the command line and the runtime hot reload share one job table.
main :: proc() {
	args := os.args[1:]
	if len(args) == 0 {
		compiled, failed := 0, 0
		for job in shader.JOBS {
			if shader.compile(job) {compiled += 1} else {failed += 1}
		}
		fmt.printfln("shaders: %d compiled, %d failed", compiled, failed)
		if failed > 0 {os.exit(1)}
		return
	}

	failed := 0
	for name in args {
		job, found := shader.find(name)
		if !found {
			fmt.eprintfln("unknown shader job %q", name)
			failed += 1
			continue
		}
		if !shader.compile(job) {failed += 1}
	}
	if failed > 0 {os.exit(1)}
}
