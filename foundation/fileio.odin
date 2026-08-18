package foundation

import "core:c"
import "core:os"

read_entire_file :: proc(filename: string) -> ([]byte, bool) {
	data, err := os.read_entire_file(filename, context.temp_allocator)
	return data, err == nil
}

write_file :: proc(filename: string, data: []byte) -> bool {
	err := os.write_entire_file(filename, data)
	return err == nil
}
