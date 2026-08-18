package graphic

import "core:math"
import la "core:math/linalg"

Camera :: struct {position: Vec3, target: Vec3, up: Vec3, fov: f32, near: f32, far: f32, aspect: f32}

camera_create :: proc(swapchain: ^SwapChain) -> Camera {return Camera{position={0,0,-4500},target={0,0,0},up={0,1,0},fov=70,near=0.1,far=1e10,aspect=f32(swapchain.extent.width)/f32(swapchain.extent.height)}}

camera_transform :: proc(self: ^Camera, ubo: ^UniformBufferObject) {
	ubo.view = la.matrix4_look_at_f32(self.position, self.target, self.up)
	ubo.proj = la.matrix4_perspective_f32(math.to_radians_f32(self.fov), self.aspect, self.near, self.far)
}

@(private) _camera_forward :: proc(self: ^Camera) -> Vec3 {return la.normalize(self.target - self.position)}
@(private) _camera_right :: proc(self: ^Camera) -> Vec3 {return la.normalize(la.cross(_camera_forward(self), self.up))}

camera_move :: proc(self: ^Camera, dir: Vec3, amount: f32) {self.position += dir * amount; self.target += dir * amount}
camera_move_forward :: proc(self: ^Camera, amount: f32) {camera_move(self, _camera_forward(self), amount)}
camera_move_backward :: proc(self: ^Camera, amount: f32) {camera_move_forward(self, -amount)}
camera_move_left :: proc(self: ^Camera, amount: f32) {camera_move(self, -_camera_right(self), amount)}
camera_move_right :: proc(self: ^Camera, amount: f32) {camera_move_left(self, -amount)}
camera_move_up :: proc(self: ^Camera, amount: f32) {camera_move(self, self.up, amount)}
camera_move_down :: proc(self: ^Camera, amount: f32) {camera_move_up(self, -amount)}

camera_rotate_yaw :: proc(self: ^Camera, radians: f32) {
	forward := _camera_forward(self)
	right := _camera_right(self)
	rot := la.matrix3_rotate_f32(radians, la.cross(right, forward))
	_set_forward(self, forward * rot)
}

camera_rotate_pitch :: proc(self: ^Camera, radians: f32) {
	forward := _camera_forward(self)
	rot := la.matrix3_rotate_f32(radians, _camera_right(self))
	_set_forward(self, forward * rot)
}

@(private) _set_forward :: proc(self: ^Camera, forward: Vec3) {
	new_forward := la.normalize(forward)
	clamp := f32(0.995)
	if la.abs(new_forward.y) > clamp {
		s := f32(1); if new_forward.y < 0 {s = -1}
		new_forward.y = s * clamp
		new_forward = la.normalize(new_forward)
	}
	distance := la.length(self.target - self.position)
	self.target = self.position + new_forward * distance
}
