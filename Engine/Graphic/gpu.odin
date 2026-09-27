package graphic

import "base:runtime"
import "core:log"
import "vendor:glfw"
import "vendor:vulkan"

@(private)
GPU :: struct {
	instance:                    vulkan.Instance,
	physical_device:             vulkan.PhysicalDevice,
	device:                      vulkan.Device,
	graphics_queue:              vulkan.Queue,
	present_queue:               vulkan.Queue,
	// Compute queue used by the GPU solver and the headless bench context. A
	// dedicated compute family is preferred; otherwise a second queue from the
	// graphics family (or, on single-queue families, the graphics queue itself).
	compute_queue:               vulkan.Queue,
	compute_queue_family_index:  u32,
	compute_queue_is_dedicated:  bool,
	compute_queue_is_shared:     bool,
	has_compute:                 bool,
	compute_timestamp_bits:      u32,
	timestamp_period_ns:         f32,
	device_name:                 [256]u8,
	device_name_len:             int,
	surface:                     vulkan.SurfaceKHR,
	window:                      ^Window,
	graphics_queue_family_index: u32,
	allocator:                   Allocator,
	debug_messenger:             vulkan.DebugUtilsMessengerEXT,
	debug_logger:                log.Logger,
}

@(private)
DEVICE_EXTENSIONS :: []cstring{vulkan.KHR_SWAPCHAIN_EXTENSION_NAME}

// Features the engine relies on. All of them are core in Vulkan 1.3/1.4, so the
// physical device must expose them (no extension fallbacks are implemented).
@(private)
DeviceFeatures :: struct {
	vulkan11:  vulkan.PhysicalDeviceVulkan11Features,
	vulkan12:  vulkan.PhysicalDeviceVulkan12Features,
	vulkan13:  vulkan.PhysicalDeviceVulkan13Features,
	vulkan14:  vulkan.PhysicalDeviceVulkan14Features,
	available: bool,
}

@(private)
gpu_init :: proc(window: ^Window) -> (result: GPU, ok: bool) {
	tmp := GPU{window = window, debug_logger = context.logger}
	committed := false
	defer if !committed {gpu_destroy(&tmp)}

	log.debugf("[VULKAN] GPU initialization...")
	vulkan.load_proc_addresses_global(rawptr(glfw.GetInstanceProcAddress))
	_gpu_create_instance(&tmp, false) or_return
	vulkan.load_proc_addresses_instance(tmp.instance)
	when ODIN_DEBUG {_gpu_create_debug_messenger(&tmp)}
	window_create_surface(window, tmp.instance) or_return
	tmp.surface = window.surface
	_gpu_pick_physical_device(&tmp, false) or_return
	_gpu_create_logical_device(&tmp, false) or_return
	tmp.allocator = allocator_init(tmp.device, tmp.physical_device)
	log.debugf("[VULKAN]   GPU ready")
	committed = true
	return tmp, true
}

// gpu_init_headless creates a device without window or surface for compute-only
// consumers (the bench). The loader's exported vkGetInstanceProcAddr is used
// because GLFW's wrapper requires an initialized window system.
@(private)
gpu_init_headless :: proc() -> (result: GPU, ok: bool) {
	tmp := GPU{debug_logger = context.logger}
	committed := false
	defer if !committed {gpu_destroy(&tmp)}

	log.debugf("[VULKAN] Headless GPU initialization...")
	loader, loader_loaded := _load_vulkan_loader()
	if !loader_loaded {return {}, false}
	vulkan.load_proc_addresses_global(loader)
	_gpu_create_instance(&tmp, true) or_return
	vulkan.load_proc_addresses_instance(tmp.instance)
	when ODIN_DEBUG {_gpu_create_debug_messenger(&tmp)}
	_gpu_pick_physical_device(&tmp, true) or_return
	_gpu_create_logical_device(&tmp, true) or_return
	tmp.allocator = allocator_init(tmp.device, tmp.physical_device)
	if !tmp.has_compute {
		log.errorf("[VULKAN]   Headless context requires a compute queue")
		return {}, false
	}
	log.debugf("[VULKAN]   Headless GPU ready")
	committed = true
	return tmp, true
}

@(private)
gpu_destroy :: proc(self: ^GPU) {
	log.debugf("[VULKAN] Destroying GPU...")
	if self.device != nil {
		vk_assert(vulkan.DeviceWaitIdle(self.device), "vkDeviceWaitIdle")
		allocator_destroy(&self.allocator)
		vulkan.DestroyDevice(self.device, nil)
	}
	when ODIN_DEBUG {
		if self.debug_messenger != 0 {
			vulkan.DestroyDebugUtilsMessengerEXT(self.instance, self.debug_messenger, nil)
		}
	}
	if self.surface != 0 {vulkan.DestroySurfaceKHR(self.instance, self.surface, nil)}
	if self.instance != nil {vulkan.DestroyInstance(self.instance, nil)}
	log.debugf("[VULKAN]   GPU destroyed")
}

@(private)
gpu_wait :: proc(self: ^GPU) {
	if self.device == nil {return}
	vk_assert(vulkan.DeviceWaitIdle(self.device), "vkDeviceWaitIdle")
}

@(private)
gpu_copy_buffer :: proc(self: ^GPU, source, destination: vulkan.Buffer, size: vulkan.DeviceSize, cmd: vulkan.CommandBuffer) {
	copy_region := vulkan.BufferCopy{srcOffset=0,dstOffset=0,size=size}; vulkan.CmdCopyBuffer(cmd, source, destination, 1, &copy_region)
}

@(private)
_gpu_create_instance :: proc(self: ^GPU, headless: bool) -> bool {
	log.debugf("[VULKAN]   Creating Vulkan instance...")

	loader_version: u32
	if vulkan.EnumerateInstanceVersion(&loader_version) == .SUCCESS {
		log.debugf(
			"[VULKAN]     Loader API version: %d.%d.%d",
			loader_version >> 22,
			(loader_version >> 12) & 0x3ff,
			loader_version & 0xfff,
		)
	}

	app_info := vulkan.ApplicationInfo{pApplicationName="Gravity Simulation",applicationVersion=vulkan.MAKE_VERSION(1,0,0),pEngineName="No Engine",engineVersion=vulkan.MAKE_VERSION(1,0,0),apiVersion=vulkan.API_VERSION_1_4}
	app_info.sType = .APPLICATION_INFO

	extension_names := make([dynamic]cstring, 0, 2)
	defer delete(extension_names)
	if !headless {
		// GLFW owns the surface extensions, so they are only requested with a
		// window; a headless instance needs no platform extensions at all.
		glfw_exts := glfw.GetRequiredInstanceExtensions()
		for extension in glfw_exts {append(&extension_names, extension)}
	}
	when ODIN_DEBUG {append(&extension_names, vulkan.EXT_DEBUG_UTILS_EXTENSION_NAME)}
	for extension in extension_names {log.debugf("[VULKAN]     Extension: %s", string(extension))}

	create_info := vulkan.InstanceCreateInfo{sType=.INSTANCE_CREATE_INFO,pApplicationInfo=&app_info,enabledExtensionCount=u32(len(extension_names)),ppEnabledExtensionNames=raw_data(extension_names)}
	log.debugf("[VULKAN]     Calling vkCreateInstance (ext_count=%d, api=1.4)...", len(extension_names))
	if !vk_check(vulkan.CreateInstance(&create_info, nil, &self.instance), "vkCreateInstance") {return false}
	log.debugf("[VULKAN]     Instance created"); return true
}

@(private)
_gpu_create_debug_messenger :: proc(self: ^GPU) {
	messenger_info := vulkan.DebugUtilsMessengerCreateInfoEXT{
		sType           = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
		messageSeverity = {.INFO, .WARNING, .ERROR},
		messageType     = {.GENERAL, .VALIDATION, .PERFORMANCE},
		pfnUserCallback = _debug_utils_callback,
	}
	// A failure here is not fatal: validation output just falls back to stdout.
	if vulkan.CreateDebugUtilsMessengerEXT(self.instance, &messenger_info, nil, &self.debug_messenger) != .SUCCESS {
		log.warnf("[VULKAN]     Failed to create debug utils messenger, falling back to stdout")
	} else {
		log.debugf("[VULKAN]     Debug utils messenger created")
	}
}

// Routes validation/best-practice messages into the engine logger. The layer
// itself is enabled externally (Vulkan Configurator / loader env), never here.
@(private)
_debug_utils_callback :: proc "system" (
	severity: vulkan.DebugUtilsMessageSeverityFlagsEXT,
	types: vulkan.DebugUtilsMessageTypeFlagsEXT,
	data: ^vulkan.DebugUtilsMessengerCallbackDataEXT,
	user_data: rawptr,
) -> b32 {
	context = runtime.default_context()
	if gpu := cast(^GPU)user_data; gpu != nil {context.logger = gpu.debug_logger}
	message := "<no message>"
	if data != nil && data.pMessage != nil {message = string(data.pMessage)}
	switch {
	case .ERROR in severity:   log.errorf("[VULKAN] %s", message)
	case .WARNING in severity: log.warnf("[VULKAN] %s", message)
	case:                      log.infof("[VULKAN] %s", message)
	}
	return false
}

@(private)
SwapChainSupportDetails :: struct {capabilities: vulkan.SurfaceCapabilitiesKHR, formats: [dynamic]vulkan.SurfaceFormatKHR, present_modes: [dynamic]vulkan.PresentModeKHR}
@(private)
QueueFamilyIndices :: struct {
	graphics_family: Maybe(u32),
	present_family:  Maybe(u32),
	compute_family:  Maybe(u32),
	// Which queue inside `compute_family` to fetch. Two when compute shares the
	// graphics family and that family exposes a second queue; zero otherwise.
	compute_queue_index: u32,
	compute_dedicated:   bool,
	// True when the family has only one queue: compute then aliases the graphics
	// queue handle and submissions must not overlap on the host side.
	compute_queue_is_shared: bool,
	compute_timestamp_bits:  u32,
}
@(private)
queue_family_indices_complete :: proc(i: QueueFamilyIndices) -> bool {return i.graphics_family != nil && i.present_family != nil}

@(private)
_gpu_query_features :: proc(device: vulkan.PhysicalDevice) -> (f: DeviceFeatures) {
	f.vulkan11 = vulkan.PhysicalDeviceVulkan11Features{sType = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES}
	f.vulkan12 = vulkan.PhysicalDeviceVulkan12Features{sType = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES}
	f.vulkan13 = vulkan.PhysicalDeviceVulkan13Features{sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES}
	f.vulkan14 = vulkan.PhysicalDeviceVulkan14Features{sType = .PHYSICAL_DEVICE_VULKAN_1_4_FEATURES}
	f.vulkan11.pNext = &f.vulkan12
	f.vulkan12.pNext = &f.vulkan13
	f.vulkan13.pNext = &f.vulkan14
	features2 := vulkan.PhysicalDeviceFeatures2{sType = .PHYSICAL_DEVICE_FEATURES_2, pNext = &f.vulkan11}
	vulkan.GetPhysicalDeviceFeatures2(device, &features2)
	f.available = bool(f.vulkan12.timelineSemaphore) &&
		bool(f.vulkan13.dynamicRendering) && bool(f.vulkan13.synchronization2) &&
		bool(f.vulkan14.pushDescriptor) && bool(f.vulkan14.maintenance5) && bool(f.vulkan14.maintenance6)
	return
}

@(private)
_gpu_pick_physical_device :: proc(self: ^GPU, headless: bool) -> bool {
	log.debugf("[VULKAN]   Picking physical device...")
	count: u32
	if !vk_check(vulkan.EnumeratePhysicalDevices(self.instance, &count, nil), "vkEnumeratePhysicalDevices") {return false}
	if count == 0 {log.errorf("[VULKAN]     No Vulkan-capable GPU found!"); return false}
	log.debugf("[VULKAN]     Found %d device(s)", count)
	devices := make([]vulkan.PhysicalDevice, int(count)); defer delete(devices)
	if !vk_check(vulkan.EnumeratePhysicalDevices(self.instance, &count, raw_data(devices)), "vkEnumeratePhysicalDevices") {return false}
	best_score := 0; best_device: vulkan.PhysicalDevice
	for device in devices {
		score, suitable := _gpu_rate_device(self, device, headless)
		props: vulkan.PhysicalDeviceProperties; vulkan.GetPhysicalDeviceProperties(device, &props)
		name := string(cstring(&props.deviceName[0]))
		if suitable {log.debugf("[VULKAN]       %s - score=%d", name, score); if score>best_score {best_score=score; best_device=device}}
		else {log.debugf("[VULKAN]       %s - skipped", name)}
	}
	if best_score == 0 {log.errorf("[VULKAN]     No suitable GPU found!"); return false}
	self.physical_device = best_device
	props: vulkan.PhysicalDeviceProperties; vulkan.GetPhysicalDeviceProperties(best_device, &props)
	name := string(cstring(&props.deviceName[0]))
	self.device_name_len = min(len(name), len(self.device_name))
	copy(self.device_name[:self.device_name_len], name[:self.device_name_len])
	log.infof("GPU: %v (Vulkan %d.%d.%d)", name, props.apiVersion >> 22, (props.apiVersion >> 12) & 0x3ff, props.apiVersion & 0xfff)
	return true
}

@(private)
_gpu_rate_device :: proc(self: ^GPU, device: vulkan.PhysicalDevice, headless: bool) -> (int, bool) {
	props: vulkan.PhysicalDeviceProperties; vulkan.GetPhysicalDeviceProperties(device, &props)
	features := _gpu_query_features(device)
	if !features.available {return 0, false}
	queue_family := _gpu_find_queue_families(self, device, !headless)
	if headless {
		// A headless context only needs a compute queue.
		if queue_family.compute_family == nil {return 0, false}
	} else if !queue_family_indices_complete(queue_family) {return 0, false}
	if !headless {
		if !_gpu_check_device_extensions(device) {return 0, false}
		swapchain_support := _gpu_query_swap_chain_support(self, device); defer {delete(swapchain_support.formats); delete(swapchain_support.present_modes)}
		if len(swapchain_support.formats)==0||len(swapchain_support.present_modes)==0 {return 0, false}
	}
	score := int(props.limits.maxImageDimension2D); if props.deviceType==.DISCRETE_GPU {score+=1000}
	return score, true
}

@(private)
Queue_Request :: struct {
	family: u32,
	count:  u32,
}

@(private)
_add_queue_request :: proc(requests: ^[dynamic]Queue_Request, family: u32, count: u32) {
	for &request in requests {
		if request.family != family {continue}
		if count > request.count {request.count = count}
		return
	}
	append(requests, Queue_Request{family = family, count = count})
}

@(private)
_gpu_create_logical_device :: proc(self: ^GPU, headless: bool) -> bool {
	log.debugf("[VULKAN]   Creating logical device...")
	features := _gpu_query_features(self.physical_device)
	if !features.available {
		log.errorf("[VULKAN]     Device is missing required Vulkan 1.3/1.4 core features")
		return false
	}

	indices := _gpu_find_queue_families(self, self.physical_device, !headless)
	if indices.graphics_family == nil && !headless {
		log.errorf("[VULKAN]     Device has no graphics queue family")
		return false
	}
	if headless && indices.compute_family == nil {
		log.errorf("[VULKAN]     Device has no compute queue family")
		return false
	}

	// One queue per family by default; the graphics family gets a second queue
	// when compute has to share it, so the two threads submit to distinct queues.
	requests: [dynamic]Queue_Request; defer delete(requests)
	if graphics := indices.graphics_family; graphics != nil {_add_queue_request(&requests, graphics.?, 1)}
	if present := indices.present_family; present != nil {_add_queue_request(&requests, present.?, 1)}
	if compute := indices.compute_family; compute != nil {
		if indices.compute_dedicated {
			_add_queue_request(&requests, compute.?, 1)
		} else if !indices.compute_queue_is_shared {
			_add_queue_request(&requests, compute.?, 2)
		}
	}

	queue_priorities := [2]f32{1.0, 1.0}
	queue_infos: [dynamic]vulkan.DeviceQueueCreateInfo; defer delete(queue_infos)
	for request in requests {
		append(&queue_infos, vulkan.DeviceQueueCreateInfo{sType=.DEVICE_QUEUE_CREATE_INFO,queueFamilyIndex=request.family,queueCount=request.count,pQueuePriorities=&queue_priorities[0]})
	}

	// Chained core-feature structs replace the deprecated pEnabledFeatures field.
	features11 := vulkan.PhysicalDeviceVulkan11Features{sType = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES}
	features12 := vulkan.PhysicalDeviceVulkan12Features{sType = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, timelineSemaphore = true}
	features13 := vulkan.PhysicalDeviceVulkan13Features{sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES, dynamicRendering = true, synchronization2 = true}
	features14 := vulkan.PhysicalDeviceVulkan14Features{sType = .PHYSICAL_DEVICE_VULKAN_1_4_FEATURES, pushDescriptor = true, maintenance5 = true, maintenance6 = true}
	features11.pNext = &features12; features12.pNext = &features13; features13.pNext = &features14

	// A headless device never presents, so the swapchain extension is not
	// requested there.
	enabled_extension_count: u32
	enabled_extension_names: [^]cstring
	if !headless {
		enabled_extension_count = u32(len(DEVICE_EXTENSIONS))
		enabled_extension_names = raw_data(DEVICE_EXTENSIONS)
	}
	create_info := vulkan.DeviceCreateInfo{sType=.DEVICE_CREATE_INFO,pNext=&features11,queueCreateInfoCount=u32(len(queue_infos)),pQueueCreateInfos=raw_data(queue_infos),enabledExtensionCount=enabled_extension_count,ppEnabledExtensionNames=enabled_extension_names}
	if !vk_check(vulkan.CreateDevice(self.physical_device, &create_info, nil, &self.device), "vkCreateDevice") {return false}
	log.debugf("[VULKAN]     Logical device created")
	vulkan.load_proc_addresses_device(self.device)
	if graphics := indices.graphics_family; graphics != nil {
		self.graphics_queue_family_index = graphics.?
		vulkan.GetDeviceQueue(self.device, graphics.?, 0, &self.graphics_queue)
	}
	if present := indices.present_family; present != nil {
		vulkan.GetDeviceQueue(self.device, present.?, 0, &self.present_queue)
	}
	if compute := indices.compute_family; compute != nil {
		self.has_compute = true
		self.compute_queue_family_index = compute.?
		self.compute_queue_is_dedicated = indices.compute_dedicated
		self.compute_queue_is_shared = indices.compute_queue_is_shared
		self.compute_timestamp_bits = indices.compute_timestamp_bits
		if indices.compute_queue_is_shared {
			self.compute_queue = self.graphics_queue
		} else {
			vulkan.GetDeviceQueue(self.device, compute.?, indices.compute_queue_index, &self.compute_queue)
		}
		props: vulkan.PhysicalDeviceProperties; vulkan.GetPhysicalDeviceProperties(self.physical_device, &props)
		self.timestamp_period_ns = props.limits.timestampPeriod
		log.debugf(
			"[VULKAN]     Compute queue family: %d (index %d, %s)",
			compute.?,
			indices.compute_queue_index,
			"dedicated" if indices.compute_dedicated else "shared family",
		)
	} else {
		log.warnf("[VULKAN]     No compute queue family found; GPU compute unavailable")
	}
	log.debugf("[VULKAN]     Graphics queue family: %v  Present queue family: %v", indices.graphics_family, indices.present_family)
	return true
}

@(private)
_gpu_check_device_extensions :: proc(device: vulkan.PhysicalDevice) -> bool {
	count: u32
	if !vk_check(vulkan.EnumerateDeviceExtensionProperties(device, nil, &count, nil), "vkEnumerateDeviceExtensionProperties") {return false}
	available_extensions := make([]vulkan.ExtensionProperties, int(count)); defer delete(available_extensions)
	if !vk_check(vulkan.EnumerateDeviceExtensionProperties(device, nil, &count, raw_data(available_extensions)), "vkEnumerateDeviceExtensionProperties") {return false}
	required_extensions: map[string]bool; defer delete(required_extensions)
	for extension in DEVICE_EXTENSIONS {required_extensions[string(extension)] = true}
	for extension in available_extensions {name := extension.extensionName; delete_key(&required_extensions, string(cstring(&name[0])))}
	return len(required_extensions) == 0
}

@(private)
_gpu_query_swap_chain_support :: proc(self: ^GPU, device: vulkan.PhysicalDevice) -> SwapChainSupportDetails {
	details: SwapChainSupportDetails
	vk_assert(vulkan.GetPhysicalDeviceSurfaceCapabilitiesKHR(device, self.window.surface, &details.capabilities), "vkGetPhysicalDeviceSurfaceCapabilitiesKHR")
	format_count: u32; vk_assert(vulkan.GetPhysicalDeviceSurfaceFormatsKHR(device, self.window.surface, &format_count, nil), "vkGetPhysicalDeviceSurfaceFormatsKHR")
	if format_count>0 {details.formats=make([dynamic]vulkan.SurfaceFormatKHR, int(format_count)); vk_assert(vulkan.GetPhysicalDeviceSurfaceFormatsKHR(device,self.window.surface,&format_count,raw_data(details.formats)), "vkGetPhysicalDeviceSurfaceFormatsKHR")}
	mode_count: u32; vk_assert(vulkan.GetPhysicalDeviceSurfacePresentModesKHR(device, self.window.surface, &mode_count, nil), "vkGetPhysicalDeviceSurfacePresentModesKHR")
	if mode_count>0 {details.present_modes=make([dynamic]vulkan.PresentModeKHR, int(mode_count)); vk_assert(vulkan.GetPhysicalDeviceSurfacePresentModesKHR(device,self.window.surface,&mode_count,raw_data(details.present_modes)), "vkGetPhysicalDeviceSurfacePresentModesKHR")}
	return details
}

// _gpu_find_queue_families scans every family (no early exit, so the compute
// policy sees all candidates) and picks the compute queue: a dedicated
// compute-only family if there is one, otherwise a queue from the graphics
// family when it supports compute.
@(private)
_gpu_find_queue_families :: proc(self: ^GPU, device: vulkan.PhysicalDevice, has_surface: bool) -> QueueFamilyIndices {
	indices: QueueFamilyIndices
	count: u32; vulkan.GetPhysicalDeviceQueueFamilyProperties(device, &count, nil)
	families := make([]vulkan.QueueFamilyProperties, int(count)); defer delete(families)
	vulkan.GetPhysicalDeviceQueueFamilyProperties(device, &count, raw_data(families))

	for family, i in families {
		if .GRAPHICS in family.queueFlags && indices.graphics_family == nil {
			indices.graphics_family = u32(i)
		}
		if has_surface && indices.present_family == nil {
			present_support: b32
			vk_assert(vulkan.GetPhysicalDeviceSurfaceSupportKHR(device, u32(i), self.window.surface, &present_support), "vkGetPhysicalDeviceSurfaceSupportKHR")
			if present_support {indices.present_family = u32(i)}
		}
	}

	for family, i in families {
		if .COMPUTE in family.queueFlags && .GRAPHICS not_in family.queueFlags {
			indices.compute_family = u32(i)
			indices.compute_dedicated = true
			indices.compute_timestamp_bits = family.timestampValidBits
			break
		}
	}
	if indices.compute_family == nil {
		if graphics := indices.graphics_family; graphics != nil {
			family := families[graphics.?]
			if .COMPUTE in family.queueFlags {
				indices.compute_family = graphics.?
				indices.compute_timestamp_bits = family.timestampValidBits
				if family.queueCount >= 2 {
					indices.compute_queue_index = 1
				} else {
					indices.compute_queue_is_shared = true
				}
			}
		}
	}
	return indices
}
