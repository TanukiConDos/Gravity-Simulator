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
	ubo_alignment:              vulkan.DeviceSize,
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

gpu_destroy :: proc(g: ^GPU) {
	log.debugf("[VULKAN] Destroying GPU...")
	if g.device != nil {vulkan.DeviceWaitIdle(g.device); vulkan.DestroyDevice(g.device, nil)}
	if g.surface != 0 {vulkan.DestroySurfaceKHR(g.instance, g.surface, nil)}
	if g.instance != nil {vulkan.DestroyInstance(g.instance, nil)}
	log.debugf("[VULKAN]   GPU destroyed")
}

gpu_wait :: proc(g: ^GPU) {vulkan.DeviceWaitIdle(g.device)}

gpu_find_memory_type :: proc(g: ^GPU, type_filter: u32, properties: vulkan.MemoryPropertyFlags) -> (u32, bool) {
	mem_properties: vulkan.PhysicalDeviceMemoryProperties; vulkan.GetPhysicalDeviceMemoryProperties(g.physical_device, &mem_properties)
	for i in 0..<mem_properties.memoryTypeCount {if (type_filter & (1<<i)) != 0 && (mem_properties.memoryTypes[i].propertyFlags & properties) == properties {return i, true}}
	return 0, false
}

gpu_create_buffer :: proc(g: ^GPU, size: vulkan.DeviceSize, usage: vulkan.BufferUsageFlags, props: vulkan.MemoryPropertyFlags) -> (vulkan.Buffer, vulkan.DeviceMemory, bool) {
	buf_info := vulkan.BufferCreateInfo{sType=.BUFFER_CREATE_INFO,size=size,usage=usage,sharingMode=.EXCLUSIVE}
	buf: vulkan.Buffer
	mem: vulkan.DeviceMemory
	if vulkan.CreateBuffer(g.device, &buf_info, nil, &buf) != .SUCCESS {return {}, {}, false}
	mem_reqs: vulkan.MemoryRequirements; vulkan.GetBufferMemoryRequirements(g.device, buf, &mem_reqs)
	idx, fd := gpu_find_memory_type(g, mem_reqs.memoryTypeBits, props); if !fd {return {}, {}, false}
	alloc := vulkan.MemoryAllocateInfo{sType=.MEMORY_ALLOCATE_INFO,allocationSize=mem_reqs.size,memoryTypeIndex=idx}
	if vulkan.AllocateMemory(g.device, &alloc, nil, &mem) != .SUCCESS {return {}, {}, false}
	vulkan.BindBufferMemory(g.device, buf, mem, 0)
	return buf, mem, true
}

gpu_copy_buffer :: proc(g: ^GPU, src, dst: vulkan.Buffer, size: vulkan.DeviceSize, cmd: vulkan.CommandBuffer) {
	cr := vulkan.BufferCopy{srcOffset=0,dstOffset=0,size=size}; vulkan.CmdCopyBuffer(cmd, src, dst, 1, &cr)
}

gpu_get_aligned_ubo_size :: proc(g: ^GPU) -> vulkan.DeviceSize {raw:=vulkan.DeviceSize(size_of(UniformBufferObject)); align:=g.ubo_alignment; if align==0 {align=256}; return ((raw+align-1)/align)*align}
gpu_get_instance :: proc(g: ^GPU) -> vulkan.Instance {return g.instance}
gpu_get_device :: proc(g: ^GPU) -> vulkan.Device {return g.device}
gpu_get_physical_device :: proc(g: ^GPU) -> vulkan.PhysicalDevice {return g.physical_device}
gpu_get_graphics_queue :: proc(g: ^GPU) -> vulkan.Queue {return g.graphics_queue}
gpu_get_queue_family :: proc(g: ^GPU) -> u32 {return g.graphics_queue_family_index}

@(private) _gpu_create_instance :: proc(g: ^GPU) -> bool {
	log.debugf("[VULKAN]   Creating Vulkan instance...")
	app_info := vulkan.ApplicationInfo{sType=.APPLICATION_INFO,pApplicationName="Gravity Simulation",applicationVersion=vulkan.MAKE_VERSION(1,0,0),pEngineName="No Engine",engineVersion=vulkan.MAKE_VERSION(1,0,0),apiVersion=vulkan.API_VERSION_1_1}
		glfw_exts := glfw.GetRequiredInstanceExtensions(); ec := len(glfw_exts); en := make([dynamic]cstring, ec); defer delete(en)
		for ext,i in glfw_exts {en[i]=ext; log.debugf("[VULKAN]     Extension: %s", string(ext))}
		ci := vulkan.InstanceCreateInfo{sType=.INSTANCE_CREATE_INFO,pApplicationInfo=&app_info,enabledExtensionCount=u32(ec),ppEnabledExtensionNames=raw_data(en)}
	log.debugf("[VULKAN]     Calling vkCreateInstance (ext_count=%d)...", ec)
	r := vulkan.CreateInstance(&ci, nil, &g.instance); log.debugf("[VULKAN]     vkCreateInstance returned: %v", r)
	if r != .SUCCESS {log.errorf("[VULKAN]     FAILED: vkCreateInstance (result=%v)", r); return false}
	log.debugf("[VULKAN]     Instance created"); return true
}

SwapChainSupportDetails :: struct {capabilities: vulkan.SurfaceCapabilitiesKHR, formats: [dynamic]vulkan.SurfaceFormatKHR, present_modes: [dynamic]vulkan.PresentModeKHR}
QueueFamilyIndices :: struct {graphics_family: Maybe(u32), present_family: Maybe(u32)}
queue_family_indices_complete :: proc(i: QueueFamilyIndices) -> bool {return i.graphics_family != nil && i.present_family != nil}

@(private) _gpu_pick_physical_device :: proc(g: ^GPU) -> bool {
	log.debugf("[VULKAN]   Picking physical device...")
	count: u32; vulkan.EnumeratePhysicalDevices(g.instance, &count, nil)
	if count == 0 {log.errorf("[VULKAN]     No Vulkan-capable GPU found!"); return false}
	log.debugf("[VULKAN]     Found %d device(s)", count)
	devices := make([]vulkan.PhysicalDevice, int(count)); defer delete(devices)
	vulkan.EnumeratePhysicalDevices(g.instance, &count, raw_data(devices))
	best_score := 0; best_device: vulkan.PhysicalDevice
	for device in devices {
		score, suitable := _gpu_rate_device(g, device)
		props: vulkan.PhysicalDeviceProperties; vulkan.GetPhysicalDeviceProperties(device, &props)
		name := string(cstring(&props.deviceName[0]))
		if suitable {log.debugf("[VULKAN]       %s - score=%d", name, score); if score>best_score {best_score=score; best_device=device}}
		else {log.debugf("[VULKAN]       %s - skipped", name)}
	}
	if best_score == 0 {log.errorf("[VULKAN]     No suitable GPU found!"); return false}
	g.physical_device = best_device
	props: vulkan.PhysicalDeviceProperties; vulkan.GetPhysicalDeviceProperties(best_device, &props)
	log.infof("GPU: %v", string(cstring(&props.deviceName[0])))
	g.ubo_alignment = props.limits.minUniformBufferOffsetAlignment
	log.debugf("[VULKAN]     UBO alignment: %v bytes", g.ubo_alignment)
	return true
}

@(private) _gpu_rate_device :: proc(g: ^GPU, device: vulkan.PhysicalDevice) -> (int, bool) {
	props: vulkan.PhysicalDeviceProperties; feats: vulkan.PhysicalDeviceFeatures
	vulkan.GetPhysicalDeviceProperties(device, &props); vulkan.GetPhysicalDeviceFeatures(device, &feats)
	if !feats.geometryShader {return 0, false}
	qf := _gpu_find_queue_families(g, device); if !queue_family_indices_complete(qf) {return 0, false}
	if !_gpu_check_device_extensions(device) {return 0, false}
	sw := _gpu_query_swap_chain_support(g, device); defer {delete(sw.formats); delete(sw.present_modes)}
	if len(sw.formats)==0||len(sw.present_modes)==0 {return 0, false}
	score := int(props.limits.maxImageDimension2D); if props.deviceType==.DISCRETE_GPU {score+=1000}
	return score, true
}

@(private) _gpu_create_logical_device :: proc(g: ^GPU) -> bool {
	log.debugf("[VULKAN]   Creating logical device...")
	indices := _gpu_find_queue_families(g, g.physical_device)
	uf: map[u32]struct{}; defer delete(uf); uf[indices.graphics_family.?]={}; uf[indices.present_family.?]={}
	qp: f32 = 1.0; qi: [dynamic]vulkan.DeviceQueueCreateInfo; defer delete(qi)
	for family in uf {append(&qi, vulkan.DeviceQueueCreateInfo{sType=.DEVICE_QUEUE_CREATE_INFO,queueFamilyIndex=family,queueCount=1,pQueuePriorities=&qp})}
	df: vulkan.PhysicalDeviceFeatures
	ci := vulkan.DeviceCreateInfo{sType=.DEVICE_CREATE_INFO,queueCreateInfoCount=u32(len(qi)),pQueueCreateInfos=raw_data(qi),pEnabledFeatures=&df,enabledExtensionCount=u32(len(DEVICE_EXTENSIONS)),ppEnabledExtensionNames=raw_data(DEVICE_EXTENSIONS)}
	if vulkan.CreateDevice(g.physical_device, &ci, nil, &g.device) != .SUCCESS {log.errorf("[VULKAN]     FAILED: vkCreateDevice"); return false}
	log.debugf("[VULKAN]     Logical device created")
	vulkan.load_proc_addresses_device(g.device)
	g.graphics_queue_family_index = indices.graphics_family.?
	vulkan.GetDeviceQueue(g.device, indices.graphics_family.?, 0, &g.graphics_queue)
	vulkan.GetDeviceQueue(g.device, indices.present_family.?, 0, &g.present_queue)
	log.debugf("[VULKAN]     Graphics queue family: %d  Present queue family: %d", indices.graphics_family.?, indices.present_family.?)
	return true
}

@(private) _gpu_check_device_extensions :: proc(device: vulkan.PhysicalDevice) -> bool {
	count: u32; vulkan.EnumerateDeviceExtensionProperties(device, nil, &count, nil)
	avail := make([]vulkan.ExtensionProperties, int(count)); defer delete(avail)
	vulkan.EnumerateDeviceExtensionProperties(device, nil, &count, raw_data(avail))
	req: map[string]bool; defer delete(req)
	for ext in DEVICE_EXTENSIONS {req[string(ext)] = true}
	for ext in avail {n := ext.extensionName; delete_key(&req, string(cstring(&n[0])))}
	return len(req) == 0
}

@(private) _gpu_query_swap_chain_support :: proc(g: ^GPU, device: vulkan.PhysicalDevice) -> SwapChainSupportDetails {
	details: SwapChainSupportDetails
	vulkan.GetPhysicalDeviceSurfaceCapabilitiesKHR(device, g.window.surface, &details.capabilities)
	fc: u32; vulkan.GetPhysicalDeviceSurfaceFormatsKHR(device, g.window.surface, &fc, nil)
	if fc>0 {details.formats=make([dynamic]vulkan.SurfaceFormatKHR, int(fc)); vulkan.GetPhysicalDeviceSurfaceFormatsKHR(device,g.window.surface,&fc,raw_data(details.formats))}
	mc: u32; vulkan.GetPhysicalDeviceSurfacePresentModesKHR(device, g.window.surface, &mc, nil)
	if mc>0 {details.present_modes=make([dynamic]vulkan.PresentModeKHR, int(mc)); vulkan.GetPhysicalDeviceSurfacePresentModesKHR(device,g.window.surface,&mc,raw_data(details.present_modes))}
	return details
}

@(private) _gpu_find_queue_families :: proc(g: ^GPU, device: vulkan.PhysicalDevice) -> QueueFamilyIndices {
	indices: QueueFamilyIndices
	count: u32; vulkan.GetPhysicalDeviceQueueFamilyProperties(device, &count, nil)
	fams := make([]vulkan.QueueFamilyProperties, int(count)); defer delete(fams)
	vulkan.GetPhysicalDeviceQueueFamilyProperties(device, &count, raw_data(fams))
	for fam,i in fams {
		if .GRAPHICS in fam.queueFlags {indices.graphics_family = u32(i)}
		ps: b32; vulkan.GetPhysicalDeviceSurfaceSupportKHR(device, u32(i), g.window.surface, &ps)
		if ps {indices.present_family = u32(i)}
		if queue_family_indices_complete(indices) {break}
	}
	return indices
}
