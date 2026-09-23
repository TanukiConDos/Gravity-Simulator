package graphic

import "vendor:vulkan"

// A named render phase: everything between vkCmdBeginRendering and
// vkCmdEndRendering, plus the pipeline and attachment state it uses. It is
// engine bookkeeping, not a VkRenderPass. The frame must not care where its
// color target came from (swapchain or offscreen); it only receives
// Render_Targets in frame_pass_begin.
@(private)
Frame_Pass :: struct {
	name:        string,
	pipeline:    Pipeline_ID,
	color_load:  vulkan.AttachmentLoadOp,
	color_store: vulkan.AttachmentStoreOp,
	color_clear: vulkan.ClearValue,
	depth_load:  vulkan.AttachmentLoadOp,
	depth_store: vulkan.AttachmentStoreOp,
	depth_clear: vulkan.ClearValue,
}

@(private)
frame_pass_create :: proc(name: string, pipeline: Pipeline_ID) -> Frame_Pass {
	return Frame_Pass{
		name        = name,
		pipeline    = pipeline,
		color_load  = .CLEAR,
		color_store = .STORE,
		color_clear = {color = {float32 = {0, 0, 0, 1}}},
		depth_load  = .CLEAR,
		depth_store = .DONT_CARE,
		depth_clear = {depthStencil = {depth = 1, stencil = 0}},
	}
}

// frame_pass_begin transitions the attachments and opens the rendering scope.
// UNDEFINED is a valid old layout for both targets: the color image is fully
// overwritten (loadOp CLEAR) and the depth target is per frame in flight and
// cleared every frame, so neither carries state across frames.
@(private)
frame_pass_begin :: proc(
	cmd: vulkan.CommandBuffer,
	pass: ^Frame_Pass,
	color: Render_Target,
	depth: ^Render_Target,
	extent: vulkan.Extent2D,
) {
	render_target_barrier(
		cmd,
		color,
		.UNDEFINED,
		.ATTACHMENT_OPTIMAL,
		{.COLOR_ATTACHMENT_OUTPUT},
		{.COLOR_ATTACHMENT_OUTPUT},
		{},
		{.COLOR_ATTACHMENT_WRITE},
	)

	color_attachment := vulkan.RenderingAttachmentInfo{
		sType       = .RENDERING_ATTACHMENT_INFO,
		imageView   = color.view,
		imageLayout = .ATTACHMENT_OPTIMAL,
		loadOp      = pass.color_load,
		storeOp     = pass.color_store,
		clearValue  = pass.color_clear,
	}
	render_info := vulkan.RenderingInfo{
		sType                = .RENDERING_INFO,
		renderArea           = vulkan.Rect2D{offset = {0, 0}, extent = extent},
		layerCount           = 1,
		colorAttachmentCount = 1,
		pColorAttachments    = &color_attachment,
	}

	depth_attachment: vulkan.RenderingAttachmentInfo
	if depth != nil {
		render_target_barrier(
			cmd,
			depth^,
			.UNDEFINED,
			.DEPTH_ATTACHMENT_OPTIMAL,
			{.TOP_OF_PIPE},
			{.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
			{},
			{.DEPTH_STENCIL_ATTACHMENT_WRITE},
		)
		depth_attachment = vulkan.RenderingAttachmentInfo{
			sType       = .RENDERING_ATTACHMENT_INFO,
			imageView   = depth.view,
			imageLayout = .DEPTH_ATTACHMENT_OPTIMAL,
			loadOp      = pass.depth_load,
			storeOp     = pass.depth_store,
			clearValue  = pass.depth_clear,
		}
		render_info.pDepthAttachment = &depth_attachment
	}

	vulkan.CmdBeginRendering(cmd, &render_info)

	// Negative viewport height flips Y in the viewport transform, replacing the
	// "proj[1][1] *= -1" CPU hack (core since Vulkan 1.1 maintenance1).
	viewport := vulkan.Viewport{x = 0, y = f32(extent.height), width = f32(extent.width), height = -f32(extent.height), minDepth = 0, maxDepth = 1}
	vulkan.CmdSetViewport(cmd, 0, 1, &viewport)
	scissor := vulkan.Rect2D{extent = extent}
	vulkan.CmdSetScissor(cmd, 0, 1, &scissor)
}

@(private)
frame_pass_end :: proc(cmd: vulkan.CommandBuffer, _: ^Frame_Pass) {
	vulkan.CmdEndRendering(cmd)
}
