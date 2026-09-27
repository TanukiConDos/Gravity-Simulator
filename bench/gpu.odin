// Headless GPU plumbing stage.
//
// Creates a windowless compute context and runs the transfer -> dispatch ->
// transfer probe, verifying the result and reporting the dispatch cost plus the
// host submit->wait round trip (the latency floor a GPU physics solver pays per
// tick).
//
// Usage:
//   odin run bench -o:speed -- gpu [elements] [dispatches] [samples]
package main

import graphic "../Engine/Graphic"
import "core:fmt"
import "core:log"
import "core:os"

gpu_run :: proc(args: []string) {
	// The bench itself only prints via fmt; the engine reports Vulkan failures
	// through the logger, so give the stage one instead of swallowing them.
	context.logger = log.create_console_logger(.Info)
	elements := 1_000_000
	iterations := 100
	samples := 7
	if len(args) > 0 {elements = _arg_int(args[0], elements)}
	if len(args) > 1 {iterations = _arg_int(args[1], iterations)}
	if len(args) > 2 {samples = _arg_int(args[2], samples)}

	compute, created := graphic.compute_init_headless()
	if !created {
		fmt.eprintln("gpu: cannot create a headless compute context")
		os.exit(1)
	}
	defer graphic.compute_destroy(compute)

	info := graphic.compute_info(compute)
	probe, ran := graphic.compute_probe(compute, elements, iterations, samples)
	if !ran {
		fmt.eprintln("gpu: compute probe failed")
		os.exit(1)
	}

	fmt.printfln(
		"=== gpu probe: device=%s compute_queue=%s ===",
		info.device_name,
		info.dedicated_queue ? "dedicated" : "shared family",
	)
	fmt.printfln(
		"  elements=%d dispatches/sample=%d samples=%d (one f32 in, one f32 out per element)",
		probe.elements,
		probe.iterations,
		probe.samples,
	)
	if probe.gpu_time_available {
		fmt.printfln(
			"  gpu:       %.4f ms/dispatch (%.3f us per 1k elements, timestamp resolution %.1f ns)",
			probe.gpu_ms_per_iteration,
			probe.gpu_ms_per_iteration * 1e6 / f64(elements),
			info.timestamp_period_ns,
		)
	} else {
		fmt.printfln("  gpu:       timestamp queries unavailable")
	}
	fmt.printfln(
		"  roundtrip: %.4f ms host submit->wait for %d dispatches",
		probe.roundtrip_ms,
		probe.iterations,
	)
	fmt.printfln("  verified:  %s", probe.verified ? "ok" : "FAILED")
	if !probe.verified {os.exit(1)}
}
