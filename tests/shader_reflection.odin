package tests

import spirv "../Engine/Graphic/spirv"
import "core:os"
import "core:testing"
import "vendor:vulkan"

@(private)
_load_spirv :: proc(t: ^testing.T, path: string) -> []byte {
	code, err := os.read_entire_file(path, context.allocator)
	testing.expectf(t, err == nil, "cannot read shader module %s", path)
	if err != nil {return nil}
	return code
}

@(private)
_expect_input :: proc(t: ^testing.T, inputs: []spirv.Input, location: u32, format: vulkan.Format) {
	for input in inputs {
		if input.location == location {
			testing.expect_value(t, input.format, format)
			testing.expect(t, input.supported, "input format should be supported")
			return
		}
	}
	testing.expectf(t, false, "no shader input at location %d", location)
}

@(test)
test_spirv_vertex_reflection :: proc(t: ^testing.T) {
	code := _load_spirv(t, "Engine/Graphic/shader/vert.spv")
	if code == nil {return}
	defer delete(code, context.allocator)

	reflection, ok := spirv.reflect(code)
	testing.expect(t, ok, "vertex shader should reflect")
	if !ok {return}
	defer spirv.reflection_destroy(&reflection)

	testing.expect_value(t, reflection.stage, spirv.Stage.Vertex)
	testing.expect_value(t, reflection.entry_point, "main")
	testing.expect_value(t, len(reflection.inputs), 5)

	if len(reflection.inputs) == 5 {
		_expect_input(t, reflection.inputs, 0, .R32G32B32_SFLOAT)
		_expect_input(t, reflection.inputs, 1, .R32G32B32_SFLOAT)
		_expect_input(t, reflection.inputs, 2, .R32G32B32_SFLOAT)
		_expect_input(t, reflection.inputs, 3, .R32_SFLOAT)
		_expect_input(t, reflection.inputs, 4, .R32_SINT)
	}

	testing.expect_value(t, len(reflection.descriptors), 1)
	if len(reflection.descriptors) == 1 {
		descriptor := reflection.descriptors[0]
		testing.expect_value(t, descriptor.set, u32(0))
		testing.expect_value(t, descriptor.binding, u32(0))
		testing.expect_value(t, descriptor.descriptor, vulkan.DescriptorType.UNIFORM_BUFFER)
		testing.expect_value(t, descriptor.stage, vulkan.ShaderStageFlag.VERTEX)
	}
}

@(test)
test_spirv_fragment_reflection :: proc(t: ^testing.T) {
	code := _load_spirv(t, "Engine/Graphic/shader/frag.spv")
	if code == nil {return}
	defer delete(code, context.allocator)

	reflection, ok := spirv.reflect(code)
	testing.expect(t, ok, "fragment shader should reflect")
	if !ok {return}
	defer spirv.reflection_destroy(&reflection)

	testing.expect_value(t, reflection.stage, spirv.Stage.Fragment)
	testing.expect_value(t, len(reflection.inputs), 2)
	testing.expect_value(t, len(reflection.outputs), 2)
	if len(reflection.outputs) == 2 {
		testing.expect_value(t, reflection.outputs[0].location, u32(0))
		testing.expect_value(t, reflection.outputs[0].format, vulkan.Format.R32G32B32A32_SFLOAT)
		testing.expect_value(t, reflection.outputs[1].location, u32(1))
		testing.expect_value(t, reflection.outputs[1].format, vulkan.Format.R32_UINT)
	}
}

@(test)
test_spirv_descriptors_and_push_constants :: proc(t: ^testing.T) {
	code := _load_spirv(t, "tests/fixtures/probe_frag.spv")
	if code == nil {return}
	defer delete(code, context.allocator)

	reflection, ok := spirv.reflect(code)
	testing.expect(t, ok, "probe shader should reflect")
	if !ok {return}
	defer spirv.reflection_destroy(&reflection)

	testing.expect_value(t, len(reflection.descriptors), 1)
	if len(reflection.descriptors) == 1 {
		descriptor := reflection.descriptors[0]
		testing.expect_value(t, descriptor.set, u32(0))
		testing.expect_value(t, descriptor.binding, u32(1))
		testing.expect_value(t, descriptor.descriptor, vulkan.DescriptorType.COMBINED_IMAGE_SAMPLER)
		testing.expect_value(t, descriptor.stage, vulkan.ShaderStageFlag.FRAGMENT)
	}

	testing.expect_value(t, len(reflection.push_constants), 1)
	if len(reflection.push_constants) == 1 {
		push := reflection.push_constants[0]
		testing.expect_value(t, push.offset, u32(0))
		testing.expect_value(t, push.size, u32(80))
	}
}

@(test)
test_spirv_rejects_invalid_modules :: proc(t: ^testing.T) {
	// Malformed modules are logged at error level, which the test runner counts
	// as a failure; silence the logger while exercising the rejection paths.
	previous := context.logger
	context.logger.lowest_level = .Fatal
	defer context.logger = previous

	_, too_small := spirv.reflect([]byte{1, 2, 3, 4})
	testing.expect(t, !too_small, "a module shorter than the header should be rejected")

	bad_magic := []byte{0, 0, 0, 0, 1, 2, 3, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
	_, bad := spirv.reflect(bad_magic)
	testing.expect(t, !bad, "a module with a bad magic should be rejected")
}
