package foundation

Arena :: struct {
	data:   []byte,
	offset: int,
}

arena_create :: proc(size: int) -> Arena {
	return Arena{
		data   = make([]byte, size),
		offset = 0,
	}
}

arena_destroy :: proc(self: ^Arena) {
	delete(self.data)
	self.offset = 0
}

arena_alloc :: proc(self: ^Arena, size: int, alignment: int) -> rawptr {
	offset := self.offset
	offset = (offset + alignment - 1) & ~(alignment - 1)
	if offset + size > len(self.data) {
		return nil
	}
	self.offset = offset + size
	return rawptr(&self.data[offset])
}

arena_reset :: proc(self: ^Arena) {
	self.offset = 0
}
