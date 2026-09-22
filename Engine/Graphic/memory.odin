package graphic

import "core:log"
import "core:slice"
import "vendor:vulkan"

// Minimal block suballocator. Instead of calling vkAllocateMemory once per
// resource, memory is carved out of large blocks per memory kind. Host-visible
// blocks are mapped once for their whole lifetime.
@(private)
MemoryKind :: enum {
	DeviceLocal,
	HostVisible,
}

@(private)
MemRange :: struct {
	offset: vulkan.DeviceSize,
	size:   vulkan.DeviceSize,
}

@(private)
MemoryBlock :: struct {
	memory:      vulkan.DeviceMemory,
	memory_type: u32,
	kind:        MemoryKind,
	size:        vulkan.DeviceSize,
	mapped:      rawptr,
	dedicated:   bool,
	free_list:   [dynamic]MemRange,
}

@(private)
MemAlloc :: struct {
	block:  ^MemoryBlock,
	offset: vulkan.DeviceSize,
	size:   vulkan.DeviceSize,
}

@(private)
Allocator :: struct {
	device:          vulkan.Device,
	physical_device: vulkan.PhysicalDevice,
	blocks:          [dynamic]^MemoryBlock,
}

@(private)
DEFAULT_DEVICE_BLOCK_SIZE :: vulkan.DeviceSize(64 * 1024 * 1024)
@(private)
DEFAULT_HOST_BLOCK_SIZE :: vulkan.DeviceSize(16 * 1024 * 1024)

@(private)
allocator_init :: proc(device: vulkan.Device, physical_device: vulkan.PhysicalDevice) -> Allocator {
	return Allocator{device = device, physical_device = physical_device, blocks = make([dynamic]^MemoryBlock)}
}

@(private)
allocator_destroy :: proc(self: ^Allocator) {
	for len(self.blocks) > 0 {
		_allocator_destroy_block(self, self.blocks[len(self.blocks) - 1])
	}
	delete(self.blocks)
	self.blocks = nil
}

@(private)
allocator_alloc :: proc(self: ^Allocator, reqs: vulkan.MemoryRequirements, kind: MemoryKind) -> (mem: MemAlloc, ok: bool) {
	alignment := max(reqs.alignment, vulkan.DeviceSize(1))
	for block in self.blocks {
		if block.dedicated || block.kind != kind {continue}
		if (reqs.memoryTypeBits & (1 << block.memory_type)) == 0 {continue}
		if offset, allocated := _block_try_alloc(block, reqs.size, alignment); allocated {
			return MemAlloc{block = block, offset = offset, size = reqs.size}, true
		}
	}
	block := _allocator_create_block(self, kind, reqs.memoryTypeBits, reqs.size + alignment, nil) or_return
	offset, allocated := _block_try_alloc(block, reqs.size, alignment)
	if !allocated {
		_allocator_destroy_block(self, block)
		return {}, false
	}
	return MemAlloc{block = block, offset = offset, size = reqs.size}, true
}

// Dedicated allocation (vkAllocateMemory with VkMemoryDedicatedAllocateInfo),
// which is the recommended path for images.
@(private)
allocator_alloc_dedicated :: proc(self: ^Allocator, reqs: vulkan.MemoryRequirements, kind: MemoryKind, image: vulkan.Image = 0, buffer: vulkan.Buffer = 0) -> (mem: MemAlloc, ok: bool) {
	dedicated_info := vulkan.MemoryDedicatedAllocateInfo{sType = .MEMORY_DEDICATED_ALLOCATE_INFO, image = image, buffer = buffer}
	block := _allocator_create_block(self, kind, reqs.memoryTypeBits, reqs.size, &dedicated_info) or_return
	block.dedicated = true
	offset, allocated := _block_try_alloc(block, reqs.size, max(reqs.alignment, vulkan.DeviceSize(1)))
	if !allocated {
		_allocator_destroy_block(self, block)
		return {}, false
	}
	return MemAlloc{block = block, offset = offset, size = reqs.size}, true
}

@(private)
allocator_free :: proc(self: ^Allocator, mem: MemAlloc) {
	if mem.block == nil {return}
	if mem.block.dedicated {
		_allocator_destroy_block(self, mem.block)
		return
	}
	_block_free(mem.block, mem.offset, mem.size)
}

@(private) mem_alloc_memory :: proc(mem: MemAlloc) -> vulkan.DeviceMemory {return mem.block.memory}
@(private) mem_alloc_offset :: proc(mem: MemAlloc) -> vulkan.DeviceSize {return mem.offset}

@(private)
mem_alloc_mapped :: proc(mem: MemAlloc) -> rawptr {
	if mem.block == nil || mem.block.mapped == nil {return nil}
	return rawptr(uintptr(mem.block.mapped) + uintptr(mem.offset))
}

@(private)
_allocator_create_block :: proc(self: ^Allocator, kind: MemoryKind, type_bits: u32, min_size: vulkan.DeviceSize, dedicated: ^vulkan.MemoryDedicatedAllocateInfo) -> (result: ^MemoryBlock, ok: bool) {
	required: vulkan.MemoryPropertyFlags
	default_size: vulkan.DeviceSize
	switch kind {
	case .DeviceLocal:
		required = {.DEVICE_LOCAL}
		default_size = DEFAULT_DEVICE_BLOCK_SIZE
	case .HostVisible:
		required = {.HOST_VISIBLE, .HOST_COHERENT}
		default_size = DEFAULT_HOST_BLOCK_SIZE
	}

	memory_type, found := _allocator_find_memory_type(self.physical_device, type_bits, required)
	if !found {log.errorf("[VULKAN] No memory type for block (kind=%v)", kind); return nil, false}

	// Dedicated allocations must match the resource's memory requirement exactly;
	// regular blocks grow to the default block size.
	size := min_size
	if dedicated == nil {size = max(min_size, default_size)}

	tmp := new(MemoryBlock)
	tmp.memory_type = memory_type
	tmp.kind = kind
	tmp.size = size
	tmp.free_list = make([dynamic]MemRange, 0, 8)
	handed_off := false
	defer if !handed_off {
		if tmp.memory != 0 {vulkan.FreeMemory(self.device, tmp.memory, nil)}
		delete(tmp.free_list)
		free(tmp)
	}

	alloc_info := vulkan.MemoryAllocateInfo{sType = .MEMORY_ALLOCATE_INFO, pNext = dedicated, allocationSize = size, memoryTypeIndex = memory_type}
	vk_check(vulkan.AllocateMemory(self.device, &alloc_info, nil, &tmp.memory), "vkAllocateMemory") or_return
	if kind == .HostVisible {
		vk_check(vulkan.MapMemory(self.device, tmp.memory, 0, size, {}, &tmp.mapped), "vkMapMemory") or_return
	}
	append(&tmp.free_list, MemRange{offset = 0, size = size})
	append(&self.blocks, tmp)
	handed_off = true
	return tmp, true
}

@(private)
_allocator_destroy_block :: proc(self: ^Allocator, block: ^MemoryBlock) {
	if block.mapped != nil {vulkan.UnmapMemory(self.device, block.memory)}
	if block.memory != 0 {vulkan.FreeMemory(self.device, block.memory, nil)}
	delete(block.free_list)
	for b, i in self.blocks {
		if b == block {unordered_remove(&self.blocks, i); break}
	}
	free(block)
}

@(private)
_allocator_find_memory_type :: proc(physical_device: vulkan.PhysicalDevice, type_bits: u32, required: vulkan.MemoryPropertyFlags) -> (u32, bool) {
	props: vulkan.PhysicalDeviceMemoryProperties
	vulkan.GetPhysicalDeviceMemoryProperties(physical_device, &props)
	for i in 0 ..< props.memoryTypeCount {
		if (type_bits & (1 << u32(i))) == 0 {continue}
		if (props.memoryTypes[i].propertyFlags & required) == required {return u32(i), true}
	}
	return 0, false
}

@(private)
_align_up :: proc(value, alignment: vulkan.DeviceSize) -> vulkan.DeviceSize {
	if alignment <= 1 {return value}
	return (value + alignment - 1) & ~(alignment - 1)
}

// First-fit allocation from the block's free list, splitting the chosen range
// into an optional head padding and the remaining tail.
@(private)
_block_try_alloc :: proc(block: ^MemoryBlock, size, alignment: vulkan.DeviceSize) -> (offset: vulkan.DeviceSize, ok: bool) {
	for region, i in block.free_list {
		start := _align_up(region.offset, alignment)
		pad := start - region.offset
		if region.size < pad + size {continue}
		end := start + size
		tail := region.offset + region.size - end
		switch {
		case pad == 0 && tail == 0:
			unordered_remove(&block.free_list, i)
		case pad == 0:
			block.free_list[i] = MemRange{offset = end, size = tail}
		case tail == 0:
			block.free_list[i] = MemRange{offset = region.offset, size = pad}
		case:
			block.free_list[i] = MemRange{offset = region.offset, size = pad}
			inject_at(&block.free_list, i + 1, MemRange{offset = end, size = tail})
		}
		return start, true
	}
	return 0, false
}

@(private)
_block_free :: proc(block: ^MemoryBlock, offset, size: vulkan.DeviceSize) {
	append(&block.free_list, MemRange{offset = offset, size = size})
	slice.sort_by(block.free_list[:], proc(a, b: MemRange) -> bool {return a.offset < b.offset})
	i := 0
	for i + 1 < len(block.free_list) {
		current := &block.free_list[i]
		next := block.free_list[i + 1]
		if current.offset + current.size == next.offset {
			current.size += next.size
			unordered_remove(&block.free_list, i + 1)
		} else {
			i += 1
		}
	}
}
