package graphic

import "core:log"
import "vendor:vulkan"

// A render destination: image + view + format + extent. Swapchain targets are
// borrowed from the swapchain (owned = false); offscreen targets own their image
// and dedicated memory. Having one type for both is what lets a future frame
// graph treat every attachment the same way.
@(private)
Render_Target :: struct {
	gpu:    ^GPU,
	image:  vulkan.Image,
	view:   vulkan.ImageView,
	format: vulkan.Format,
	extent: vulkan.Extent2D,
	aspect: vulkan.ImageAspectFlags,
	mem:    MemAlloc,
	owned:  bool,
}

@(private)
Render_Target_Desc :: struct {
	format: vulkan.Format,
	extent: vulkan.Extent2D,
	usage:  vulkan.ImageUsageFlags,
	aspect: vulkan.ImageAspectFlags,
}

@(private)
render_target_init :: proc(gpu: ^GPU, desc: Render_Target_Desc) -> (result: Render_Target, ok: bool) {
	tmp := Render_Target{
		gpu    = gpu,
		format = desc.format,
		extent = desc.extent,
		aspect = desc.aspect,
		owned  = true,
	}
	committed := false
	defer if !committed {render_target_destroy(&tmp)}

	image_info := vulkan.ImageCreateInfo{
		sType         = .IMAGE_CREATE_INFO,
		imageType     = .D2,
		format        = desc.format,
		extent        = vulkan.Extent3D{width = desc.extent.width, height = desc.extent.height, depth = 1},
		mipLevels     = 1,
		arrayLayers   = 1,
		samples       = {._1},
		tiling        = .OPTIMAL,
		usage         = desc.usage,
		sharingMode   = .EXCLUSIVE,
		initialLayout = .UNDEFINED,
	}
	vk_check(vulkan.CreateImage(gpu.device, &image_info, nil, &tmp.image), "vkCreateImage") or_return

	mem_reqs: vulkan.MemoryRequirements
	vulkan.GetImageMemoryRequirements(gpu.device, tmp.image, &mem_reqs)
	mem, allocated := allocator_alloc_dedicated(&gpu.allocator, mem_reqs, .DeviceLocal, image = tmp.image)
	if !allocated {
		log.errorf("[VULKAN] Failed to allocate render target memory!")
		return {}, false
	}
	tmp.mem = mem
	vk_assert(vulkan.BindImageMemory(gpu.device, tmp.image, mem_alloc_memory(mem), mem_alloc_offset(mem)), "vkBindImageMemory")

	view_info := vulkan.ImageViewCreateInfo{
		sType    = .IMAGE_VIEW_CREATE_INFO,
		image    = tmp.image,
		viewType = .D2,
		format   = desc.format,
		subresourceRange = vulkan.ImageSubresourceRange{
			aspectMask = desc.aspect,
			levelCount = 1,
			layerCount = 1,
		},
	}
	vk_assert(vulkan.CreateImageView(gpu.device, &view_info, nil, &tmp.view), "vkCreateImageView")

	committed = true
	return tmp, true
}

// Wraps an image/view owned by someone else (the swapchain). The returned target
// must not be passed to render_target_destroy; it is only a barrier/render
// descriptor for the frame.
@(private)
render_target_borrow :: proc(
	gpu: ^GPU,
	image: vulkan.Image,
	view: vulkan.ImageView,
	format: vulkan.Format,
	extent: vulkan.Extent2D,
	aspect: vulkan.ImageAspectFlags = {.COLOR},
) -> Render_Target {
	return Render_Target{
		gpu    = gpu,
		image  = image,
		view   = view,
		format = format,
		extent = extent,
		aspect = aspect,
		owned  = false,
	}
}

@(private)
render_target_destroy :: proc(self: ^Render_Target) {
	if self.gpu == nil || !self.owned {return}
	device := self.gpu.device
	if self.view != 0 {vulkan.DestroyImageView(device, self.view, nil); self.view = 0}
	if self.image != 0 {vulkan.DestroyImage(device, self.image, nil); self.image = 0}
	if self.mem.block != nil {allocator_free(&self.gpu.allocator, self.mem); self.mem = {}}
	self.owned = false
}

// image_barrier is the single place that knows about layouts. Every layout
// transition in the frame goes through it, so adding a pass does not scatter
// stage/access masks across the renderer.
@(private)
image_barrier :: proc(
	cmd: vulkan.CommandBuffer,
	image: vulkan.Image,
	aspect: vulkan.ImageAspectFlags,
	old_layout, new_layout: vulkan.ImageLayout,
	src_stage, dst_stage: vulkan.PipelineStageFlags2,
	src_access, dst_access: vulkan.AccessFlags2,
) {
	barrier := vulkan.ImageMemoryBarrier2{
		sType               = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask        = src_stage,
		srcAccessMask       = src_access,
		dstStageMask        = dst_stage,
		dstAccessMask       = dst_access,
		oldLayout           = old_layout,
		newLayout           = new_layout,
		srcQueueFamilyIndex = vulkan.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vulkan.QUEUE_FAMILY_IGNORED,
		image               = image,
		subresourceRange    = vulkan.ImageSubresourceRange{aspectMask = aspect, levelCount = 1, layerCount = 1},
	}
	dependency := vulkan.DependencyInfo{sType = .DEPENDENCY_INFO, imageMemoryBarrierCount = 1, pImageMemoryBarriers = &barrier}
	vulkan.CmdPipelineBarrier2(cmd, &dependency)
}

@(private)
render_target_barrier :: proc(
	cmd: vulkan.CommandBuffer,
	target: Render_Target,
	old_layout, new_layout: vulkan.ImageLayout,
	src_stage, dst_stage: vulkan.PipelineStageFlags2,
	src_access, dst_access: vulkan.AccessFlags2,
) {
	image_barrier(cmd, target.image, target.aspect, old_layout, new_layout, src_stage, dst_stage, src_access, dst_access)
}
