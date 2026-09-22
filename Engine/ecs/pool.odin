package ecs

// A component pool is a struct-of-arrays column indexed by `entity.index`. Two
// pools for different components therefore share one address space: the entry at
// `data[e.index]` always belongs to the same entity in every pool. That is what
// keeps the physics hot path free of per-access lookups.
//
// `dense` lists the entity indices that hold the component, so iteration never
// walks empty slots; `dense_pos` maps an index back to its slot in `dense` for
// O(1) swap-removal.
POOL_NONE :: u32(0xFFFFFFFF)

Pool :: struct($T: typeid) {
	data:      [dynamic]T,
	dense:     [dynamic]u32,
	dense_pos: [dynamic]u32,
}

@(private)
pool_ensure :: proc(p: ^Pool($T), index: u32) {
	if int(index) < len(p.dense_pos) {return}
	old := len(p.dense_pos)
	resize(&p.dense_pos, int(index) + 1)
	for i in old ..< len(p.dense_pos) {p.dense_pos[i] = POOL_NONE}
	resize(&p.data, int(index) + 1)
}

pool_set :: proc(p: ^Pool($T), index: u32, value: T) {
	pool_ensure(p, index)
	if p.dense_pos[index] == POOL_NONE {
		p.dense_pos[index] = u32(len(p.dense))
		append(&p.dense, index)
	}
	p.data[index] = value
}

pool_remove :: proc(p: ^Pool($T), index: u32) {
	if int(index) >= len(p.dense_pos) {return}
	pos := p.dense_pos[index]
	if pos == POOL_NONE {return}
	last := u32(len(p.dense) - 1)
	moved := p.dense[last]
	p.dense[pos] = moved
	p.dense_pos[moved] = pos
	pop(&p.dense)
	p.dense_pos[index] = POOL_NONE
}

pool_get :: proc(p: ^Pool($T), index: u32) -> ^T {
	return &p.data[index]
}

pool_has :: proc(p: ^Pool($T), index: u32) -> bool {
	return int(index) < len(p.dense_pos) && p.dense_pos[index] != POOL_NONE
}

pool_clear :: proc(p: ^Pool($T)) {
	clear(&p.dense)
	for i in 0 ..< len(p.dense_pos) {p.dense_pos[i] = POOL_NONE}
}

pool_destroy :: proc(p: ^Pool($T)) {
	delete(p.data)
	delete(p.dense)
	delete(p.dense_pos)
}
