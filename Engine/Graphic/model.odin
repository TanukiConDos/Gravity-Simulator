package graphic

import "base:intrinsics"
import "core:log"
import "core:math"
import "vendor:vulkan"

Model :: struct {
	buffer:       Buffer,
	index_count:  u32,
	index_offset: vulkan.DeviceSize,
	gpu:          ^GPU,
}

model_create :: proc(gpu: ^GPU, cp: ^CommandPool, sector_count, stack_count: i32) -> (m: Model, ok: bool) {
	log.debugf("[VULKAN] Model initialization (sphere %dx%d)...", sector_count, stack_count)
	m.gpu = gpu
	vertices, indices := _gen_sphere(sector_count, stack_count)
	defer {delete(vertices); delete(indices)}

	vs := vulkan.DeviceSize(len(vertices) * size_of(Vertex))
	is := vulkan.DeviceSize(len(indices) * size_of(u32))
	total_size := vs + is

	log.debugf("[VULKAN]   Uploading mesh to GPU (%d verts, %d indices)...", len(vertices), len(indices))

	staging_buf, staging_mem, _ := gpu_create_buffer(gpu, total_size, {.TRANSFER_SRC}, {.HOST_VISIBLE, .HOST_COHERENT})
	mapped: rawptr
	vulkan.MapMemory(gpu.device, staging_mem, 0, total_size, {}, &mapped)
	intrinsics.mem_copy(mapped, raw_data(vertices), int(vs))
	intrinsics.mem_copy(rawptr(uintptr(mapped) + uintptr(vs)), raw_data(indices), int(is))
	vulkan.UnmapMemory(gpu.device, staging_mem)

	m.buffer, _ = buffer_create(gpu, total_size, {.TRANSFER_DST, .VERTEX_BUFFER, .INDEX_BUFFER}, {.DEVICE_LOCAL})
	m.index_count = u32(len(indices))
	m.index_offset = vs

	cmd := command_pool_begin_one_shot(cp)
	gpu_copy_buffer(gpu, staging_buf, m.buffer.buffer, total_size, cmd)
	command_pool_end_one_shot(cp, cmd)

	vulkan.DestroyBuffer(gpu.device, staging_buf, nil)
	vulkan.FreeMemory(gpu.device, staging_mem, nil)

	log.debugf("[VULKAN]   Model ready")
	return m, true
}

model_destroy :: proc(m: ^Model) {
	log.debugf("[VULKAN] Destroying Model...")
	buffer_destroy(&m.buffer)
	log.debugf("[VULKAN]   Model destroyed")
}

model_bind :: proc(m: ^Model, cmd: vulkan.CommandBuffer) {
	off: vulkan.DeviceSize = 0
	vulkan.CmdBindVertexBuffers(cmd, 0, 1, &m.buffer.buffer, &off)
	vulkan.CmdBindIndexBuffer(cmd, m.buffer.buffer, m.index_offset, .UINT32)
}

model_get_index_count :: proc(m: ^Model) -> u32 {
	return m.index_count
}

_gen_sphere :: proc(sector_count, stack_count: i32) -> (vertices: [dynamic]Vertex, indices: [dynamic]u32) {
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
			append(&vertices, Vertex{pos = {x, y, z}, color = {0.3, 0.5, 0.8}})
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
