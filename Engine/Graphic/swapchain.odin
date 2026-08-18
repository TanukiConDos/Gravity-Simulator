package graphic

import "core:log"
import "vendor:vulkan"

SwapChain :: struct {
	gpu:                   ^GPU,
	window:                ^Window,
	handle:                vulkan.SwapchainKHR,
	image_format:          vulkan.Format,
	extent:                vulkan.Extent2D,
	images:                [dynamic]vulkan.Image,
	image_views:           [dynamic]vulkan.ImageView,
	render_pass:           vulkan.RenderPass,
	framebuffers:          [dynamic]vulkan.Framebuffer,
	depth_image:           vulkan.Image,
	depth_image_memory:    vulkan.DeviceMemory,
	depth_image_view:      vulkan.ImageView,
	image_available_semas: [dynamic]vulkan.Semaphore,
	render_finished_semas: [dynamic]vulkan.Semaphore,
	in_flight_fences:      [dynamic]vulkan.Fence,
}

swapchain_create :: proc(gpu: ^GPU, window: ^Window) -> (self: SwapChain, ok: bool) {
	log.debugf("[VULKAN] SwapChain initialization...")
	self.gpu = gpu; self.window = window
	log.debugf("[VULKAN]   Creating swap chain...")
	if !_swapchain_create(&self) {return {}, false}
	log.debugf("[VULKAN]   Creating image views...")
	_swapchain_create_image_views(&self)
	log.debugf("[VULKAN]     Created %d image views", len(self.image_views))
	log.debugf("[VULKAN]   Creating render pass...")
	_swapchain_create_render_pass(&self)
	log.debugf("[VULKAN]     Render pass created")
	log.debugf("[VULKAN]   Creating depth resources...")
	_swapchain_create_depth_resources(&self)
	log.debugf("[VULKAN]     Depth resources created")
	log.debugf("[VULKAN]   Creating framebuffers...")
	_swapchain_create_framebuffers(&self)
	log.debugf("[VULKAN]     Created %d framebuffers", len(self.framebuffers))
	log.debugf("[VULKAN]   Creating sync objects...")
	_swapchain_create_sync_objects(&self)
	log.debugf("[VULKAN]     Sync objects created (%d frames in flight)", MAX_FRAMES_IN_FLIGHT)
	log.debugf("[VULKAN]   SwapChain ready")
	return self, true
}

swapchain_destroy :: proc(self: ^SwapChain) {
	log.debugf("[VULKAN] Destroying SwapChain...")
	gpu := self.gpu
	vulkan.DeviceWaitIdle(gpu.device)
	for &semaphore in self.image_available_semas {vulkan.DestroySemaphore(gpu.device, semaphore, nil)}
	for &semaphore in self.render_finished_semas {vulkan.DestroySemaphore(gpu.device, semaphore, nil)}
	for &fence in self.in_flight_fences {vulkan.DestroyFence(gpu.device, fence, nil)}
	for &framebuffer in self.framebuffers {vulkan.DestroyFramebuffer(gpu.device, framebuffer, nil)}
	vulkan.DestroyImageView(gpu.device, self.depth_image_view, nil)
	vulkan.DestroyImage(gpu.device, self.depth_image, nil)
	vulkan.FreeMemory(gpu.device, self.depth_image_memory, nil)
	vulkan.DestroyRenderPass(gpu.device, self.render_pass, nil)
	for &image_view in self.image_views {vulkan.DestroyImageView(gpu.device, image_view, nil)}
	vulkan.DestroySwapchainKHR(gpu.device, self.handle, nil)
	delete(self.images); delete(self.image_views); delete(self.framebuffers)
	delete(self.image_available_semas); delete(self.render_finished_semas); delete(self.in_flight_fences)
	log.debugf("[VULKAN]   SwapChain destroyed")
}

swapchain_recreate :: proc(self: ^SwapChain) {
	log.debugf("[VULKAN] Recreating SwapChain...")
	gpu_wait(self.gpu)
	swapchain_destroy(self)
	if !_swapchain_create(self) {log.errorf("[VULKAN] Failed to recreate swapchain!")}
	_swapchain_create_image_views(self)
	_swapchain_create_render_pass(self)
	_swapchain_create_depth_resources(self)
	_swapchain_create_framebuffers(self)
	_swapchain_create_sync_objects(self)
	log.debugf("[VULKAN]   SwapChain recreated")
}

swapchain_acquire_next :: proc(self: ^SwapChain, current_frame: u32) -> (vulkan.Result, u32) {
	image_index: u32
	result := vulkan.AcquireNextImageKHR(self.gpu.device, self.handle, max(u64), self.image_available_semas[current_frame], 0, &image_index)
	return result, image_index
}

swapchain_reset_fences :: proc(self: ^SwapChain, current_frame: u32) {
	vulkan.WaitForFences(self.gpu.device, 1, &self.in_flight_fences[current_frame], true, max(u64))
	vulkan.ResetFences(self.gpu.device, 1, &self.in_flight_fences[current_frame])
}

swapchain_begin_render_pass :: proc(self: ^SwapChain, command_buffer: vulkan.CommandBuffer, image_index: u32) {
	clear_color := vulkan.ClearValue{color = vulkan.ClearColorValue{float32 = {0, 0, 0, 1}}}
	clear_depth := vulkan.ClearValue{depthStencil = vulkan.ClearDepthStencilValue{depth = 1, stencil = 0}}
	clear_values := [?]vulkan.ClearValue{clear_color, clear_depth}

	render_info := vulkan.RenderPassBeginInfo{
		sType = .RENDER_PASS_BEGIN_INFO,
		renderPass = self.render_pass,
		framebuffer = self.framebuffers[image_index],
		renderArea = vulkan.Rect2D{offset = {0, 0}, extent = self.extent},
		clearValueCount = 2,
		pClearValues = &clear_values[0],
	}
	vulkan.CmdBeginRenderPass(command_buffer, &render_info, .INLINE)

	viewport := vulkan.Viewport{width = f32(self.extent.width), height = f32(self.extent.height), minDepth = 0, maxDepth = 1}
	vulkan.CmdSetViewport(command_buffer, 0, 1, &viewport)
	scissor := vulkan.Rect2D{extent = self.extent}
	vulkan.CmdSetScissor(command_buffer, 0, 1, &scissor)
}

swapchain_queue_submit :: proc(self: ^SwapChain, command_buffer: vulkan.CommandBuffer, current_frame, image_index_param: u32) -> vulkan.Result {
	cmd_copy := command_buffer
	wait_stages := [?]vulkan.PipelineStageFlags{{.COLOR_ATTACHMENT_OUTPUT}}
	submit_info := vulkan.SubmitInfo{
		sType = .SUBMIT_INFO,
		waitSemaphoreCount = 1,
		pWaitSemaphores = &self.image_available_semas[current_frame],
		pWaitDstStageMask = &wait_stages[0],
		commandBufferCount = 1,
		pCommandBuffers = &cmd_copy,
		signalSemaphoreCount = 1,
		pSignalSemaphores = &self.render_finished_semas[current_frame],
	}
	if vulkan.QueueSubmit(self.gpu.graphics_queue, 1, &submit_info, self.in_flight_fences[current_frame]) != .SUCCESS {
		log.errorf("[VULKAN] Failed to submit!")
		return .ERROR_UNKNOWN
	}
	image_index := image_index_param
	present_info := vulkan.PresentInfoKHR{
		sType = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores = &self.render_finished_semas[current_frame],
		swapchainCount = 1,
		pSwapchains = &self.handle,
		pImageIndices = &image_index,
	}
	return vulkan.QueuePresentKHR(self.gpu.present_queue, &present_info)
}

@(private) _swapchain_create :: proc(self: ^SwapChain) -> bool {
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
		oldSwapchain = 0,
	}

	if vulkan.CreateSwapchainKHR(self.gpu.device, &create_info, nil, &self.handle) != .SUCCESS {
		log.errorf("[VULKAN] Failed to create swapchain!")
		return false
	}

	self.image_format = surface_format.format; self.extent = extent
	img_count: u32; vulkan.GetSwapchainImagesKHR(self.gpu.device, self.handle, &img_count, nil)
	self.images = make([dynamic]vulkan.Image, int(img_count))
	vulkan.GetSwapchainImagesKHR(self.gpu.device, self.handle, &img_count, raw_data(self.images))
	log.debugf("[VULKAN]     Format: %v  Extent: %d x %d", surface_format.format, extent.width, extent.height)
	return true
}

@(private) _swapchain_create_image_views :: proc(self: ^SwapChain) {
	self.image_views = make([dynamic]vulkan.ImageView, len(self.images))
	for image, i in self.images {
		view_info := vulkan.ImageViewCreateInfo{
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = image,
			viewType = .D2,
			format = self.image_format,
			subresourceRange = vulkan.ImageSubresourceRange{aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
		}
		vulkan.CreateImageView(self.gpu.device, &view_info, nil, &self.image_views[i])
	}
}

@(private) _swapchain_create_render_pass :: proc(self: ^SwapChain) {
	color_attach := vulkan.AttachmentDescription{
		format = self.image_format,
		samples = {._1},
		loadOp = .CLEAR,
		storeOp = .STORE,
		stencilLoadOp = .DONT_CARE,
		stencilStoreOp = .DONT_CARE,
		initialLayout = .UNDEFINED,
		finalLayout = .PRESENT_SRC_KHR,
	}
	depth_attach := vulkan.AttachmentDescription{
		format = _find_depth_format(self.gpu),
		samples = {._1},
		loadOp = .CLEAR,
		storeOp = .DONT_CARE,
		stencilLoadOp = .DONT_CARE,
		stencilStoreOp = .DONT_CARE,
		initialLayout = .UNDEFINED,
		finalLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
	}
	color_ref := vulkan.AttachmentReference{attachment = 0, layout = .COLOR_ATTACHMENT_OPTIMAL}
	depth_ref := vulkan.AttachmentReference{attachment = 1, layout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL}
	subpass := vulkan.SubpassDescription{pipelineBindPoint = .GRAPHICS, colorAttachmentCount = 1, pColorAttachments = &color_ref, pDepthStencilAttachment = &depth_ref}
	dependency := vulkan.SubpassDependency{srcSubpass = vulkan.SUBPASS_EXTERNAL, dstSubpass = 0, srcStageMask = {.COLOR_ATTACHMENT_OUTPUT, .LATE_FRAGMENT_TESTS}, srcAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE}, dstStageMask = {.COLOR_ATTACHMENT_OUTPUT, .EARLY_FRAGMENT_TESTS}, dstAccessMask = {.COLOR_ATTACHMENT_WRITE, .DEPTH_STENCIL_ATTACHMENT_WRITE}}
	attachments := [?]vulkan.AttachmentDescription{color_attach, depth_attach}
	render_pass_info := vulkan.RenderPassCreateInfo{sType = .RENDER_PASS_CREATE_INFO, attachmentCount = 2, pAttachments = &attachments[0], subpassCount = 1, pSubpasses = &subpass, dependencyCount = 1, pDependencies = &dependency}
	vulkan.CreateRenderPass(self.gpu.device, &render_pass_info, nil, &self.render_pass)
}

@(private) _swapchain_create_depth_resources :: proc(self: ^SwapChain) {
	depth_format := _find_depth_format(self.gpu)

	image_info := vulkan.ImageCreateInfo{
		sType         = .IMAGE_CREATE_INFO,
		imageType     = .D2,
		format        = depth_format,
		extent        = vulkan.Extent3D{width = self.extent.width, height = self.extent.height, depth = 1},
		mipLevels     = 1,
		arrayLayers   = 1,
		samples       = {._1},
		tiling        = .OPTIMAL,
		usage         = {.DEPTH_STENCIL_ATTACHMENT},
		sharingMode   = .EXCLUSIVE,
		initialLayout = .UNDEFINED,
	}
	if vulkan.CreateImage(self.gpu.device, &image_info, nil, &self.depth_image) != .SUCCESS {
		log.errorf("[VULKAN] Failed to create depth image!")
		return
	}

	mem_reqs: vulkan.MemoryRequirements
	vulkan.GetImageMemoryRequirements(self.gpu.device, self.depth_image, &mem_reqs)
	memory_index, found := gpu_find_memory_type(self.gpu, mem_reqs.memoryTypeBits, {.DEVICE_LOCAL})
	assert(found)

	alloc_info := vulkan.MemoryAllocateInfo{
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = mem_reqs.size,
		memoryTypeIndex = memory_index,
	}
	vulkan.AllocateMemory(self.gpu.device, &alloc_info, nil, &self.depth_image_memory)
	vulkan.BindImageMemory(self.gpu.device, self.depth_image, self.depth_image_memory, 0)

	view_info := vulkan.ImageViewCreateInfo{
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = self.depth_image,
		viewType = .D2,
		format = depth_format,
		subresourceRange = vulkan.ImageSubresourceRange{aspectMask = {.DEPTH}, levelCount = 1, layerCount = 1},
	}
	vulkan.CreateImageView(self.gpu.device, &view_info, nil, &self.depth_image_view)
}

@(private) _swapchain_create_framebuffers :: proc(self: ^SwapChain) {
	self.framebuffers = make([dynamic]vulkan.Framebuffer, len(self.image_views))
	for view, i in self.image_views {
		attachments := [?]vulkan.ImageView{view, self.depth_image_view}
		framebuffer_info := vulkan.FramebufferCreateInfo{sType = .FRAMEBUFFER_CREATE_INFO, renderPass = self.render_pass, attachmentCount = 2, pAttachments = &attachments[0], width = self.extent.width, height = self.extent.height, layers = 1}
		vulkan.CreateFramebuffer(self.gpu.device, &framebuffer_info, nil, &self.framebuffers[i])
	}
}

@(private) _swapchain_create_sync_objects :: proc(self: ^SwapChain) {
	self.image_available_semas = make([dynamic]vulkan.Semaphore, MAX_FRAMES_IN_FLIGHT)
	self.render_finished_semas = make([dynamic]vulkan.Semaphore, MAX_FRAMES_IN_FLIGHT)
	self.in_flight_fences = make([dynamic]vulkan.Fence, MAX_FRAMES_IN_FLIGHT)
	for i in 0..<MAX_FRAMES_IN_FLIGHT {
		vulkan.CreateSemaphore(self.gpu.device, &vulkan.SemaphoreCreateInfo{sType = .SEMAPHORE_CREATE_INFO}, nil, &self.image_available_semas[i])
		vulkan.CreateSemaphore(self.gpu.device, &vulkan.SemaphoreCreateInfo{sType = .SEMAPHORE_CREATE_INFO}, nil, &self.render_finished_semas[i])
		vulkan.CreateFence(self.gpu.device, &vulkan.FenceCreateInfo{sType = .FENCE_CREATE_INFO, flags = {.SIGNALED}}, nil, &self.in_flight_fences[i])
	}
}

_choose_swap_surface_format :: proc(formats: [dynamic]vulkan.SurfaceFormatKHR) -> vulkan.SurfaceFormatKHR {
	for format in formats {if format.format == .B8G8R8A8_SRGB && format.colorSpace == .SRGB_NONLINEAR {return format}}
	return formats[0]
}

_choose_swap_present_mode :: proc(modes: [dynamic]vulkan.PresentModeKHR) -> vulkan.PresentModeKHR {
	for mode in modes {if mode == .MAILBOX {return mode}}
	return .FIFO
}

_choose_swap_extent :: proc(window: ^Window, caps: vulkan.SurfaceCapabilitiesKHR) -> vulkan.Extent2D {
	if caps.currentExtent.width != max(u32) {return caps.currentExtent}
	w, h := window_get_framebuffer_size(window)
	extent := vulkan.Extent2D{width = u32(w), height = u32(h)}
	extent.width = clamp(extent.width, caps.minImageExtent.width, caps.maxImageExtent.width)
	extent.height = clamp(extent.height, caps.minImageExtent.height, caps.maxImageExtent.height)
	return extent
}

_find_depth_format :: proc(gpu: ^GPU) -> vulkan.Format {
	candidates := [?]vulkan.Format{.D32_SFLOAT, .D32_SFLOAT_S8_UINT, .D24_UNORM_S8_UINT}
	for format in candidates {
		props: vulkan.FormatProperties; vulkan.GetPhysicalDeviceFormatProperties(gpu.physical_device, format, &props)
		if .DEPTH_STENCIL_ATTACHMENT in props.optimalTilingFeatures {return format}
	}
	return .D32_SFLOAT
}
