package tests

import ecs "../Engine/ecs"
import physics "../Engine/physic"
import foundation "../foundation"
import "core:sync"
import "core:testing"
import "core:thread"

@(private)
_Snapshot_Writer :: struct {
	w:        ^ecs.World,
	entities: []ecs.Entity,
	versions: int,
}

@(private)
_snapshot_writer_main :: proc(t: ^thread.Thread) {
	ctx := cast(^_Snapshot_Writer)t.data
	for v in 1 ..= ctx.versions {
		for e in ctx.entities {
			pos := ecs.world_get(ctx.w, e, physics.Position)
			pos.x = f32(v)
		}
		physics.physic_snapshot_publish(ctx.w)
	}
}

@(private)
_Snapshot_Reader :: struct {
	snapshot: ^physics.RenderSnapshot,
	buf:      []physics.Vec3,
	done:     ^i32,
	reads:    ^i32,
	bad:      ^bool,
}

@(private)
_snapshot_reader_main :: proc(t: ^thread.Thread) {
	ctx := cast(^_Snapshot_Reader)t.data
	for sync.atomic_load(ctx.done) == 0 {
		n := physics.physic_snapshot_read(
			ctx.snapshot,
			raw_data(ctx.buf),
			nil,
			len(ctx.buf),
		)
		if n == 0 {continue}
		v := ctx.buf[0].x
		for i in 1 ..< n {
			if ctx.buf[i].x != v {
				ctx.bad^ = true
				break
			}
		}
		sync.atomic_add(ctx.reads, 1)
	}
}

// A single publish is visible to a read, and the published version is complete.
@(test)
test_snapshot_roundtrip :: proc(t: ^testing.T) {
	w := ecs.world_create()
	defer ecs.world_destroy(w)

	entities: [4]ecs.Entity
	for i in 0 ..< len(entities) {
		entities[i] = physics.body_spawn(w, {f32(i), 0, 0}, {0, 0, 0}, 1, 1)
	}
	physics.physic_init(w, foundation.Config{algorithm = .BRUTE_FORCE})

	for e in entities {
		ecs.world_get(w, e, physics.Position).x = 7
	}
	physics.physic_snapshot_publish(w)

	buf: [4]physics.Vec3
	snapshot := physics.physic_snapshot(w)
	n := physics.physic_snapshot_read(snapshot, raw_data(buf[:]), nil, len(buf))
	testing.expect_value(t, n, 4)
	for i in 0 ..< n {
		testing.expect_value(t, buf[i].x, f32(7))
	}
}

// A reader must never observe a torn publish: every snapshot it claims is one
// consistent version (all x equal to the same value).
@(test)
test_snapshot_concurrent_reader :: proc(t: ^testing.T) {
	w := ecs.world_create()
	defer ecs.world_destroy(w)

	N :: 64
	entities := make([]ecs.Entity, N)
	defer delete(entities)
	for i in 0 ..< N {
		entities[i] = physics.body_spawn(w, {0, 0, 0}, {0, 0, 0}, 1, 1)
	}
	physics.physic_init(w, foundation.Config{algorithm = .BRUTE_FORCE})

	done: i32
	reads: i32
	bad := false
	reader_ctx := _Snapshot_Reader {
		snapshot = physics.physic_snapshot(w),
		buf      = make([]physics.Vec3, N),
		done     = &done,
		reads    = &reads,
		bad      = &bad,
	}
	defer delete(reader_ctx.buf)
	writer_ctx := _Snapshot_Writer {
		w        = w,
		entities = entities,
		versions = 2000,
	}

	writer := thread.create(_snapshot_writer_main, .Normal, "snap-writer")
	writer.data = &writer_ctx
	reader := thread.create(_snapshot_reader_main, .Normal, "snap-reader")
	reader.data = &reader_ctx
	thread.start(reader)
	thread.start(writer)
	thread.join(writer)
	sync.atomic_store(&done, 1)
	thread.join(reader)
	thread.destroy(writer)
	thread.destroy(reader)

	testing.expect(t, !bad, "reader observed a torn snapshot")
	testing.expect(t, sync.atomic_load(&reads) > 0, "reader made progress")
}
