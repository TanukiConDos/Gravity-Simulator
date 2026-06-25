package foundation

import "core:c"
import "core:os"

read_entire_file :: proc(filename: string) -> ([]byte, bool) {
	data, ok := os.read_entire_file(filename, context.temp_allocator)
	return data, ok
}

write_file :: proc(filename: string, data: []byte) -> bool {
	ok := os.write_entire_file(filename, data)
	return ok
}
