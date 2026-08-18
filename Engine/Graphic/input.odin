package graphic

import "vendor:glfw"

MOVE_SPEED   :: 500.0
ROTATE_SPEED :: 1.0

input_poll :: proc(w: ^Window, cam: ^Camera, delta_seconds: f32) {
	move := delta_seconds * MOVE_SPEED
	rotate := delta_seconds * ROTATE_SPEED

	if glfw.GetKey(w.handle, glfw.KEY_W) == glfw.PRESS {camera_move_forward(cam, move)}
	if glfw.GetKey(w.handle, glfw.KEY_S) == glfw.PRESS {camera_move_backward(cam, move)}
	if glfw.GetKey(w.handle, glfw.KEY_A) == glfw.PRESS {camera_move_left(cam, move)}
	if glfw.GetKey(w.handle, glfw.KEY_D) == glfw.PRESS {camera_move_right(cam, move)}
	if glfw.GetKey(w.handle, glfw.KEY_Q) == glfw.PRESS {camera_move_down(cam, move)}
	if glfw.GetKey(w.handle, glfw.KEY_E) == glfw.PRESS {camera_move_up(cam, move)}

	if glfw.GetKey(w.handle, glfw.KEY_UP) == glfw.PRESS {camera_rotate_pitch(cam, rotate)}
	if glfw.GetKey(w.handle, glfw.KEY_DOWN) == glfw.PRESS {camera_rotate_pitch(cam, -rotate)}
	if glfw.GetKey(w.handle, glfw.KEY_LEFT) == glfw.PRESS {camera_rotate_yaw(cam, -rotate)}
	if glfw.GetKey(w.handle, glfw.KEY_RIGHT) == glfw.PRESS {camera_rotate_yaw(cam, rotate)}
}
