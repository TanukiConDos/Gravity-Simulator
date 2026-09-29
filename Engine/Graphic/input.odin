package graphic

import ecs "../ecs"

@(private)
MOVE_SPEED   :: 500.0
@(private)
ROTATE_SPEED :: 1.0

// Set by the input system on a left-button press edge and consumed by
// renderer_draw_frame in the same phase, so it needs no locking. `u`/`v` are
// normalised window coordinates taken from the main-thread input snapshot; the
// renderer maps them to framebuffer pixels, which keeps window scaling out of
// this code.
@(private)
Pick_Request :: struct {
	requested: bool,
	prev_down: bool,
	u:         f32,
	v:         f32,
}

// RENDER-phase system: updates the Camera resource from the keyboard and turns
// left-click edges into pick requests. The graphics thread never calls GLFW; it
// reads the snapshot the main thread publishes in `window_pump`.
@(private)
input_system :: proc(w: ^ecs.World, delta_seconds: f32) -> bool {
	ref := ecs.world_resource(w, Window_Ref)
	if ref.window == nil {return true}
	cam := ecs.world_resource(w, Camera)
	input := window_input_snapshot(ref.window)
	input_poll(input, cam, delta_seconds)
	_input_pick(w, input)
	return true
}

// Edge-triggered: a pick is requested only on the press, so the readback never
// stalls the graphics thread for every frame the button is held.
@(private)
_input_pick :: proc(w: ^ecs.World, input: Input_State) {
	req := ecs.world_resource(w, Pick_Request)
	if input.mouse_down && !req.prev_down && input.fb_valid {
		req.u = input.cursor_u
		req.v = input.cursor_v
		req.requested = true
	}
	req.prev_down = input.mouse_down
}

@(private)
input_poll :: proc(input: Input_State, cam: ^Camera, delta_seconds: f32) {
	move := delta_seconds * MOVE_SPEED
	rotate := delta_seconds * ROTATE_SPEED

	if (input.keys & INPUT_KEY_W) != 0 {camera_move_forward(cam, move)}
	if (input.keys & INPUT_KEY_S) != 0 {camera_move_backward(cam, move)}
	if (input.keys & INPUT_KEY_A) != 0 {camera_move_left(cam, move)}
	if (input.keys & INPUT_KEY_D) != 0 {camera_move_right(cam, move)}
	if (input.keys & INPUT_KEY_Q) != 0 {camera_move_down(cam, move)}
	if (input.keys & INPUT_KEY_E) != 0 {camera_move_up(cam, move)}

	if (input.keys & INPUT_KEY_UP) != 0 {camera_rotate_pitch(cam, rotate)}
	if (input.keys & INPUT_KEY_DOWN) != 0 {camera_rotate_pitch(cam, -rotate)}
	if (input.keys & INPUT_KEY_LEFT) != 0 {camera_rotate_yaw(cam, -rotate)}
	if (input.keys & INPUT_KEY_RIGHT) != 0 {camera_rotate_yaw(cam, rotate)}
}
