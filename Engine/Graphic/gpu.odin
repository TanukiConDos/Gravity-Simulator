package graphic

import "core:c"
import "core:log"
import "vendor:glfw"
import "vendor:vulkan"

GPU :: struct {
	instance:                   vulkan.Instance,
	physical_device:            vulkan.PhysicalDevice,
	device:                     vulkan.Device,
	graphics_queue:             vulkan.Queue,
	present_queue:              vulkan.Queue,
	surface:                    vulkan.SurfaceKHR,
	window:                     ^Window,
	graphics_queue_family_index: u32,
}

DEVICE_EXTENSIONS :: []cstring{vulkan.KHR_SWAPCHAIN_EXTENSION_NAME}

gpu_create :: proc(window: ^Window) -> (g: GPU, ok: bool) {
	g.window = window
	log.debugf("[VULKAN] GPU initialization...")
	vulkan.load_proc_addresses_global(rawptr(glfw.GetInstanceProcAddress))
	if !_gpu_create_instance(&g) {return {}, false}
	if !window_create_surface(window, g.instance) {return {}, false}
	g.surface = window.surface
	vulkan.load_proc_addresses_instance(g.instance)
	if !_gpu_pick_physical_device(&g) {return {}, false}
	if !_gpu_create_logical_device(&g) {return {}, false}
	log.debugf("[VULKAN]   GPU ready")
	return g, true
}

gpu_destroy :: proc(self: ^GPU) {
	log.debugf("[VULKAN] Destroying GPU...")
	if self.device != nil {vulkan.DeviceWaitIdle(self.device); vulkan.DestroyDevice(self.device, nil)}
	if self.surface != 0 {vulkan.DestroySurfaceKHR(self.instance, self.surface, nil)}
	if self.instance != nil {vulkan.DestroyInstance(self.instance, nil)}
	log.debugf("[VULKAN]   GPU destroyed")
}

gpu_wait :: proc(self: ^GPU) {vulkan.DeviceWaitIdle(self.device)}

gpu_find_memory_type :: proc(self: ^GPU, type_filter: u32, properties: vulkan.MemoryPropertyFlags) -> (u32, bool) {
	mem_properties: vulkan.PhysicalDeviceMemoryProperties; vulkan.GetPhysicalDeviceMemoryProperties(self.physical_device, &mem_properties)
	for i in 0..<mem_properties.memoryTypeCount {if (type_filter & (1<<i)) != 0 && (mem_properties.memoryTypes[i].propertyFlags & properties) == properties {return i, true}}
	return 0, false
}

gpu_create_buffer :: proc(self: ^GPU, size: vulkan.DeviceSize, usage: vulkan.BufferUsageFlags, props: vulkan.MemoryPropertyFlags) -> (vulkan.Buffer, vulkan.DeviceMemory, bool) {
	buf_info := vulkan.BufferCreateInfo{sType=.BUFFER_CREATE_INFO,size=size,usage=usage,sharingMode=.EXCLUSIVE}
	buffer: vulkan.Buffer
	memory: vulkan.DeviceMemory
	if vulkan.CreateBuffer(self.device, &buf_info, nil, &buffer) != .SUCCESS {return {}, {}, false}
	mem_reqs: vulkan.MemoryRequirements; vulkan.GetBufferMemoryRequirements(self.device, buffer, &mem_reqs)
	idx, found := gpu_find_memory_type(self, mem_reqs.memoryTypeBits, props); if !found {return {}, {}, false}
	alloc := vulkan.MemoryAllocateInfo{sType=.MEMORY_ALLOCATE_INFO,allocationSize=mem_reqs.size,memoryTypeIndex=idx}
	if vulkan.AllocateMemory(self.device, &alloc, nil, &memory) != .SUCCESS {return {}, {}, false}
	vulkan.BindBufferMemory(self.device, buffer, memory, 0)
	return buffer, memory, true
}

gpu_copy_buffer :: proc(self: ^GPU, source, destination: vulkan.Buffer, size: vulkan.DeviceSize, cmd: vulkan.CommandBuffer) {
	copy_region := vulkan.BufferCopy{srcOffset=0,dstOffset=0,size=size}; vulkan.CmdCopyBuffer(cmd, source, destination, 1, &copy_region)
}

gpu_get_queue_family :: proc(self: ^GPU) -> u32 {return self.graphics_queue_family_index}

@(private) _gpu_create_instance :: proc(self: ^GPU) -> bool {
	log.debugf("[VULKAN]   Creating Vulkan instance...")
	app_info := vulkan.ApplicationInfo{sType=.APPLICATION_INFO,pApplicationName="Gravity Simulation",applicationVersion=vulkan.MAKE_VERSION(1,0,0),pEngineName="No Engine",engineVersion=vulkan.MAKE_VERSION(1,0,0),apiVersion=vulkan.API_VERSION_1_1}
		glfw_exts := glfw.GetRequiredInstanceExtensions(); extension_count := len(glfw_exts); extension_names := make([dynamic]cstring, extension_count); defer delete(extension_names)
		for extension,i in glfw_exts {extension_names[i]=extension; log.debugf("[VULKAN]     Extension: %s", string(extension))}
		create_info := vulkan.InstanceCreateInfo{sType=.INSTANCE_CREATE_INFO,pApplicationInfo=&app_info,enabledExtensionCount=u32(extension_count),ppEnabledExtensionNames=raw_data(extension_names)}
	log.debugf("[VULKAN]     Calling vkCreateInstance (ext_count=%d)...", extension_count)
	result := vulkan.CreateInstance(&create_info, nil, &self.instance); log.debugf("[VULKAN]     vkCreateInstance returned: %v", result)
	if result != .SUCCESS {log.errorf("[VULKAN]     FAILED: vkCreateInstance (result=%v)", result); return false}
	log.debugf("[VULKAN]     Instance created"); return true
}

SwapChainSupportDetails :: struct {capabilities: vulkan.SurfaceCapabilitiesKHR, formats: [dynamic]vulkan.SurfaceFormatKHR, present_modes: [dynamic]vulkan.PresentModeKHR}
QueueFamilyIndices :: struct {graphics_family: Maybe(u32), present_family: Maybe(u32)}
queue_family_indices_complete :: proc(i: QueueFamilyIndices) -> bool {return i.graphics_family != nil && i.present_family != nil}

@(private) _gpu_pick_physical_device :: proc(self: ^GPU) -> bool {
	log.debugf("[VULKAN]   Picking physical device...")
	count: u32; vulkan.EnumeratePhysicalDevices(self.instance, &count, nil)
	if count == 0 {log.errorf("[VULKAN]     No Vulkan-capable GPU found!"); return false}
	log.debugf("[VULKAN]     Found %d device(s)", count)
	devices := make([]vulkan.PhysicalDevice, int(count)); defer delete(devices)
	vulkan.EnumeratePhysicalDevices(self.instance, &count, raw_data(devices))
	best_score := 0; best_device: vulkan.PhysicalDevice
	for device in devices {
		score, suitable := _gpu_rate_device(self, device)
		props: vulkan.PhysicalDeviceProperties; vulkan.GetPhysicalDeviceProperties(device, &props)
		name := string(cstring(&props.deviceName[0]))
		if suitable {log.debugf("[VULKAN]       %s - score=%d", name, score); if score>best_score {best_score=score; best_device=device}}
		else {log.debugf("[VULKAN]       %s - skipped", name)}
	}
	if best_score == 0 {log.errorf("[VULKAN]     No suitable GPU found!"); return false}
	self.physical_device = best_device
	props: vulkan.PhysicalDeviceProperties; vulkan.GetPhysicalDeviceProperties(best_device, &props)
	log.infof("GPU: %v", string(cstring(&props.deviceName[0])))
	return true
}

@(private) _gpu_rate_device :: proc(self: ^GPU, device: vulkan.PhysicalDevice) -> (int, bool) {
	props: vulkan.PhysicalDeviceProperties; features: vulkan.PhysicalDeviceFeatures
	vulkan.GetPhysicalDeviceProperties(device, &props); vulkan.GetPhysicalDeviceFeatures(device, &features)
	if !features.geometryShader {return 0, false}
	queue_family := _gpu_find_queue_families(self, device); if !queue_family_indices_complete(queue_family) {return 0, false}
	if !_gpu_check_device_extensions(device) {return 0, false}
	swapchain_support := _gpu_query_swap_chain_support(self, device); defer {delete(swapchain_support.formats); delete(swapchain_support.present_modes)}
	if len(swapchain_support.formats)==0||len(swapchain_support.present_modes)==0 {return 0, false}
	score := int(props.limits.maxImageDimension2D); if props.deviceType==.DISCRETE_GPU {score+=1000}
	return score, true
}

@(private) _gpu_create_logical_device :: proc(self: ^GPU) -> bool {
	log.debugf("[VULKAN]   Creating logical device...")
	indices := _gpu_find_queue_families(self, self.physical_device)
	unique_families: map[u32]struct{}; defer delete(unique_families); unique_families[indices.graphics_family.?]={}; unique_families[indices.present_family.?]={}
	queue_priority: f32 = 1.0; queue_infos: [dynamic]vulkan.DeviceQueueCreateInfo; defer delete(queue_infos)
	for family in unique_families {append(&queue_infos, vulkan.DeviceQueueCreateInfo{sType=.DEVICE_QUEUE_CREATE_INFO,queueFamilyIndex=family,queueCount=1,pQueuePriorities=&queue_priority})}
	device_features: vulkan.PhysicalDeviceFeatures
	create_info := vulkan.DeviceCreateInfo{sType=.DEVICE_CREATE_INFO,queueCreateInfoCount=u32(len(queue_infos)),pQueueCreateInfos=raw_data(queue_infos),pEnabledFeatures=&device_features,enabledExtensionCount=u32(len(DEVICE_EXTENSIONS)),ppEnabledExtensionNames=raw_data(DEVICE_EXTENSIONS)}
	if vulkan.CreateDevice(self.physical_device, &create_info, nil, &self.device) != .SUCCESS {log.errorf("[VULKAN]     FAILED: vkCreateDevice"); return false}
	log.debugf("[VULKAN]     Logical device created")
	vulkan.load_proc_addresses_device(self.device)
	self.graphics_queue_family_index = indices.graphics_family.?
	vulkan.GetDeviceQueue(self.device, indices.graphics_family.?, 0, &self.graphics_queue)
	vulkan.GetDeviceQueue(self.device, indices.present_family.?, 0, &self.present_queue)
	log.debugf("[VULKAN]     Graphics queue family: %d  Present queue family: %d", indices.graphics_family.?, indices.present_family.?)
	return true
}

@(private) _gpu_check_device_extensions :: proc(device: vulkan.PhysicalDevice) -> bool {
	count: u32; vulkan.EnumerateDeviceExtensionProperties(device, nil, &count, nil)
	available_extensions := make([]vulkan.ExtensionProperties, int(count)); defer delete(available_extensions)
	vulkan.EnumerateDeviceExtensionProperties(device, nil, &count, raw_data(available_extensions))
	required_extensions: map[string]bool; defer delete(required_extensions)
	for extension in DEVICE_EXTENSIONS {required_extensions[string(extension)] = true}
	for extension in available_extensions {name := extension.extensionName; delete_key(&required_extensions, string(cstring(&name[0])))}
	return len(required_extensions) == 0
}

@(private) _gpu_query_swap_chain_support :: proc(self: ^GPU, device: vulkan.PhysicalDevice) -> SwapChainSupportDetails {
	details: SwapChainSupportDetails
	vulkan.GetPhysicalDeviceSurfaceCapabilitiesKHR(device, self.window.surface, &details.capabilities)
	format_count: u32; vulkan.GetPhysicalDeviceSurfaceFormatsKHR(device, self.window.surface, &format_count, nil)
	if format_count>0 {details.formats=make([dynamic]vulkan.SurfaceFormatKHR, int(format_count)); vulkan.GetPhysicalDeviceSurfaceFormatsKHR(device,self.window.surface,&format_count,raw_data(details.formats))}
	mode_count: u32; vulkan.GetPhysicalDeviceSurfacePresentModesKHR(device, self.window.surface, &mode_count, nil)
	if mode_count>0 {details.present_modes=make([dynamic]vulkan.PresentModeKHR, int(mode_count)); vulkan.GetPhysicalDeviceSurfacePresentModesKHR(device,self.window.surface,&mode_count,raw_data(details.present_modes))}
	return details
}

@(private) _gpu_find_queue_families :: proc(self: ^GPU, device: vulkan.PhysicalDevice) -> QueueFamilyIndices {
	indices: QueueFamilyIndices
	count: u32; vulkan.GetPhysicalDeviceQueueFamilyProperties(device, &count, nil)
	families := make([]vulkan.QueueFamilyProperties, int(count)); defer delete(families)
	vulkan.GetPhysicalDeviceQueueFamilyProperties(device, &count, raw_data(families))
	for family,i in families {
		if .GRAPHICS in family.queueFlags {indices.graphics_family = u32(i)}
		present_support: b32; vulkan.GetPhysicalDeviceSurfaceSupportKHR(device, u32(i), self.window.surface, &present_support)
		if present_support {indices.present_family = u32(i)}
		if queue_family_indices_complete(indices) {break}
	}
	return indices
}
