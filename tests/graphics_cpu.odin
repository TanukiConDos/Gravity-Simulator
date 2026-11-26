package tests

import graphic "engine:graphics/front"
import gfx "engine:graphics/shared"
import "core:testing"

// The front's camera math and the seam layout are backend-agnostic, so they are
// pinned here instead of in the device tests.

@(test)
test_camera_uniforms :: proc(t: ^testing.T) {
	cam := graphic.camera_create(16.0 / 9.0)
	testing.expect_value(t, cam.aspect, f32(16.0 / 9.0))

	graphic.camera_set_aspect(&cam, 1920, 1080)
	testing.expect_value(t, cam.aspect, f32(1920.0 / 1080.0))

	// Invalid (minimized) framebuffer sizes must not change the projection.
	before := cam.aspect
	graphic.camera_set_aspect(&cam, 0, 0)
	testing.expect_value(t, cam.aspect, before)

	ubo := graphic.camera_uniforms(&cam)
	testing.expect_value(t, size_of(ubo), size_of(gfx.Camera_Uniforms))
	for column in 0 ..< 4 {
		for row in 0 ..< 4 {
			v := ubo.view[column][row]
			testing.expect(t, v == v)
		}
	}
	for column in 0 ..< 4 {
		for row in 0 ..< 4 {
			v := ubo.proj[column][row]
			testing.expect(t, v == v)
		}
	}
	// The projection must actually depend on the near/far planes; an all-zero
	// matrix would pass the finiteness check above.
	testing.expect(t, ubo.proj[2][2] != 0 || ubo.proj[3][2] != 0)
}

@(test)
test_gfx_seam_layout :: proc(t: ^testing.T) {
	// The backend uploads this block as-is; the shader reads it as std140.
	testing.expect_value(t, size_of(gfx.Camera_Uniforms), 128)
	testing.expect_value(t, gfx.MESH_PRIMARY, gfx.Mesh_Handle(1))
	testing.expect_value(t, u32(gfx.Instance_Mode.CPU), u32(0))
}
