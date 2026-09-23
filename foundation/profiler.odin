package foundation

import spall "core:prof/spall"
import "core:fmt"
import "core:sync"

// spall tracing, compiled in only with `-define:PROFILE=true`. When the gate is
// off every call below folds away: profile_scope's body is empty and its
// deferred end is empty, so call sites need no `when`.
//
// The spall *viewer* only understands Begin, End, Name_Thread and Name_Process;
// there are no counter or instant events in the wire format, so extra data is
// carried as free-form `args` text on a Begin (shown as "user data") and
// point-in-time facts become zero-duration spans (profile_mark).
//
// `profile_scope_args` keeps its formatting inside the `when`, so builds without
// the flag pay neither the format nor any allocation: the only thing evaluated
// at the call site is a stack `[]any`.
//
// profile_start must be called before any worker thread starts producing spans
// (it is cheap to call earlier); worker threads lazily pick up the active
// context on their first job.
PROFILE_ENABLED :: #config(PROFILE, false)

// Per-thread event buffer. A larger buffer means fewer flushes (and fewer
// synthetic "Buffer Flush" spans) but more resident memory per thread.
PROFILE_BUFFER_SIZE :: spall.BUFFER_DEFAULT_SIZE

// Upper bound on the formatted `args` string; longer text is truncated.
PROFILE_ARG_MAX :: 512

@(private)
_profile_ctx: spall.Context
@(private)
_profile_active: bool

@(thread_local)
_profile_buffer: spall.Buffer
@(thread_local)
_profile_buffer_ready: bool
@(thread_local)
_profile_named: bool
@(thread_local)
_profile_backing: []u8
@(thread_local)
_profile_scratch: [PROFILE_ARG_MAX]u8

profile_start :: proc(filename: string) {
	when PROFILE_ENABLED {
		if _profile_active {return}
		ctx, ok := spall.context_create(filename)
		if !ok {return}
		_profile_ctx = ctx
		_profile_active = true
		_profile_thread_buffer_init()
	}
}

profile_stop :: proc() {
	when PROFILE_ENABLED {
		if !_profile_active {return}
		if _profile_buffer_ready {
			spall.buffer_destroy(&_profile_ctx, &_profile_buffer)
			delete(_profile_backing)
			_profile_backing = nil
			_profile_buffer_ready = false
			_profile_named = false
		}
		spall.context_destroy(&_profile_ctx)
		_profile_active = false
	}
}

// Labels the process in the trace viewer. Written once, typically right after
// profile_start, before threads start producing spans.
profile_process_name :: proc(name: string) {
	when PROFILE_ENABLED {
		if _profile_active && _profile_buffer_ready {
			spall._buffer_name_process(&_profile_ctx, &_profile_buffer, name)
		}
	}
}

@(private)
_profile_thread_buffer_init :: proc() {
	if !_profile_active || _profile_buffer_ready {return}
	_profile_backing = make([]u8, PROFILE_BUFFER_SIZE)
	_profile_buffer = spall.buffer_create(_profile_backing, u32(sync.current_thread_id()))
	_profile_buffer_ready = true
	_profile_named = false
}

// Worker threads call this per job; the first call gives the thread its own
// buffer, so parallel work shows up as separate timelines.
profile_thread_ensure :: proc() {
	when PROFILE_ENABLED {
		_profile_thread_buffer_init()
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

// Same as profile_thread_name but with a numeric suffix (e.g. "worker.3"). The
// formatted name is only built the first time, so per-job calls stay cheap.
profile_thread_name_id :: proc(prefix: string, id: int) {
	when PROFILE_ENABLED {
		if !_profile_active || !_profile_buffer_ready || _profile_named {return}
		text := fmt.bprintf(_profile_scratch[:], "%s.%d", prefix, id)
		spall._buffer_name_thread(&_profile_ctx, &_profile_buffer, text)
		_profile_named = true
	}
}

// Worker buffers are never destroyed by the main thread (thread-local state);
// each thread flushes and releases its own buffer on exit. The context must
// still be alive, so threads have to be joined before profile_stop.
profile_thread_destroy :: proc() {
	when PROFILE_ENABLED {
		if !_profile_buffer_ready {return}
		if _profile_active {
			spall.buffer_destroy(&_profile_ctx, &_profile_buffer)
		}
		delete(_profile_backing)
		_profile_backing = nil
		_profile_buffer_ready = false
		_profile_named = false
	}
}

// Flushes outstanding events without tearing the buffer down; used by worker
// threads between jobs so their timeline is written out promptly.
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

// Records a span whose `args` are formatted with `format`/`args` (printf style)
// only when tracing is enabled. The `[]any` literal is a stack array, so
// disabled builds pay for neither the format nor an allocation.
@(deferred_in=_profile_scope_args_end)
profile_scope_args :: #force_inline proc(name, format: string, args: []any) {
	when PROFILE_ENABLED {
		if _profile_active && _profile_buffer_ready {
			text: string
			if format != "" {
				text = fmt.bprintf(_profile_scratch[:], format, ..args)
			}
			spall._buffer_begin(&_profile_ctx, &_profile_buffer, name, text)
		}
	}
}

@(private)
_profile_scope_args_end :: proc(name, format: string, args: []any) {
	when PROFILE_ENABLED {
		if _profile_active && _profile_buffer_ready {
			spall._buffer_end(&_profile_ctx, &_profile_buffer)
		}
	}
}

// Zero-duration span: a point-in-time fact with formatted args. The nearest
// thing to an instant marker the spall format supports.
profile_mark :: #force_inline proc(name, format: string, args: []any) {
	when PROFILE_ENABLED {
		if _profile_active && _profile_buffer_ready {
			text: string
			if format != "" {
				text = fmt.bprintf(_profile_scratch[:], format, ..args)
			}
			spall._buffer_begin(&_profile_ctx, &_profile_buffer, name, text)
			spall._buffer_end(&_profile_ctx, &_profile_buffer)
		}
	}
}
