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

swapchain_create :: proc(gpu: ^GPU, window: ^Window) -> (s: SwapChain, ok: bool) {
	log.debugf("[VULKAN] SwapChain initialization...")
	s.gpu = gpu; s.window = window
	log.debugf("[VULKAN]   Creating swap chain...")
	if !_swapchain_create(&s) {return {}, false}
	log.debugf("[VULKAN]   Creating image views...")
	_swapchain_create_image_views(&s)
	log.debugf("[VULKAN]     Created %d image views", len(s.image_views))
	log.debugf("[VULKAN]   Creating render pass...")
	_swapchain_create_render_pass(&s)
	log.debugf("[VULKAN]     Render pass created")
	log.debugf("[VULKAN]   Creating depth resources...")
	_swapchain_create_depth_resources(&s)
	log.debugf("[VULKAN]     Depth resources created")
	log.debugf("[VULKAN]   Creating framebuffers...")
	_swapchain_create_framebuffers(&s)
	log.debugf("[VULKAN]     Created %d framebuffers", len(s.framebuffers))
	log.debugf("[VULKAN]   Creating sync objects...")
	_swapchain_create_sync_objects(&s)
	log.debugf("[VULKAN]     Sync objects created (%d frames in flight)", MAX_FRAMES_IN_FLIGHT)
	log.debugf("[VULKAN]   SwapChain ready")
	return s, true
}

swapchain_destroy :: proc(s: ^SwapChain) {
	log.debugf("[VULKAN] Destroying SwapChain...")
	gpu := s.gpu
	for &sema in s.image_available_semas {vulkan.DestroySemaphore(gpu.device, sema, nil)}
	for &sema in s.render_finished_semas {vulkan.DestroySemaphore(gpu.device, sema, nil)}
	for &fence in s.in_flight_fences {vulkan.DestroyFence(gpu.device, fence, nil)}
	for &fb in s.framebuffers {vulkan.DestroyFramebuffer(gpu.device, fb, nil)}
	vulkan.DestroyImageView(gpu.device, s.depth_image_view, nil)
	vulkan.DestroyImage(gpu.device, s.depth_image, nil)
	vulkan.FreeMemory(gpu.device, s.depth_image_memory, nil)
	vulkan.DestroyRenderPass(gpu.device, s.render_pass, nil)
	for &iv in s.image_views {vulkan.DestroyImageView(gpu.device, iv, nil)}
	vulkan.DestroySwapchainKHR(gpu.device, s.handle, nil)
	delete(s.images); delete(s.image_views); delete(s.framebuffers)
	delete(s.image_available_semas); delete(s.render_finished_semas); delete(s.in_flight_fences)
	log.debugf("[VULKAN]   SwapChain destroyed")
}

swapchain_recreate :: proc(s: ^SwapChain) {
	log.debugf("[VULKAN] Recreating SwapChain...")
	gpu_wait(s.gpu)
	swapchain_destroy(s)
	if !_swapchain_create(s) {log.errorf("[VULKAN] Failed to recreate swapchain!")}
	_swapchain_create_image_views(s)
	_swapchain_create_render_pass(s)
	_swapchain_create_depth_resources(s)
	_swapchain_create_framebuffers(s)
	_swapchain_create_sync_objects(s)
	log.debugf("[VULKAN]   SwapChain recreated")
}

swapchain_acquire_next :: proc(s: ^SwapChain, current_frame: u32) -> (vulkan.Result, u32) {
	image_index: u32
	result := vulkan.AcquireNextImageKHR(s.gpu.device, s.handle, max(u64), s.image_available_semas[current_frame], 0, &image_index)
	return result, image_index
}

swapchain_reset_fences :: proc(s: ^SwapChain, current_frame: u32) {
	vulkan.WaitForFences(s.gpu.device, 1, &s.in_flight_fences[current_frame], true, max(u64))
	vulkan.ResetFences(s.gpu.device, 1, &s.in_flight_fences[current_frame])
}

swapchain_begin_render_pass :: proc(s: ^SwapChain, cmd: vulkan.CommandBuffer, image_index: u32) {
	clear_color := vulkan.ClearValue{color = vulkan.ClearColorValue{float32 = {0, 0, 0, 1}}}
	clear_depth := vulkan.ClearValue{depthStencil = vulkan.ClearDepthStencilValue{depth = 1, stencil = 0}}
	clear_values := [?]vulkan.ClearValue{clear_color, clear_depth}

	render_info := vulkan.RenderPassBeginInfo{
		sType = .RENDER_PASS_BEGIN_INFO,
		renderPass = s.render_pass,
		framebuffer = s.framebuffers[image_index],
		renderArea = vulkan.Rect2D{offset = {0, 0}, extent = s.extent},
		clearValueCount = 2,
		pClearValues = &clear_values[0],
	}
	vulkan.CmdBeginRenderPass(cmd, &render_info, .INLINE)

	viewport := vulkan.Viewport{width = f32(s.extent.width), height = f32(s.extent.height), minDepth = 0, maxDepth = 1}
	vulkan.CmdSetViewport(cmd, 0, 1, &viewport)
	scissor := vulkan.Rect2D{extent = s.extent}
	vulkan.CmdSetScissor(cmd, 0, 1, &scissor)
}

swapchain_queue_submit :: proc(s: ^SwapChain, cmd: vulkan.CommandBuffer, current_frame, image_index: u32) -> vulkan.Result {
	cmd_copy := cmd
	wait_stages := [?]vulkan.PipelineStageFlags{{.COLOR_ATTACHMENT_OUTPUT}}
	submit_info := vulkan.SubmitInfo{
		sType = .SUBMIT_INFO,
		waitSemaphoreCount = 1,
		pWaitSemaphores = &s.image_available_semas[current_frame],
		pWaitDstStageMask = &wait_stages[0],
		commandBufferCount = 1,
		pCommandBuffers = &cmd_copy,
		signalSemaphoreCount = 1,
		pSignalSemaphores = &s.render_finished_semas[current_frame],
	}
	if vulkan.QueueSubmit(s.gpu.graphics_queue, 1, &submit_info, s.in_flight_fences[current_frame]) != .SUCCESS {
		log.errorf("[VULKAN] Failed to submit!")
		return .ERROR_UNKNOWN
	}
	img_idx := image_index
	present_info := vulkan.PresentInfoKHR{
		sType = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores = &s.render_finished_semas[current_frame],
		swapchainCount = 1,
		pSwapchains = &s.handle,
		pImageIndices = &img_idx,
	}
	return vulkan.QueuePresentKHR(s.gpu.present_queue, &present_info)
}

@(private) _swapchain_create :: proc(s: ^SwapChain) -> bool {
	support := _gpu_query_swap_chain_support(s.gpu, s.gpu.physical_device)
	defer {delete(support.formats); delete(support.present_modes)}

	surface_format := _choose_swap_surface_format(support.formats)
	present_mode := _choose_swap_present_mode(support.present_modes)
	extent := _choose_swap_extent(s.window, support.capabilities)

	image_count := support.capabilities.minImageCount + 1
	if support.capabilities.maxImageCount > 0 && image_count > support.capabilities.maxImageCount {
		image_count = support.capabilities.maxImageCount
	}

	create_info := vulkan.SwapchainCreateInfoKHR{
		sType = .SWAPCHAIN_CREATE_INFO_KHR,
		surface = s.gpu.surface,
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

	if vulkan.CreateSwapchainKHR(s.gpu.device, &create_info, nil, &s.handle) != .SUCCESS {
		log.errorf("[VULKAN] Failed to create swapchain!")
		return false
	}

	s.image_format = surface_format.format; s.extent = extent
	img_count: u32; vulkan.GetSwapchainImagesKHR(s.gpu.device, s.handle, &img_count, nil)
	s.images = make([dynamic]vulkan.Image, int(img_count))
	vulkan.GetSwapchainImagesKHR(s.gpu.device, s.handle, &img_count, raw_data(s.images))
	log.debugf("[VULKAN]     Format: %v  Extent: %d x %d", surface_format.format, extent.width, extent.height)
	return true
}

@(private) _swapchain_create_image_views :: proc(s: ^SwapChain) {
	s.image_views = make([dynamic]vulkan.ImageView, len(s.images))
	for image, i in s.images {
		view_info := vulkan.ImageViewCreateInfo{
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = image,
			viewType = .D2,
			format = s.image_format,
			subresourceRange = vulkan.ImageSubresourceRange{aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
		}
		vulkan.CreateImageView(s.gpu.device, &view_info, nil, &s.image_views[i])
	}
}

@(private) _swapchain_create_render_pass :: proc(s: ^SwapChain) {
	color_attach := vulkan.AttachmentDescription{
		format = s.image_format,
		samples = {._1},
		loadOp = .CLEAR,
		storeOp = .STORE,
		stencilLoadOp = .DONT_CARE,
		stencilStoreOp = .DONT_CARE,
		initialLayout = .UNDEFINED,
		finalLayout = .PRESENT_SRC_KHR,
	}
	depth_attach := vulkan.AttachmentDescription{
		format = _find_depth_format(s.gpu),
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
	vulkan.CreateRenderPass(s.gpu.device, &render_pass_info, nil, &s.render_pass)
}

@(private) _swapchain_create_depth_resources :: proc(s: ^SwapChain) {
	depth_format := _find_depth_format(s.gpu)

	image_info := vulkan.ImageCreateInfo{
		sType         = .IMAGE_CREATE_INFO,
		imageType     = .D2,
		format        = depth_format,
		extent        = vulkan.Extent3D{width = s.extent.width, height = s.extent.height, depth = 1},
		mipLevels     = 1,
		arrayLayers   = 1,
		samples       = {._1},
		tiling        = .OPTIMAL,
		usage         = {.DEPTH_STENCIL_ATTACHMENT},
		sharingMode   = .EXCLUSIVE,
		initialLayout = .UNDEFINED,
	}
	if vulkan.CreateImage(s.gpu.device, &image_info, nil, &s.depth_image) != .SUCCESS {
		log.errorf("[VULKAN] Failed to create depth image!")
		return
	}

	mem_reqs: vulkan.MemoryRequirements
	vulkan.GetImageMemoryRequirements(s.gpu.device, s.depth_image, &mem_reqs)
	mem_idx, found := gpu_find_memory_type(s.gpu, mem_reqs.memoryTypeBits, {.DEVICE_LOCAL})
	assert(found)

	alloc_info := vulkan.MemoryAllocateInfo{
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = mem_reqs.size,
		memoryTypeIndex = mem_idx,
	}
	vulkan.AllocateMemory(s.gpu.device, &alloc_info, nil, &s.depth_image_memory)
	vulkan.BindImageMemory(s.gpu.device, s.depth_image, s.depth_image_memory, 0)

	view_info := vulkan.ImageViewCreateInfo{
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = s.depth_image,
		viewType = .D2,
		format = depth_format,
		subresourceRange = vulkan.ImageSubresourceRange{aspectMask = {.DEPTH}, levelCount = 1, layerCount = 1},
	}
	vulkan.CreateImageView(s.gpu.device, &view_info, nil, &s.depth_image_view)
}

@(private) _swapchain_create_framebuffers :: proc(s: ^SwapChain) {
	s.framebuffers = make([dynamic]vulkan.Framebuffer, len(s.image_views))
	for view, i in s.image_views {
		attachments := [?]vulkan.ImageView{view, s.depth_image_view}
		fb_info := vulkan.FramebufferCreateInfo{sType = .FRAMEBUFFER_CREATE_INFO, renderPass = s.render_pass, attachmentCount = 2, pAttachments = &attachments[0], width = s.extent.width, height = s.extent.height, layers = 1}
		vulkan.CreateFramebuffer(s.gpu.device, &fb_info, nil, &s.framebuffers[i])
	}
}

@(private) _swapchain_create_sync_objects :: proc(s: ^SwapChain) {
	s.image_available_semas = make([dynamic]vulkan.Semaphore, MAX_FRAMES_IN_FLIGHT)
	s.render_finished_semas = make([dynamic]vulkan.Semaphore, MAX_FRAMES_IN_FLIGHT)
	s.in_flight_fences = make([dynamic]vulkan.Fence, MAX_FRAMES_IN_FLIGHT)
	for i in 0..<MAX_FRAMES_IN_FLIGHT {
		vulkan.CreateSemaphore(s.gpu.device, &vulkan.SemaphoreCreateInfo{sType = .SEMAPHORE_CREATE_INFO}, nil, &s.image_available_semas[i])
		vulkan.CreateSemaphore(s.gpu.device, &vulkan.SemaphoreCreateInfo{sType = .SEMAPHORE_CREATE_INFO}, nil, &s.render_finished_semas[i])
		vulkan.CreateFence(s.gpu.device, &vulkan.FenceCreateInfo{sType = .FENCE_CREATE_INFO, flags = {.SIGNALED}}, nil, &s.in_flight_fences[i])
	}
}

_choose_swap_surface_format :: proc(formats: [dynamic]vulkan.SurfaceFormatKHR) -> vulkan.SurfaceFormatKHR {
	for f in formats {if f.format == .B8G8R8A8_SRGB && f.colorSpace == .SRGB_NONLINEAR {return f}}
	return formats[0]
}

_choose_swap_present_mode :: proc(modes: [dynamic]vulkan.PresentModeKHR) -> vulkan.PresentModeKHR {
	for m in modes {if m == .MAILBOX {return m}}
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
