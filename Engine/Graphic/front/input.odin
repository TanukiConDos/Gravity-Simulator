package graphic

import gfx "../shared"
import ecs "../../ecs"
import "core:sync"

@(private)
MOVE_SPEED   :: 500.0
@(private)
ROTATE_SPEED :: 1.0

// RENDER-phase system: updates the Camera resource from the keyboard and turns
// left-click edges into pick requests. The graphics thread never calls GLFW; it
// reads the snapshot the main thread publishes in `vk.window_pump` (through the
// world resource `Window_Ref`).
@(private)
input_system :: proc(w: ^ecs.World, delta_seconds: f32) -> bool {
	ref := ecs.world_resource(w, Window_Ref)
	if ref.input == nil {return true}
	cam := ecs.world_resource(w, Camera)
	input := _input_snapshot(ref.input)
	camera_set_aspect(cam, input.fb_width, input.fb_height)
	input_poll(input, cam, delta_seconds)
	_input_pick(w, input)
	return true
}

// Each field is atomic, so a tear across fields only ever mixes two adjacent
// pumps. `fb_valid` is stored last by the publisher, so a reader that sees
// `true` also sees a complete framebuffer size.
@(private)
_input_snapshot :: proc(input: ^gfx.Input_State) -> gfx.Input_State {
	return gfx.Input_State{
		keys = sync.atomic_load(&input.keys),
		mouse_down = sync.atomic_load(&input.mouse_down),
		cursor_u = sync.atomic_load(&input.cursor_u),
		cursor_v = sync.atomic_load(&input.cursor_v),
		fb_width = sync.atomic_load(&input.fb_width),
		fb_height = sync.atomic_load(&input.fb_height),
		fb_valid = sync.atomic_load(&input.fb_valid),
	}
}

// Edge-triggered: a pick is requested only on the press, so the readback never
// stalls the graphics thread for every frame the button is held.
@(private)
_input_pick :: proc(w: ^ecs.World, input: gfx.Input_State) {
	req := ecs.world_resource(w, Pick_Request)
	if input.mouse_down && !req.prev_down && input.fb_valid {
		req.u = input.cursor_u
		req.v = input.cursor_v
		req.requested = true
	}
	req.prev_down = input.mouse_down
}

@(private)
input_poll :: proc(input: gfx.Input_State, cam: ^Camera, delta_seconds: f32) {
	move := delta_seconds * MOVE_SPEED
	rotate := delta_seconds * ROTATE_SPEED

	if (input.keys & gfx.INPUT_KEY_W) != 0 {camera_move_forward(cam, move)}
	if (input.keys & gfx.INPUT_KEY_S) != 0 {camera_move_backward(cam, move)}
	if (input.keys & gfx.INPUT_KEY_A) != 0 {camera_move_left(cam, move)}
	if (input.keys & gfx.INPUT_KEY_D) != 0 {camera_move_right(cam, move)}
	if (input.keys & gfx.INPUT_KEY_Q) != 0 {camera_move_down(cam, move)}
	if (input.keys & gfx.INPUT_KEY_E) != 0 {camera_move_up(cam, move)}

	if (input.keys & gfx.INPUT_KEY_UP) != 0 {camera_rotate_pitch(cam, rotate)}
	if (input.keys & gfx.INPUT_KEY_DOWN) != 0 {camera_rotate_pitch(cam, -rotate)}
	if (input.keys & gfx.INPUT_KEY_LEFT) != 0 {camera_rotate_yaw(cam, -rotate)}
	if (input.keys & gfx.INPUT_KEY_RIGHT) != 0 {camera_rotate_yaw(cam, rotate)}
}
