package graphic

import "base:intrinsics"
import "core:log"
import "core:math"
import "vendor:vulkan"

@(private)
Model :: struct {
	buffer:       Buffer,
	index_count:  u32,
	index_offset: vulkan.DeviceSize,
	index_size:   vulkan.DeviceSize,
	gpu:          ^GPU,
}

@(private)
model_init :: proc(gpu: ^GPU, command_pool: ^CommandPool, sector_count, stack_count: i32) -> (result: Model, ok: bool) {
	log.debugf("[VULKAN] Model initialization (sphere %dx%d)...", sector_count, stack_count)
	tmp := Model{gpu = gpu}
	vertices, indices := _gen_sphere(sector_count, stack_count)
	defer {delete(vertices); delete(indices)}

	vertex_size := vulkan.DeviceSize(len(vertices) * size_of(Vertex))
	index_size := vulkan.DeviceSize(len(indices) * size_of(u32))
	total_size := vertex_size + index_size

	log.debugf(
		"[VULKAN]   Uploading mesh to GPU (%d verts, %d indices)...",
		len(vertices),
		len(indices),
	)

	staging := buffer_init(gpu, total_size, {.TRANSFER_SRC}, .HostVisible) or_return
	defer buffer_destroy(&staging)
	intrinsics.mem_copy(staging.mapped, raw_data(vertices), int(vertex_size))
	intrinsics.mem_copy(
		rawptr(uintptr(staging.mapped) + uintptr(vertex_size)),
		raw_data(indices),
		int(index_size),
	)

	tmp.buffer = buffer_init(gpu, total_size, {.TRANSFER_DST, .VERTEX_BUFFER, .INDEX_BUFFER}, .DeviceLocal) or_return
	tmp.index_count = u32(len(indices))
	tmp.index_offset = vertex_size
	tmp.index_size = index_size

	command_buffer := command_pool_begin_one_shot(command_pool)
	gpu_copy_buffer(gpu, staging.buffer, tmp.buffer.buffer, total_size, command_buffer)
	command_pool_end_one_shot(command_pool, command_buffer)

	log.debugf("[VULKAN]   Model ready")
	return tmp, true
}

@(private)
model_destroy :: proc(self: ^Model) {
	if self.gpu == nil {return}
	log.debugf("[VULKAN] Destroying Model...")
	buffer_destroy(&self.buffer)
	log.debugf("[VULKAN]   Model destroyed")
}

@(private)
model_bind :: proc(self: ^Model, cmd: vulkan.CommandBuffer) {
	offset: vulkan.DeviceSize = 0
	vulkan.CmdBindVertexBuffers(cmd, 0, 1, &self.buffer.buffer, &offset)
	// vkCmdBindIndexBuffer2 (maintenance5, core in Vulkan 1.4) binds the index
	// subrange of the packed vertex+index buffer directly.
	vulkan.CmdBindIndexBuffer2(cmd, self.buffer.buffer, self.index_offset, self.index_size, .UINT32)
}

@(private)
_gen_sphere :: proc(
	sector_count, stack_count: i32,
) -> (
	vertices: [dynamic]Vertex,
	indices: [dynamic]u32,
) {
	radius: f32 = 1.0
	stack_step := math.PI / f32(stack_count)
	sector_step := 2.0 * math.PI / f32(sector_count)

	for i in 0 ..= stack_count {
		stack_angle := math.PI / 2.0 - f32(i) * stack_step
		xy := radius * math.cos(stack_angle)
		z := radius * math.sin(stack_angle)
		for j in 0 ..= sector_count {
			sector_angle := f32(j) * sector_step
			x := xy * math.cos(sector_angle)
			y := xy * math.sin(sector_angle)
			append(&vertices, Vertex{pos = {x, y, z}, color = {x, y, z}})
		}
	}

	for i in 0 ..< stack_count {
		k1 := u32(i * (sector_count + 1))
		k2 := k1 + u32(sector_count) + 1
		for j in 0 ..< sector_count {
			if i != 0 {
				append(&indices, k1, k2, k1 + 1)
			}
			if i != stack_count - 1 {
				append(&indices, k1 + 1, k2, k2 + 1)
			}
			k1 += 1
			k2 += 1
		}
	}

	return
}
