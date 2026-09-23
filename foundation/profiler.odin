package foundation

import spall "core:prof/spall"
import "core:sync"

// spall tracing, compiled in only with `-define:PROFILE=true`. When the gate is
// off every call below folds away: profile_scope's body is empty and its
// deferred end is empty, so call sites need no `when`.
//
// profile_start must be called before any worker thread starts producing spans
// (the bench ensures this by starting workers before enabling the trace).
PROFILE_ENABLED :: #config(PROFILE, false)

@(private)
_profile_ctx: spall.Context
@(private)
_profile_active: bool
@(private)
_profile_backing: []u8

@(thread_local)
_profile_buffer: spall.Buffer
@(thread_local)
_profile_buffer_ready: bool
@(thread_local)
_profile_named: bool

profile_start :: proc(filename: string) {
	when PROFILE_ENABLED {
		if _profile_active {return}
		ctx, ok := spall.context_create(filename)
		if !ok {return}
		_profile_ctx = ctx
		_profile_backing = make([]u8, spall.BUFFER_DEFAULT_SIZE)
		_profile_buffer = spall.buffer_create(
			_profile_backing,
			u32(sync.current_thread_id()),
		)
		_profile_buffer_ready = true
		_profile_named = false
		_profile_active = true
	}
}

profile_stop :: proc() {
	when PROFILE_ENABLED {
		if !_profile_active {return}
		spall.buffer_destroy(&_profile_ctx, &_profile_buffer)
		spall.context_destroy(&_profile_ctx)
		delete(_profile_backing)
		_profile_backing = nil
		_profile_buffer_ready = false
		_profile_active = false
	}
}

// Worker threads call this per job; the first call gives the thread its own
// buffer, so parallel work shows up as separate timelines.
profile_thread_ensure :: proc() {
	when PROFILE_ENABLED {
		if !_profile_active || _profile_buffer_ready {return}
		backing := make([]u8, spall.BUFFER_DEFAULT_SIZE)
		_profile_buffer = spall.buffer_create(backing, u32(sync.current_thread_id()))
		_profile_buffer_ready = true
		_profile_named = false
	}
}

// Labels the calling thread's timeline in the trace viewer (no-op after the
// first call per thread, so it is safe to call every job).
profile_thread_name :: proc(name: string) {
	when PROFILE_ENABLED {
		if !_profile_active || !_profile_buffer_ready || _profile_named {return}
		spall._buffer_name_thread(&_profile_ctx, &_profile_buffer, name)
		_profile_named = true
	}
}

// Worker buffers are never destroyed (the main thread owns context_stop), so
// their events are written out by flushing explicitly.
profile_thread_flush :: proc() {
	when PROFILE_ENABLED {
		if _profile_active && _profile_buffer_ready {
			spall.buffer_flush(&_profile_ctx, &_profile_buffer)
		}
	}
}

// Records a span named `name` that ends at the end of the enclosing scope.
@(deferred_in=_profile_scope_end)
profile_scope :: #force_inline proc(name: string, args := "") {
	when PROFILE_ENABLED {
		if _profile_active && _profile_buffer_ready {
			spall._buffer_begin(&_profile_ctx, &_profile_buffer, name, args)
		}
	}
}

@(private)
_profile_scope_end :: #force_inline proc(name: string, args: string) {
	when PROFILE_ENABLED {
		if _profile_active && _profile_buffer_ready {
			spall._buffer_end(&_profile_ctx, &_profile_buffer)
		}
	}
}
