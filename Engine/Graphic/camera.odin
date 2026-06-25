package graphic

import "core:math"
import la "core:math/linalg"

Camera :: struct {position: Vec3, target: Vec3, up: Vec3, fov: f32, near: f32, far: f32, aspect: f32}

camera_create :: proc(sc: ^SwapChain) -> Camera {return Camera{position={0,0,-4500},target={0,0,0},up={0,1,0},fov=70,near=0.1,far=1e10,aspect=f32(sc.extent.width)/f32(sc.extent.height)}}

camera_transform :: proc(c: ^Camera, ubo: ^UniformBufferObject) {
	ubo.view = la.matrix4_look_at_f32(c.position, c.target, c.up)
	ubo.proj = la.matrix4_perspective_f32(math.to_radians_f32(c.fov), c.aspect, c.near, c.far)
}

camera_move_forward :: proc(c: ^Camera, a: f32) {c.position.z+=a; c.target.z+=a}
camera_move_backward :: proc(c: ^Camera, a: f32) {camera_move_forward(c,-a)}
camera_move_left :: proc(c: ^Camera, a: f32) {c.position.x-=a; c.target.x-=a}
camera_move_right :: proc(c: ^Camera, a: f32) {camera_move_left(c,-a)}
camera_move_up :: proc(c: ^Camera, a: f32) {c.position.y+=a; c.target.y+=a}
camera_move_down :: proc(c: ^Camera, a: f32) {camera_move_up(c,-a)}
camera_rotate_up :: proc(c: ^Camera, a: f32) {c.target.y+=a}
camera_rotate_down :: proc(c: ^Camera, a: f32) {camera_rotate_up(c,-a)}
camera_rotate_left :: proc(c: ^Camera, a: f32) {c.target.x-=a}
camera_rotate_right :: proc(c: ^Camera, a: f32) {camera_rotate_left(c,-a)}
