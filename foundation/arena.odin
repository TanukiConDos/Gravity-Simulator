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

arena_destroy :: proc(a: ^Arena) {
	delete(a.data)
	a.offset = 0
}

arena_alloc :: proc(a: ^Arena, size: int, align: int) -> rawptr {
	offset := a.offset
	offset = (offset + align - 1) & ~(align - 1)
	if offset + size > len(a.data) {
		return nil
	}
	a.offset = offset + size
	return rawptr(&a.data[offset])
}

arena_reset :: proc(a: ^Arena) {
	a.offset = 0
}
