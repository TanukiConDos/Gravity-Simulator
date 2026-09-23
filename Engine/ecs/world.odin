package ecs

// The world owns the entity registry and every component pool and resource.
// Pools and resources are keyed by `typeid` and reached through the generic
// accessors below; systems cache the returned pointer and never look it up in a
// hot loop.
//
// Threading: the world is not synchronised. One thread owns it at a time. In this
// engine the physics thread owns the simulation components and the graphics
// thread only reads a snapshot resource, matching the pre-ECS ownership model.
World :: struct {
	generations:   [dynamic]u32,
	alive:         [dynamic]bool,
	free:          [dynamic]u32,
	alive_count:   int,
	// Bumped on structural changes only (spawn/despawn/component add/remove),
	// never on value updates. Physics uses it to know when its octree is stale.
	revision:      u64,
	pools:         map[typeid]Pool_Entry,
	resources:     map[typeid]Resource_Entry,
	destroy_queue: [dynamic]Entity,
}

@(private)
Pool_Entry :: struct {
	ptr:          rawptr,
	destroy:      proc(ptr: rawptr),
	remove_index: proc(ptr: rawptr, index: u32),
}

@(private)
Resource_Entry :: struct {
	ptr:     rawptr,
	destroy: proc(ptr: rawptr),
}

world_create :: proc() -> ^World {
	w := new(World)
	w.pools = make(map[typeid]Pool_Entry)
	w.resources = make(map[typeid]Resource_Entry)
	return w
}

world_destroy :: proc(w: ^World) {
	if w == nil {return}
	for _, entry in w.pools {entry.destroy(entry.ptr)}
	for _, entry in w.resources {entry.destroy(entry.ptr)}
	delete(w.pools)
	delete(w.resources)
	delete(w.generations)
	delete(w.alive)
	delete(w.free)
	delete(w.destroy_queue)
	free(w)
}

// --- Pools ---------------------------------------------------------------

world_pool :: proc(w: ^World, $T: typeid) -> ^Pool(T) {
	if entry, ok := w.pools[typeid_of(T)]; ok {
		return cast(^Pool(T))entry.ptr
	}
	p := new(Pool(T))
	w.pools[typeid_of(T)] = Pool_Entry {
		ptr          = p,
		destroy      = _pool_entry_destroy(T),
		remove_index = _pool_entry_remove(T),
	}
	return p
}

@(private)
_pool_entry_destroy :: proc($T: typeid) -> proc(ptr: rawptr) {
	return proc(ptr: rawptr) {
		p := cast(^Pool(T))ptr
		pool_destroy(p)
		free(p)
	}
}

@(private)
_pool_entry_remove :: proc($T: typeid) -> proc(ptr: rawptr, index: u32) {
	return proc(ptr: rawptr, index: u32) {pool_remove(cast(^Pool(T))ptr, index)}
}

// --- Resources -----------------------------------------------------------

// Singletons that are not per-entity data (camera, snapshot, tunables). The
// first call creates the value zeroed and records `destroy`; later calls return
// the same pointer. `destroy` receives the raw allocation and is responsible for
// releasing any memory the resource owns.
world_resource :: proc(
	w: ^World,
	$T: typeid,
	destroy: proc(ptr: rawptr) = nil,
) -> ^T {
	if entry, ok := w.resources[typeid_of(T)]; ok {
		return cast(^T)entry.ptr
	}
	r := new(T)
	d := destroy
	if d == nil {d = _resource_entry_destroy(T)}
	w.resources[typeid_of(T)] = Resource_Entry {
		ptr     = r,
		destroy = d,
	}
	return r
}

@(private)
_resource_entry_destroy :: proc($T: typeid) -> proc(ptr: rawptr) {
	return proc(ptr: rawptr) {free(ptr)}
}

// --- Entities ------------------------------------------------------------

world_spawn :: proc(w: ^World) -> Entity {
	index: u32
	if len(w.free) > 0 {
		index = pop(&w.free)
	} else {
		index = u32(len(w.generations))
		append(&w.generations, 0)
		append(&w.alive, false)
	}
	w.alive[index] = true
	w.alive_count += 1
	w.revision += 1
	return Entity{index = index, generation = w.generations[index]}
}

world_is_alive :: proc(w: ^World, e: Entity) -> bool {
	return int(
		e.index,
	) < len(w.alive) && w.alive[e.index] && w.generations[e.index] == e.generation
}

// Despawns are deferred: systems may call this while iterating pools, and the
// slots are only recycled at `world_flush_despawns`, so nothing aliases a live
// entity mid-tick.
world_despawn :: proc(w: ^World, e: Entity) {
	if !world_is_alive(w, e) {return}
	append(&w.destroy_queue, e)
}

world_flush_despawns :: proc(w: ^World) {
	if len(w.destroy_queue) == 0 {return}
	for e in w.destroy_queue {
		if !world_is_alive(w, e) {continue}
		for _, entry in w.pools {entry.remove_index(entry.ptr, e.index)}
		w.alive[e.index] = false
		w.generations[e.index] += 1
		w.alive_count -= 1
		w.revision += 1
		append(&w.free, e.index)
	}
	clear(&w.destroy_queue)
}

// --- Typed component access ---------------------------------------------

world_set :: proc(w: ^World, e: Entity, value: $T) {
	if !world_is_alive(w, e) {return}
	p := world_pool(w, T)
	if !pool_has(p, e.index) {w.revision += 1}
	pool_set(p, e.index, value)
}

world_get :: proc(w: ^World, e: Entity, $T: typeid) -> ^T {
	if !world_is_alive(w, e) {return nil}
	p := world_pool(w, T)
	if !pool_has(p, e.index) {return nil}
	return pool_get(p, e.index)
}

world_has :: proc(w: ^World, e: Entity, $T: typeid) -> bool {
	if !world_is_alive(w, e) {return false}
	return pool_has(world_pool(w, T), e.index)
}

world_remove :: proc(w: ^World, e: Entity, $T: typeid) {
	if !world_is_alive(w, e) {return}
	p := world_pool(w, T)
	if pool_has(p, e.index) {w.revision += 1}
	pool_remove(p, e.index)
}
