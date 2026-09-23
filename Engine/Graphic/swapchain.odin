package graphic

import "core:log"
import "vendor:vulkan"

// Swapchain + dynamic-rendering resources. Rendering uses VkRenderingInfo
// (Vulkan 1.3 core) instead of VkRenderPass/VkFramebuffer, so image layout
// transitions are explicit and go through vkCmdPipelineBarrier2 (sync2).
@(private)
SwapChain :: struct {
	gpu:                   ^GPU,
	window:                ^Window,
	handle:                vulkan.SwapchainKHR,
	image_format:          vulkan.Format,
	depth_format:          vulkan.Format,
	extent:                vulkan.Extent2D,
	images:                [dynamic]vulkan.Image,
	image_views:           [dynamic]vulkan.ImageView,
	// One depth target per frame in flight. Sharing a single depth image across
	// two in-flight frames would let both write it concurrently; keeping one per
	// frame removes the hazard and matches the transient model a frame graph will
	// assume later.
	depth_targets:         [MAX_FRAMES_IN_FLIGHT]Render_Target,
	// One acquire semaphore + fence per frame in flight.
	image_available_semas: [dynamic]vulkan.Semaphore,
	in_flight_fences:      [dynamic]vulkan.Fence,
	// One render-finished semaphore + fence per swapchain image. Keeping these
	// per image (instead of per frame) avoids binary semaphore reuse hazards.
	render_finished_semas: [dynamic]vulkan.Semaphore,
	images_in_flight:      [dynamic]vulkan.Fence,
}

@(private)
IN_FLIGHT_WAIT :: max(u64)

@(private)
swapchain_init :: proc(gpu: ^GPU, window: ^Window) -> (result: SwapChain, ok: bool) {
	log.debugf("[VULKAN] SwapChain initialization...")
	tmp := SwapChain{gpu = gpu, window = window}
	committed := false
	defer if !committed {swapchain_destroy(&tmp)}

	_swapchain_create_handle(&tmp, 0) or_return
	log.debugf("[VULKAN]   Creating image views...")
	_swapchain_fetch_images(&tmp)
	_swapchain_create_image_views(&tmp)
	log.debugf("[VULKAN]     Created %d image views", len(tmp.image_views))
	log.debugf("[VULKAN]   Creating depth resources...")
	_swapchain_create_depth_resources(&tmp)
	log.debugf("[VULKAN]   Creating sync objects...")
	_swapchain_create_sync_objects(&tmp)
	log.debugf("[VULKAN]   SwapChain ready")
	committed = true
	return tmp, true
}

@(private)
swapchain_destroy :: proc(self: ^SwapChain) {
	log.debugf("[VULKAN] Destroying SwapChain...")
	if self.gpu == nil {return}
	gpu_wait(self.gpu)
	_swapchain_destroy_resources(self)
	if self.handle != 0 {vulkan.DestroySwapchainKHR(self.gpu.device, self.handle, nil); self.handle = 0}
	log.debugf("[VULKAN]   SwapChain destroyed")
}

// Recreates the swapchain in place, reusing the old one via oldSwapchain so the
// presentation engine can hand over without tearing down the surface.
@(private)
swapchain_recreate :: proc(self: ^SwapChain) -> bool {
	log.debugf("[VULKAN] Recreating SwapChain...")
	gpu_wait(self.gpu)
	old_handle := self.handle
	// Drop the old handle reference before creating so the new one can replace it.
	self.handle = 0
	if !_swapchain_create_handle(self, old_handle) {
		log.errorf("[VULKAN] Failed to recreate swapchain!")
		self.handle = old_handle
		return false
	}
	_swapchain_destroy_resources(self)
	if old_handle != 0 {vulkan.DestroySwapchainKHR(self.gpu.device, old_handle, nil)}
	_swapchain_fetch_images(self)
	_swapchain_create_image_views(self)
	_swapchain_create_depth_resources(self)
	_swapchain_create_sync_objects(self)
	log.debugf("[VULKAN]   SwapChain recreated")
	return true
}

@(private)
swapchain_wait_for_frame :: proc(self: ^SwapChain, frame: u32) {
	vk_assert(vulkan.WaitForFences(self.gpu.device, 1, &self.in_flight_fences[frame], true, IN_FLIGHT_WAIT), "vkWaitForFences")
}

@(private)
swapchain_acquire_next :: proc(self: ^SwapChain, frame: u32) -> (vulkan.Result, u32) {
	image_index: u32
	result := vulkan.AcquireNextImageKHR(self.gpu.device, self.handle, IN_FLIGHT_WAIT, self.image_available_semas[frame], 0, &image_index)
	return result, image_index
}

// Waits until the acquired image is no longer used, then resets the frame fence.
@(private)
swapchain_prepare_frame :: proc(self: ^SwapChain, frame, image_index: u32) {
	if self.images_in_flight[image_index] != 0 {
		vk_assert(vulkan.WaitForFences(self.gpu.device, 1, &self.images_in_flight[image_index], true, IN_FLIGHT_WAIT), "vkWaitForFences")
	}
	vk_assert(vulkan.ResetFences(self.gpu.device, 1, &self.in_flight_fences[frame]), "vkResetFences")
}

// swapchain_color_target borrows the acquired image for this frame. The returned
// target must not be destroyed.
@(private)
swapchain_color_target :: proc(self: ^SwapChain, image_index: u32) -> Render_Target {
	return render_target_borrow(
		self.gpu,
		self.images[image_index],
		self.image_views[image_index],
		self.image_format,
		self.extent,
	)
}

// The depth target is per frame in flight, so a frame only ever touches its own.
@(private)
swapchain_depth_target :: proc(self: ^SwapChain, frame: u32) -> ^Render_Target {
	return &self.depth_targets[frame]
}

@(private)
swapchain_submit :: proc(self: ^SwapChain, cmd: vulkan.CommandBuffer, frame, image_index: u32) -> vulkan.Result {
	wait_info := vulkan.SemaphoreSubmitInfo{
		sType = .SEMAPHORE_SUBMIT_INFO,
		semaphore = self.image_available_semas[frame],
		stageMask = {.COLOR_ATTACHMENT_OUTPUT},
	}
	signal_info := vulkan.SemaphoreSubmitInfo{
		sType = .SEMAPHORE_SUBMIT_INFO,
		semaphore = self.render_finished_semas[image_index],
		stageMask = {.ALL_COMMANDS},
	}
	cmd_info := vulkan.CommandBufferSubmitInfo{sType = .COMMAND_BUFFER_SUBMIT_INFO, commandBuffer = cmd}
	submit_info := vulkan.SubmitInfo2{
		sType = .SUBMIT_INFO_2,
		waitSemaphoreInfoCount = 1,
		pWaitSemaphoreInfos = &wait_info,
		commandBufferInfoCount = 1,
		pCommandBufferInfos = &cmd_info,
		signalSemaphoreInfoCount = 1,
		pSignalSemaphoreInfos = &signal_info,
	}
	if !vk_check(vulkan.QueueSubmit2(self.gpu.graphics_queue, 1, &submit_info, self.in_flight_fences[frame]), "vkQueueSubmit2") {
		return .ERROR_UNKNOWN
	}
	self.images_in_flight[image_index] = self.in_flight_fences[frame]
	return .SUCCESS
}

@(private)
swapchain_present :: proc(self: ^SwapChain, frame, image_index: u32) -> vulkan.Result {
	present_index := image_index
	present_info := vulkan.PresentInfoKHR{
		sType = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores = &self.render_finished_semas[present_index],
		swapchainCount = 1,
		pSwapchains = &self.handle,
		pImageIndices = &present_index,
	}
	return vulkan.QueuePresentKHR(self.gpu.present_queue, &present_info)
}

@(private)
_swapchain_create_handle :: proc(self: ^SwapChain, old_swapchain: vulkan.SwapchainKHR) -> bool {
	support := _gpu_query_swap_chain_support(self.gpu, self.gpu.physical_device)
	defer {delete(support.formats); delete(support.present_modes)}

	surface_format := _choose_swap_surface_format(support.formats)
	present_mode := _choose_swap_present_mode(support.present_modes)
	extent := _choose_swap_extent(self.window, support.capabilities)

	image_count := support.capabilities.minImageCount + 1
	if support.capabilities.maxImageCount > 0 && image_count > support.capabilities.maxImageCount {
		image_count = support.capabilities.maxImageCount
	}

	create_info := vulkan.SwapchainCreateInfoKHR{
		sType = .SWAPCHAIN_CREATE_INFO_KHR,
		surface = self.gpu.surface,
		minImageCount = image_count,
		imageFormat = surface_format.format,
		imageColorSpace = surface_format.colorSpace,
		imageExtent = extent,
		imageArrayLayers = 1,
		imageUsage = {.COLOR_ATTACHMENT},
		imageSharingMode = .EXCLUSIVE,
		preTransform = support.capabilities.currentTransform,
		compositeAlpha = {.OPAQUE},
		presentMode = present_mode,
		clipped = true,
		oldSwapchain = old_swapchain,
	}

	if !vk_check(vulkan.CreateSwapchainKHR(self.gpu.device, &create_info, nil, &self.handle), "vkCreateSwapchainKHR") {
		return false
	}

	self.image_format = surface_format.format; self.extent = extent
	self.depth_format = _find_depth_format(self.gpu)
	log.debugf("[VULKAN]     Format: %v  Depth: %v  Extent: %d x %d", surface_format.format, self.depth_format, extent.width, extent.height)
	return true
}

@(private)
_swapchain_fetch_images :: proc(self: ^SwapChain) {
	img_count: u32
	vk_assert(vulkan.GetSwapchainImagesKHR(self.gpu.device, self.handle, &img_count, nil), "vkGetSwapchainImagesKHR")
	self.images = make([dynamic]vulkan.Image, int(img_count))
	vk_assert(vulkan.GetSwapchainImagesKHR(self.gpu.device, self.handle, &img_count, raw_data(self.images)), "vkGetSwapchainImagesKHR")
}

@(private)
_swapchain_create_image_views :: proc(self: ^SwapChain) {
	self.image_views = make([dynamic]vulkan.ImageView, len(self.images))
	for image, i in self.images {
		view_info := vulkan.ImageViewCreateInfo{
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = image,
			viewType = .D2,
			format = self.image_format,
			subresourceRange = vulkan.ImageSubresourceRange{aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
		}
		vk_assert(vulkan.CreateImageView(self.gpu.device, &view_info, nil, &self.image_views[i]), "vkCreateImageView")
	}
}

@(private)
_swapchain_create_depth_resources :: proc(self: ^SwapChain) {
	depth_format := self.depth_format
	if depth_format == {} {depth_format = _find_depth_format(self.gpu); self.depth_format = depth_format}

	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		target, created := render_target_init(self.gpu, Render_Target_Desc{
			format = depth_format,
			extent = self.extent,
			usage  = {.DEPTH_STENCIL_ATTACHMENT},
			aspect = {.DEPTH},
		})
		if !created {
			log.errorf("[VULKAN] Failed to create depth target (frame %d)", i)
			return
		}
		self.depth_targets[i] = target
	}
}

@(private)
_swapchain_destroy_resources :: proc(self: ^SwapChain) {
	device := self.gpu.device
	for &semaphore in self.image_available_semas {vulkan.DestroySemaphore(device, semaphore, nil)}
	for &semaphore in self.render_finished_semas {vulkan.DestroySemaphore(device, semaphore, nil)}
	for &fence in self.in_flight_fences {vulkan.DestroyFence(device, fence, nil)}
	// NOTE: images_in_flight only aliases entries of in_flight_fences (bookkeeping
	// of which frame fence owns each image), so its entries must NOT be destroyed.
	for &image_view in self.image_views {vulkan.DestroyImageView(device, image_view, nil)}
	for &target in self.depth_targets {render_target_destroy(&target)}
	delete(self.images); self.images = nil
	delete(self.image_views); self.image_views = nil
	delete(self.image_available_semas); self.image_available_semas = nil
	delete(self.render_finished_semas); self.render_finished_semas = nil
	delete(self.in_flight_fences); self.in_flight_fences = nil
	delete(self.images_in_flight); self.images_in_flight = nil
}

@(private)
_swapchain_create_sync_objects :: proc(self: ^SwapChain) {
	device := self.gpu.device
	self.image_available_semas = make([dynamic]vulkan.Semaphore, MAX_FRAMES_IN_FLIGHT)
	self.in_flight_fences = make([dynamic]vulkan.Fence, MAX_FRAMES_IN_FLIGHT)
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		vk_assert(vulkan.CreateSemaphore(device, &vulkan.SemaphoreCreateInfo{sType = .SEMAPHORE_CREATE_INFO}, nil, &self.image_available_semas[i]), "vkCreateSemaphore")
		vk_assert(vulkan.CreateFence(device, &vulkan.FenceCreateInfo{sType = .FENCE_CREATE_INFO, flags = {.SIGNALED}}, nil, &self.in_flight_fences[i]), "vkCreateFence")
	}
	self.render_finished_semas = make([dynamic]vulkan.Semaphore, len(self.images))
	self.images_in_flight = make([dynamic]vulkan.Fence, len(self.images))
	for i in 0 ..< len(self.images) {
		vk_assert(vulkan.CreateSemaphore(device, &vulkan.SemaphoreCreateInfo{sType = .SEMAPHORE_CREATE_INFO}, nil, &self.render_finished_semas[i]), "vkCreateSemaphore")
	}
}

@(private)
_choose_swap_surface_format :: proc(formats: [dynamic]vulkan.SurfaceFormatKHR) -> vulkan.SurfaceFormatKHR {
	for format in formats {if format.format == .B8G8R8A8_SRGB && format.colorSpace == .SRGB_NONLINEAR {return format}}
	return formats[0]
}

@(private)
_choose_swap_present_mode :: proc(modes: [dynamic]vulkan.PresentModeKHR) -> vulkan.PresentModeKHR {
	// FIFO queues presentation to vblank — that is vsync. The spec requires FIFO
	// to be available, so it is used unconditionally; MAILBOX/IMMEDIATE would cap
	// the graphics thread only by GPU throughput.
	for mode in modes {if mode == .FIFO {return mode}}
	return .FIFO
}

@(private)
_choose_swap_extent :: proc(window: ^Window, caps: vulkan.SurfaceCapabilitiesKHR) -> vulkan.Extent2D {
	if caps.currentExtent.width != max(u32) {return caps.currentExtent}
	w, h := window_get_framebuffer_size(window)
	extent := vulkan.Extent2D{width = u32(w), height = u32(h)}
	extent.width = clamp(extent.width, caps.minImageExtent.width, caps.maxImageExtent.width)
	extent.height = clamp(extent.height, caps.minImageExtent.height, caps.maxImageExtent.height)
	return extent
}

@(private)
_find_depth_format :: proc(gpu: ^GPU) -> vulkan.Format {
	candidates := [?]vulkan.Format{.D32_SFLOAT, .D32_SFLOAT_S8_UINT, .D24_UNORM_S8_UINT}
	for format in candidates {
		props: vulkan.FormatProperties; vulkan.GetPhysicalDeviceFormatProperties(gpu.physical_device, format, &props)
		if .DEPTH_STENCIL_ATTACHMENT in props.optimalTilingFeatures {return format}
	}
	return .D32_SFLOAT
}
