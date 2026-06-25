package foundation

import "core:time"

Timer :: struct {start: f64, elapsed: f64}

timer_start :: proc(t: ^Timer) {t.start = _get_time(); t.elapsed = 0}
timer_tick :: proc(t: ^Timer) -> f64 {now := _get_time(); t.elapsed = now - t.start; t.start = now; return t.elapsed}
timer_elapsed_ms :: proc(t: ^Timer) -> f64 {return t.elapsed * 1000.0}

@(private) _get_time :: proc() -> f64 {return f64(time.tick_now()._nsec) / 1e9}
