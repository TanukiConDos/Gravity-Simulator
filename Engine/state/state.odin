package state

import graphic "../graphic"
import phys "../physic"
import found "../../foundation"
import imgui "../../External/odin-imgui"
import "base:intrinsics"
import "core:c"

Action :: enum {DEFAULT, BEGIN_SIMULATION, CONFIGURATION, SAVE, EXIT}

StateMachine :: struct {
	state: State, objects: ^[dynamic]phys.PhysicObject, renderer: ^graphic.Renderer,
	frame_time: ^f32, tick_time: ^f32, config: ^found.Config,
	sim_init: proc(sm: ^StateMachine), sim_end: proc(sm: ^StateMachine),
}

State :: union {MainMenu, Config, Debug, ObjectSelected}
MainMenu :: struct {}
Config :: struct {}
Debug :: struct {inner: ^State}
ObjectSelected :: struct {inner: ^State, object_id: i32, old_id: i32}

@(private) _new_main_menu :: proc() -> State {return MainMenu{}}
@(private) _new_config :: proc() -> State {return Config{}}
@(private) _new_debug :: proc(inner: ^State) -> State {return Debug{inner = inner}}
@(private) _new_object_selected :: proc(sm: ^StateMachine, inner: ^State) -> State {
	o := ObjectSelected{inner = inner, object_id = 0, old_id = -1}
	if sm.objects != nil && len(sm.objects) > 0 {sm.objects[0].selected = true}
	return o
}

state_machine_create :: proc(renderer: ^graphic.Renderer, objects: ^[dynamic]phys.PhysicObject, config: ^found.Config, frame_time, tick_time: ^f32, sim_init, sim_end: proc(sm: ^StateMachine)) -> StateMachine {
	sm := StateMachine{objects = objects, renderer = renderer, frame_time = frame_time, tick_time = tick_time, config = config, sim_init = sim_init, sim_end = sim_end}
	sm.state = _new_main_menu()
	return sm
}

state_machine_destroy :: proc(sm: ^StateMachine) {state_destroy(&sm.state)}
state_machine_frame :: proc(sm: ^StateMachine) {state_frame(sm, &sm.state)}
state_machine_change :: proc(sm: ^StateMachine, action: Action) {state_change(sm, &sm.state, action)}

state_destroy :: proc(s: ^State) {
	#partial switch _ in s {
	case Debug: d := &s.(Debug); if d.inner != nil {state_destroy(d.inner); free(d.inner)}
	case ObjectSelected: o := &s.(ObjectSelected); if o.inner != nil {state_destroy(o.inner); free(o.inner)}
	}
}

state_frame :: proc(sm: ^StateMachine, s: ^State) {
	switch _ in s {
	case MainMenu: _main_menu_frame(sm)
	case Config: _config_frame(sm)
	case Debug: d := &s.(Debug); if d.inner != nil {state_frame(sm, d.inner)}; _debug_frame(sm)
	case ObjectSelected: o := &s.(ObjectSelected); if o.inner != nil {state_frame(sm, o.inner)}; _object_selected_frame(sm, o)
	}
}

state_change :: proc(sm: ^StateMachine, s: ^State, action: Action) {
	switch _ in s {
	case MainMenu: _main_menu_change(sm, s, action)
	case Config: _config_change(sm, s, action)
	case Debug: _debug_change(sm, s, action)
	case ObjectSelected: _object_selected_change(sm, s, action)
	}
}

@(private) NO_DECOR := imgui.WindowFlags{.NoTitleBar,.NoResize,.NoMove}
@(private) NO_FLAGS :: imgui.InputTextFlags{}
@(private) NO_COMBO :: imgui.ComboFlags{}

@(private) _center_window :: proc() {
	vp := imgui.GetMainViewport().Size; ws := imgui.GetWindowSize()
	imgui.SetWindowPos({(vp.x-ws.x)*0.5,(vp.y-ws.y)*0.5}, imgui.Cond.Always)
}

@(private) _main_menu_frame :: proc(sm: ^StateMachine) {
	imgui.Begin("MainMenu", nil, NO_DECOR)
	imgui.SetWindowSize({300,100}, imgui.Cond.Always); _center_window()
	imgui.Text("SIMULADOR DE FUERZA GRAVITATORIA")
	if imgui.Button("Iniciar Simulacion") {state_machine_change(sm, .BEGIN_SIMULATION)}
	if imgui.Button("Configuracion") {state_machine_change(sm, .CONFIGURATION)}
	imgui.End()
}

@(private) _main_menu_change :: proc(sm: ^StateMachine, s: ^State, action: Action) {
	#partial switch action {
	case .BEGIN_SIMULATION: sm.sim_init(sm); empty: State; inner := new_clone(empty); state_destroy(s); ds := _new_debug(inner); s^ = _new_object_selected(sm, new_clone(ds))
	case .CONFIGURATION: state_destroy(s); s^ = _new_config()
	}
}

@(private) _config_frame :: proc(sm: ^StateMachine) {
	cfg := sm.config
	imgui.Begin("Config", nil, NO_DECOR)
	imgui.SetWindowSize({750,200}, imgui.Cond.Always); _center_window()

	imgui.InputFloat("Multiplicador paso del tiempo", &cfg.time)

	mode := i32(cfg.system_creation_mode)
	_scene_preview := mode == 0 ? cstring("ALEATORIO") : cstring("FICHERO")
	if imgui.BeginCombo("Modo de creacion de la escena", _scene_preview, NO_COMBO) {
		if imgui.Selectable(cstring("ALEATORIO"), mode==0,{},{0,0}) {cfg.system_creation_mode=.RANDOM}
		if mode==0 {imgui.SetItemDefaultFocus()}
		if imgui.Selectable(cstring("FICHERO"), mode==1,{},{0,0}) {cfg.system_creation_mode=.FILE}
		if mode==1 {imgui.SetItemDefaultFocus()}
		imgui.EndCombo()
	}

	if cfg.system_creation_mode == .FILE {
		buf: [100]u8; fn := cfg.filename; n := len(fn); if n>99{n=99}
		intrinsics.mem_copy(&buf[0], raw_data(fn), n); buf[n]=0
		imgui.InputText("Fichero JSON", cstring(&buf[0]), 100, NO_FLAGS)
	}
	if cfg.system_creation_mode == .RANDOM {
		v: c.int = c.int(cfg.num_objects); imgui.InputInt("Numero de objetos", &v)
		cfg.num_objects = int(v)
	}

	col := i32(cfg.collision_algorithm)
	_col_preview := col==0 ? cstring("BRUTE FORCE") : cstring("OCTREE")
	if imgui.BeginCombo("Algoritmo de deteccion de colision", _col_preview, NO_COMBO) {
		if imgui.Selectable(cstring("BRUTE FORCE"), col==0,{},{0,0}) {cfg.collision_algorithm=.BRUTE_FORCE}
		if col==0 {imgui.SetItemDefaultFocus()}
		if imgui.Selectable(cstring("OCTREE"), col==1,{},{0,0}) {cfg.collision_algorithm=.OCTREE}
		if col==1 {imgui.SetItemDefaultFocus()}
		imgui.EndCombo()
	}

	sol := i32(cfg.solver_algorithm)
	_sol_preview := sol==0 ? cstring("BRUTE FORCE") : cstring("OCTREE")
	if imgui.BeginCombo("Algoritmo de resolucion", _sol_preview, NO_COMBO) {
		if imgui.Selectable(cstring("BRUTE FORCE"), sol==0,{},{0,0}) {cfg.solver_algorithm=.BRUTE_FORCE}
		if sol==0 {imgui.SetItemDefaultFocus()}
		if imgui.Selectable(cstring("OCTREE"), sol==1,{},{0,0}) {cfg.solver_algorithm=.OCTREE}
		if sol==1 {imgui.SetItemDefaultFocus()}
		imgui.EndCombo()
	}

	if imgui.Button("Guardar") {state_machine_change(sm, .SAVE)}
	imgui.End()
}
@(private) _config_change :: proc(sm: ^StateMachine, s: ^State, action: Action) {if action == .SAVE {state_destroy(s); s^=_new_main_menu()}}

@(private) _debug_frame :: proc(sm: ^StateMachine) {
	imgui.Begin("Debug", nil, NO_DECOR)
	imgui.SetWindowPos({0,0}, imgui.Cond.Always)
	imgui.Text("Frametime: %.2f ms", sm.frame_time^)
	imgui.Text("Ticktime: %.2f µs", sm.tick_time^)
	imgui.End()
}
@(private) _debug_change :: proc(sm: ^StateMachine, s: ^State, action: Action) {}

@(private) _object_selected_frame :: proc(sm: ^StateMachine, o: ^ObjectSelected) {
	if o.old_id != o.object_id && o.object_id < i32(len(sm.objects)) && o.object_id >= 0 {
		if o.old_id>=0 && o.old_id<i32(len(sm.objects)) {sm.objects[o.old_id].selected=false}
		sm.objects[o.object_id].selected=true; o.old_id=o.object_id
	}
	imgui.Begin("ItemSelected", nil, NO_DECOR)
	vp := imgui.GetMainViewport().Size; ws := imgui.GetWindowSize()
	if ws.x<100{ws.x=400}; if ws.y<100{ws.y=200}
	imgui.SetWindowPos({vp.x-ws.x,0}, imgui.Cond.Always)

	id: c.int = c.int(o.object_id); imgui.InputInt("Id", &id)
	o.object_id = i32(id)

	if o.object_id >= 0 && o.object_id < i32(len(sm.objects)) {
		obj := &sm.objects[o.object_id]
		pos_km := [3]f32{obj.position.x*0.001, obj.position.y*0.001, obj.position.z*0.001}
		imgui.InputFloat3("posicion", &pos_km)
		obj.position = {pos_km.x*1000, pos_km.y*1000, pos_km.z*1000}
		imgui.InputFloat3("velocidad", &obj.velocity)
		acc := obj.acceleration; imgui.InputFloat3("acceleracion", &acc)
		mass_kg: f64 = obj.mass; if imgui.InputDouble("masa", &mass_kg) && mass_kg>0 {obj.mass=mass_kg}
		r_km: f32 = obj.radius*0.001; if imgui.InputFloat("radio", &r_km) {obj.radius=r_km*1000}
	}

	if imgui.Button("finalizar simulacion") {state_machine_change(sm, .EXIT)}
	imgui.End()
}
@(private) _object_selected_change :: proc(sm: ^StateMachine, s: ^State, action: Action) {if action==.EXIT {sm.sim_end(sm); state_destroy(s); s^=_new_main_menu()}}
