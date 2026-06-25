package graphic

import "core:math"
import la "core:math/linalg"

Camera :: struct {position: Vec3, target: Vec3, up: Vec3, fov: f32, near: f32, far: f32, aspect: f32}

camera_create :: proc(swapchain: ^SwapChain) -> Camera {return Camera{position={0,0,-4500},target={0,0,0},up={0,1,0},fov=70,near=0.1,far=1e10,aspect=f32(swapchain.extent.width)/f32(swapchain.extent.height)}}

camera_transform :: proc(self: ^Camera, ubo: ^UniformBufferObject) {
	ubo.view = la.matrix4_look_at_f32(self.position, self.target, self.up)
	ubo.proj = la.matrix4_perspective_f32(math.to_radians_f32(self.fov), self.aspect, self.near, self.far)
}

camera_move_forward :: proc(self: ^Camera, amount: f32) {self.position.z+=amount; self.target.z+=amount}
camera_move_backward :: proc(self: ^Camera, amount: f32) {camera_move_forward(self,-amount)}
camera_move_left :: proc(self: ^Camera, amount: f32) {self.position.x-=amount; self.target.x-=amount}
camera_move_right :: proc(self: ^Camera, amount: f32) {camera_move_left(self,-amount)}
camera_move_up :: proc(self: ^Camera, amount: f32) {self.position.y+=amount; self.target.y+=amount}
camera_move_down :: proc(self: ^Camera, amount: f32) {camera_move_up(self,-amount)}
camera_rotate_up :: proc(self: ^Camera, amount: f32) {self.target.y+=amount}
camera_rotate_down :: proc(self: ^Camera, amount: f32) {camera_rotate_up(self,-amount)}
camera_rotate_left :: proc(self: ^Camera, amount: f32) {self.target.x-=amount}
camera_rotate_right :: proc(self: ^Camera, amount: f32) {camera_rotate_left(self,-amount)}
