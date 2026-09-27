package graphic

import "core:dynlib"
import "core:log"

// Headless device creation needs vkGetInstanceProcAddr before any window
// exists, so it cannot use GLFW's loader wrapper (which requires an initialized
// window system). The Vulkan loader is opened at runtime — the same model GLFW
// uses — and kept for the process lifetime: the function tables loaded from it
// stay in use until the last instance/device is destroyed.
@(private)
_g_vulkan_loader: dynlib.Library

@(private)
_g_vk_get_instance_proc_addr: rawptr

@(private)
_load_vulkan_loader :: proc() -> (rawptr, bool) {
	if _g_vk_get_instance_proc_addr != nil {return _g_vk_get_instance_proc_addr, true}

	names: []string
	when ODIN_OS == .Windows {
		names = {"vulkan-1.dll"}
	} else when ODIN_OS == .Darwin {
		names = {"libvulkan.1.dylib", "libvulkan.dylib", "libMoltenVK.dylib"}
	} else {
		names = {"libvulkan.so.1", "libvulkan.so"}
	}

	for name in names {
		library, loaded := dynlib.load_library(name, allocator = context.allocator)
		if !loaded {continue}
		address, found := dynlib.symbol_address(library, "vkGetInstanceProcAddr", context.allocator)
		if !found {
			dynlib.unload_library(library)
			continue
		}
		_g_vulkan_loader = library
		_g_vk_get_instance_proc_addr = address
		log.debugf("[VULKAN]     Loaded Vulkan loader %s", name)
		return address, true
	}

	log.errorf("[VULKAN]     Cannot load a Vulkan loader library")
	return nil, false
}
