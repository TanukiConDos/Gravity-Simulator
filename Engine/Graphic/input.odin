package graphic

InputAction :: enum {NONE, MOVE_FORWARD, MOVE_BACKWARD, MOVE_LEFT_SIDE, MOVE_RIGHT_SIDE, MOVE_UP, MOVE_DOWN, ROTATE_UP, ROTATE_DOWN, ROTATE_LEFT, ROTATE_RIGHT}
InputEvent :: struct {action: InputAction, camera: ^Camera}

input_submit :: proc(event: ^InputEvent, a: InputAction) {event.action = a}
input_subscribe :: proc(event: ^InputEvent, cam: ^Camera) {event.camera = cam}

input_process :: proc(event: ^InputEvent, delta: f32) {
	amount := delta * 50.0
	switch event.action {
	case .MOVE_FORWARD: event.camera.position.z+=amount; event.camera.target.z+=amount
	case .MOVE_BACKWARD: event.camera.position.z-=amount; event.camera.target.z-=amount
	case .MOVE_LEFT_SIDE: event.camera.position.x-=amount; event.camera.target.x-=amount
	case .MOVE_RIGHT_SIDE: event.camera.position.x+=amount; event.camera.target.x+=amount
	case .MOVE_UP: event.camera.position.y+=amount; event.camera.target.y+=amount
	case .MOVE_DOWN: event.camera.position.y-=amount; event.camera.target.y-=amount
	case .ROTATE_UP: event.camera.target.y+=amount*0.5
	case .ROTATE_DOWN: event.camera.target.y-=amount*0.5
	case .ROTATE_LEFT: event.camera.target.x-=amount*0.5
	case .ROTATE_RIGHT: event.camera.target.x+=amount*0.5
	case .NONE:
	}
	event.action = .NONE
}
