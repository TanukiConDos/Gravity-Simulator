package ecs

// Entity handles are index+generation pairs. The generation invalidates handles
// to recycled slots: despawning bumps it, so a stale handle can never alias the
// entity that reuses its index.
Entity :: struct {
	index:      u32,
	generation: u32,
}

MAX_U32 :: u32(0xFFFFFFFF)

ENTITY_NONE :: Entity {
	index      = MAX_U32,
	generation = MAX_U32,
}
