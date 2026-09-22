package graphic

import "base:runtime"
import "core:log"
import "vendor:vulkan"

@(private)
_vk_log :: proc(what: string, result: vulkan.Result, loc: runtime.Source_Code_Location) {
	log.errorf("[VULKAN] %s failed: %v (%s:%d)", what, result, loc.file_path, loc.line)
}

// Logs and propagates. Use for creation/allocation the caller can abort on.
@(private)
vk_check :: proc(result: vulkan.Result, what: string, loc := #caller_location) -> bool {
	if result != .SUCCESS {_vk_log(what, result, loc); return false}
	return true
}

// No recovery path: panics in debug, logs in release.
@(private)
vk_assert :: proc(result: vulkan.Result, what: string, loc := #caller_location) {
	when ODIN_DISABLE_ASSERT {
		if result != .SUCCESS {_vk_log(what, result, loc)}
	}
	assert(result == .SUCCESS, what)
}
