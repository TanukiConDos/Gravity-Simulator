package graphic

InputAction :: enum {NONE, MOVE_FORWARD, MOVE_BACKWARD, MOVE_LEFT_SIDE, MOVE_RIGHT_SIDE, MOVE_UP, MOVE_DOWN, ROTATE_UP, ROTATE_DOWN, ROTATE_LEFT, ROTATE_RIGHT}
InputEvent :: struct {action: InputAction, camera: ^Camera}

input_submit :: proc(e: ^InputEvent, a: InputAction) {e.action = a}
input_subscribe :: proc(e: ^InputEvent, cam: ^Camera) {e.camera = cam}

input_process :: proc(e: ^InputEvent, delta: f32) {
	amount := delta * 50.0
	switch e.action {
	case .MOVE_FORWARD: e.camera.position.z+=amount; e.camera.target.z+=amount
	case .MOVE_BACKWARD: e.camera.position.z-=amount; e.camera.target.z-=amount
	case .MOVE_LEFT_SIDE: e.camera.position.x-=amount; e.camera.target.x-=amount
	case .MOVE_RIGHT_SIDE: e.camera.position.x+=amount; e.camera.target.x+=amount
	case .MOVE_UP: e.camera.position.y+=amount; e.camera.target.y+=amount
	case .MOVE_DOWN: e.camera.position.y-=amount; e.camera.target.y-=amount
	case .ROTATE_UP: e.camera.target.y+=amount*0.5
	case .ROTATE_DOWN: e.camera.target.y-=amount*0.5
	case .ROTATE_LEFT: e.camera.target.x-=amount*0.5
	case .ROTATE_RIGHT: e.camera.target.x+=amount*0.5
	case .NONE:
	}
	e.action = .NONE
}
