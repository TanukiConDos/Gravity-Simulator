package ecs

import "core:log"

// The world owns the entity registry and every component pool and resource.
// Pools and resources are keyed by `typeid` and reached through the generic
// accessors below; systems cache the returned pointer and never look it up in a
// hot loop.
//
// Threading: the world is not synchronised. One thread owns it at a time. In this
// engine the physics thread owns the simulation components and the graphics
// thread only reads a snapshot resource, matching the pre-ECS ownership model.
// `world_reserve` + `world_freeze` formalise that split: all pools and resources
// are registered during setup, and after freeze the registries are read-only so
// the two threads may look values up concurrently.
World :: struct {
	generations:   [dynamic]u32,
	alive:         [dynamic]bool,
	free:          [dynamic]u32,
	alive_count:   int,
	// Entity index budget set by `world_reserve`; 0 means unlimited until freeze.
	capacity:      int,
	frozen:        bool,
	// Bumped on structural changes only (spawn/despawn/component add/remove),
	// never on value updates. Physics uses it to know when its octree is stale.
	revision:      u64,
	pools:         map[typeid]Pool_Entry,
	resources:     map[typeid]Resource_Entry,
	deferred:      [dynamic]Deferred,
}

// A queued structural change: despawn, component write or component removal.
// `data` is an owned heap copy for `.SET` (released by `apply`); `apply` carries
// the concrete component type across the type erasure the queue needs.
@(private)
Deferred_Kind :: enum {
	DESPAWN,
	SET,
	REMOVE,
}

@(private)
Deferred :: struct {
	entity: Entity,
	kind:   Deferred_Kind,
	data:   rawptr,
	apply:  proc(w: ^World, e: Entity, data: rawptr),
}

@(private)
Pool_Entry :: struct {
	ptr:          rawptr,
	destroy:      proc(ptr: rawptr),
	remove_index: proc(ptr: rawptr, index: u32),
	reserve:      proc(ptr: rawptr, capacity: int),
	validate:     proc(ptr: rawptr) -> bool,
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
	for op in w.deferred {
		if op.data != nil {free(op.data)}
	}
	delete(w.deferred)
	free(w)
}

// --- Capacity ------------------------------------------------------------

// Reserves room for `max_entities` live entities. Pools created afterwards are
// sized automatically; pools that already exist are grown here. Only grows, and
// is a no-op once the world is frozen: a resize after freeze would relocate the
// columns that systems are iterating.
world_reserve :: proc(w: ^World, max_entities: int) {
	if max_entities <= w.capacity {return}
	if w.frozen {
		log.errorf(
			"[ECS] world_reserve(%d) ignored: world is frozen at capacity %d",
			max_entities,
			w.capacity,
		)
		return
	}
	w.capacity = max_entities
	// Reserve the registry but let `world_spawn` grow the logical length as
	// entities appear, so an index is always `len(generations)` and the arrays
	// cover exactly the indices in use up to the capacity.
	reserve(&w.generations, max_entities)
	reserve(&w.alive, max_entities)
	reserve(&w.free, max_entities)
	for _, entry in w.pools {entry.reserve(entry.ptr, max_entities)}
}

// Freezes the world for concurrent use: no new pool or resource may be created
// and columns may not be grown. Call once after every pool/resource used by the
// threads has been registered, before starting them.
world_freeze :: proc(w: ^World) {
	w.frozen = true
}

// --- Pools ---------------------------------------------------------------

world_pool :: proc(w: ^World, $T: typeid) -> ^Pool(T) {
	if entry, ok := w.pools[typeid_of(T)]; ok {
		return cast(^Pool(T))entry.ptr
	}
	if w.frozen {
		// A new pool after freeze means the component was not registered during
		// setup, so creating it here can race with the other thread.
		assert(false, "world_pool: new pool requested after world_freeze")
		log.errorf("[ECS] new pool %v requested after world_freeze", typeid_of(T))
	}
	p := new(Pool(T))
	if w.capacity > 0 {pool_reserve(p, w.capacity)}
	w.pools[typeid_of(T)] = Pool_Entry {
		ptr          = p,
		destroy      = _pool_entry_destroy(T),
		remove_index = _pool_entry_remove(T),
		reserve      = _pool_entry_reserve(T),
		validate     = _pool_entry_validate(T),
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

@(private)
_pool_entry_reserve :: proc($T: typeid) -> proc(ptr: rawptr, capacity: int) {
	return proc(ptr: rawptr, capacity: int) {pool_reserve(cast(^Pool(T))ptr, capacity)}
}

@(private)
_pool_entry_validate :: proc($T: typeid) -> proc(ptr: rawptr) -> bool {
	return proc(ptr: rawptr) -> bool {return pool_validate(cast(^Pool(T))ptr)}
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
	if w.frozen {
		assert(false, "world_resource: new resource requested after world_freeze")
		log.errorf("[ECS] new resource %v requested after world_freeze", typeid_of(T))
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
		if w.frozen && len(w.generations) >= w.capacity {
			log.warnf(
				"[ECS] world_spawn: capacity %d exhausted (reserve a larger world)",
				w.capacity,
			)
			return ENTITY_NONE
		}
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
// slots are only recycled at `world_flush`, so nothing aliases a live entity
// mid-tick. The pending operations are visible to the owner thread only.
world_despawn :: proc(w: ^World, e: Entity) {
	if !world_is_alive(w, e) {return}
	append(&w.deferred, Deferred{entity = e, kind = .DESPAWN})
}

// Queues a component write for the next `world_flush`. Use this to add a
// component while iterating a view; `world_set` would relocate `dense` under it.
world_defer_set :: proc(w: ^World, e: Entity, value: $T) {
	if !world_is_alive(w, e) {return}
	_ = world_pool(w, T)
	data := new(T)
	data^ = value
	append(
		&w.deferred,
		Deferred {
			entity = e,
			kind = .SET,
			data = rawptr(data),
			apply = _deferred_set(T),
		},
	)
}

// Queues a component removal for the next `world_flush`.
world_defer_remove :: proc(w: ^World, e: Entity, $T: typeid) {
	if !world_is_alive(w, e) {return}
	_ = world_pool(w, T)
	append(&w.deferred, Deferred{entity = e, kind = .REMOVE, apply = _deferred_remove(T)})
}

@(private)
_deferred_set :: proc($T: typeid) -> proc(w: ^World, e: Entity, data: rawptr) {
	return proc(w: ^World, e: Entity, data: rawptr) {
		world_set(w, e, (cast(^T)data)^)
		free(data)
	}
}

@(private)
_deferred_remove :: proc($T: typeid) -> proc(w: ^World, e: Entity, data: rawptr) {
	return proc(w: ^World, e: Entity, data: rawptr) {world_remove(w, e, T)}
}

// Applies every deferred despawn/component change in submission order, then
// clears the queue. Called by the owner thread (the physics loop) at the end of
// a tick.
world_flush :: proc(w: ^World) {
	if len(w.deferred) == 0 {return}
	for op in w.deferred {
		switch op.kind {
		case .DESPAWN:
			_apply_despawn(w, op.entity)
		case .SET, .REMOVE:
			op.apply(w, op.entity, op.data)
		}
	}
	clear(&w.deferred)
}

@(private)
_apply_despawn :: proc(w: ^World, e: Entity) {
	if !world_is_alive(w, e) {return}
	for _, entry in w.pools {entry.remove_index(entry.ptr, e.index)}
	w.alive[e.index] = false
	w.alive_count -= 1
	w.revision += 1
	// Retire a slot whose generation would wrap: reusing it would let a stale
	// handle alias the next occupant.
	if w.generations[e.index] == MAX_U32 {return}
	w.generations[e.index] += 1
	append(&w.free, e.index)
}

// Verifies the registry invariants (alive/free consistency and every pool's
// dense bijection). Intended for tests and debug builds.
world_validate :: proc(w: ^World) -> bool {
	ok := true
	if len(w.generations) != len(w.alive) {
		log.errorf("[ECS] validate: generations/alive length mismatch")
		ok = false
	}
	alive_count := 0
	for i in 0 ..< len(w.alive) {
		if w.alive[i] {alive_count += 1}
	}
	if alive_count != w.alive_count {
		log.errorf(
			"[ECS] validate: alive_count %d does not match registry %d",
			w.alive_count,
			alive_count,
		)
		ok = false
	}
	free_seen := make([]bool, len(w.alive), context.temp_allocator)
	defer delete(free_seen, context.temp_allocator)
	for index in w.free {
		if int(index) >= len(w.alive) {
			log.errorf("[ECS] validate: free slot %d is out of range", index)
			ok = false
			continue
		}
		if w.alive[index] {
			log.errorf("[ECS] validate: free slot %d is alive", index)
			ok = false
		}
		if free_seen[index] {
			log.errorf("[ECS] validate: free slot %d appears twice", index)
			ok = false
		}
		free_seen[index] = true
	}
	for t, entry in w.pools {
		if !entry.validate(entry.ptr) {
			log.errorf("[ECS] validate: pool %v is inconsistent", t)
			ok = false
		}
	}
	return ok
}

// --- Typed component access ---------------------------------------------

world_set :: proc(w: ^World, e: Entity, value: $T) {
	if !world_is_alive(w, e) {return}
	if w.frozen && int(e.index) >= w.capacity {
		log.warnf(
			"[ECS] world_set(%v): index %d exceeds capacity %d",
			typeid_of(T),
			e.index,
			w.capacity,
		)
		return
	}
	p := world_pool(w, T)
	if p == nil {return}
	if !pool_has(p, e.index) {w.revision += 1}
	pool_set(p, e.index, value)
}

world_get :: proc(w: ^World, e: Entity, $T: typeid) -> ^T {
	if !world_is_alive(w, e) {return nil}
	p := world_pool(w, T)
	if p == nil || !pool_has(p, e.index) {return nil}
	return pool_get(p, e.index)
}

world_has :: proc(w: ^World, e: Entity, $T: typeid) -> bool {
	if !world_is_alive(w, e) {return false}
	p := world_pool(w, T)
	return p != nil && pool_has(p, e.index)
}

world_remove :: proc(w: ^World, e: Entity, $T: typeid) {
	if !world_is_alive(w, e) {return}
	p := world_pool(w, T)
	if p == nil {return}
	if pool_has(p, e.index) {w.revision += 1}
	pool_remove(p, e.index)
}
