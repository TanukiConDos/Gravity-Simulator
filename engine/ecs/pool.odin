package ecs

// A component pool is a struct-of-arrays column indexed by `entity.index`. Two
// pools for different components therefore share one address space: the entry at
// `data[e.index]` always belongs to the same entity in every pool. That is what
// keeps the physics hot path free of per-access lookups.
//
// `dense` lists the entity indices that hold the component, so iteration never
// walks empty slots; `dense_pos` maps an index back to its slot in `dense` for
// O(1) swap-removal.
//
// Storage is fixed-capacity once the world is reserved: `data` and `dense_pos`
// are grown to the world capacity up front and `dense` is reserved to it, so a
// column never relocates during the simulation. Pool mutation is package-private
// (only `World` may add/remove/revision); callers read through `pool_has`/
// `pool_get` or borrow the column slices for iteration.
POOL_NONE :: u32(0xFFFFFFFF)

Pool :: struct($T: typeid) {
	data:      [dynamic]T,
	dense:     [dynamic]u32,
	dense_pos: [dynamic]u32,
}

// Grows the column to `capacity` and reserves the dense list, so no later
// `pool_set` can reallocate. Only grows: a smaller capacity is ignored.
pool_reserve :: proc(p: ^Pool($T), capacity: int) {
	reserve(&p.dense, capacity)
	old := len(p.dense_pos)
	if capacity <= old {return}
	resize(&p.dense_pos, capacity)
	for i in old ..< len(p.dense_pos) {p.dense_pos[i] = POOL_NONE}
	resize(&p.data, capacity)
}

@(private)
pool_ensure :: proc(p: ^Pool($T), index: u32) {
	if int(index) < len(p.dense_pos) {return}
	old := len(p.dense_pos)
	resize(&p.dense_pos, int(index) + 1)
	for i in old ..< len(p.dense_pos) {p.dense_pos[i] = POOL_NONE}
	resize(&p.data, int(index) + 1)
}

@(private)
pool_set :: proc(p: ^Pool($T), index: u32, value: T) {
	pool_ensure(p, index)
	if p.dense_pos[index] == POOL_NONE {
		p.dense_pos[index] = u32(len(p.dense))
		append(&p.dense, index)
	}
	p.data[index] = value
}

@(private)
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

// Checks the dense/dense_pos bijection and that no entry points outside the
// column. Invariant checking only; not used in the hot path.
pool_validate :: proc(p: ^Pool($T)) -> bool {
	if len(p.data) != len(p.dense_pos) {return false}
	if len(p.dense) > len(p.dense_pos) {return false}
	for i in 0 ..< len(p.dense) {
		entity := p.dense[i]
		if int(entity) >= len(p.dense_pos) || p.dense_pos[entity] != u32(i) {return false}
	}
	for slot in 0 ..< len(p.dense_pos) {
		pos := p.dense_pos[slot]
		if pos == POOL_NONE {continue}
		if int(pos) >= len(p.dense) || p.dense[pos] != u32(slot) {return false}
	}
	return true
}

pool_destroy :: proc(p: ^Pool($T)) {
	delete(p.data)
	delete(p.dense)
	delete(p.dense_pos)
}
