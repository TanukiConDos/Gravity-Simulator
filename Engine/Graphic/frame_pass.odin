package graphic

import "vendor:vulkan"

// One color output of a frame pass: the target plus how it is loaded/stored and
// the value it is cleared to. Keeping these separate from Frame_Pass lets the
// renderer assemble per-frame targets (e.g. the swapchain image) while the pass
// itself stays static.
@(private)
Color_Attachment :: struct {
	target: Render_Target,
	load:   vulkan.AttachmentLoadOp,
	store:  vulkan.AttachmentStoreOp,
	clear:  vulkan.ClearValue,
}

// A named render phase: everything between vkCmdBeginRendering and
// vkCmdEndRendering, plus the pipeline and depth state it uses. It is engine
// bookkeeping, not a VkRenderPass.
@(private)
Frame_Pass :: struct {
	name:        string,
	pipeline:    Pipeline_ID,
	depth_load:  vulkan.AttachmentLoadOp,
	depth_store: vulkan.AttachmentStoreOp,
	depth_clear: vulkan.ClearValue,
}

@(private)
frame_pass_create :: proc(name: string, pipeline: Pipeline_ID) -> Frame_Pass {
	return Frame_Pass{
		name        = name,
		pipeline    = pipeline,
		depth_load  = .CLEAR,
		depth_store = .DONT_CARE,
		depth_clear = {depthStencil = {depth = 1, stencil = 0}},
	}
}

// frame_pass_begin opens the rendering scope. Layout transitions are emitted by
// the frame graph beforehand; this only builds the attachments and sets the
// dynamic viewport/scissor.
@(private)
frame_pass_begin :: proc(
	cmd: vulkan.CommandBuffer,
	pass: ^Frame_Pass,
	colors: []Color_Attachment,
	depth: ^Render_Target,
	extent: vulkan.Extent2D,
) {
	assert(
		len(colors) > 0 && len(colors) <= MAX_COLOR_ATTACHMENTS,
		"frame pass color attachment count out of range",
	)

	attachments: [MAX_COLOR_ATTACHMENTS]vulkan.RenderingAttachmentInfo
	for color, i in colors {
		attachments[i] = vulkan.RenderingAttachmentInfo{
			sType       = .RENDERING_ATTACHMENT_INFO,
			imageView   = color.target.view,
			imageLayout = .ATTACHMENT_OPTIMAL,
			loadOp      = color.load,
			storeOp     = color.store,
			clearValue  = color.clear,
		}
	}
	render_info := vulkan.RenderingInfo{
		sType                = .RENDERING_INFO,
		renderArea           = vulkan.Rect2D{offset = {0, 0}, extent = extent},
		layerCount           = 1,
		colorAttachmentCount = u32(len(colors)),
		pColorAttachments    = &attachments[0],
	}

	depth_attachment: vulkan.RenderingAttachmentInfo
	if depth != nil {
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
