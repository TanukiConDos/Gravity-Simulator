package foundation

import "core:time"

Timer :: struct {start: f64, elapsed: f64}

timer_start :: proc(self: ^Timer) {self.start = _get_time(); self.elapsed = 0}
timer_tick :: proc(self: ^Timer) -> f64 {now := _get_time(); self.elapsed = now - self.start; self.start = now; return self.elapsed}
timer_elapsed_ms :: proc(self: ^Timer) -> f64 {return self.elapsed * 1000.0}

@(private) _get_time :: proc() -> f64 {return f64(time.tick_now()._nsec) / 1e9}
