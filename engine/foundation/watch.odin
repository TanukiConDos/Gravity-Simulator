package foundation

import "core:os"
import "core:time"

// File_Watch polls a file's modification time. `watch_poll` reports a change
// once per observed mtime and seeds itself on init, so a file that already
// exists does not trigger a reload at startup.
//
// Polling is deliberately simple: the engine has no portable file-watcher
// dependency, and the main loop already wakes often enough to check a handful
// of paths a few times per second.
File_Watch :: struct {
	path:  string,
	mtime: time.Time,
	valid: bool,
}

watch_file :: proc(path: string) -> File_Watch {
	w := File_Watch{path = path}
	if mtime, err := os.last_write_time_by_name(path); err == nil {
		w.mtime = mtime
		w.valid = true
	}
	return w
}

// watch_poll reports true when the file's mtime moved since the previous call.
// A file that cannot be read (missing, mid-rename) is ignored: the next
// successful stat seeds the baseline instead of triggering a spurious reload.
watch_poll :: proc(w: ^File_Watch) -> bool {
	if w == nil || len(w.path) == 0 {return false}
	mtime, err := os.last_write_time_by_name(w.path)
	if err != nil {return false}
	if !w.valid {
		w.mtime = mtime
		w.valid = true
		return false
	}
	if mtime == w.mtime {return false}
	w.mtime = mtime
	return true
}
