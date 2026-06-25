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
	simulation_init: proc(state_machine: ^StateMachine), simulation_end: proc(state_machine: ^StateMachine),
}

State :: union {MainMenu, Config, Debug, ObjectSelected}
MainMenu :: struct {}
Config :: struct {}
Debug :: struct {inner: ^State}
ObjectSelected :: struct {inner: ^State, object_id: i32, old_id: i32}

@(private) _new_main_menu :: proc() -> State {return MainMenu{}}
@(private) _new_config :: proc() -> State {return Config{}}
@(private) _new_debug :: proc(inner: ^State) -> State {return Debug{inner = inner}}
@(private) _new_object_selected :: proc(state_machine: ^StateMachine, inner: ^State) -> State {
	o := ObjectSelected{inner = inner, object_id = 0, old_id = -1}
	if state_machine.objects != nil && len(state_machine.objects) > 0 {state_machine.objects[0].selected = true}
	return o
}

state_machine_create :: proc(renderer: ^graphic.Renderer, objects: ^[dynamic]phys.PhysicObject, config: ^found.Config, frame_time, tick_time: ^f32, simulation_init, simulation_end: proc(state_machine: ^StateMachine)) -> StateMachine {
	state_machine := StateMachine{objects = objects, renderer = renderer, frame_time = frame_time, tick_time = tick_time, config = config, simulation_init = simulation_init, simulation_end = simulation_end}
	state_machine.state = _new_main_menu()
	return state_machine
}

state_machine_destroy :: proc(state_machine: ^StateMachine) {state_destroy(&state_machine.state)}
state_machine_frame :: proc(state_machine: ^StateMachine) {state_frame(state_machine, &state_machine.state)}
state_machine_change :: proc(state_machine: ^StateMachine, action: Action) {state_change(state_machine, &state_machine.state, action)}

state_destroy :: proc(state: ^State) {
	#partial switch _ in state {
	case Debug: debug := &state.(Debug); if debug.inner != nil {state_destroy(debug.inner); free(debug.inner)}
	case ObjectSelected: object_selected := &state.(ObjectSelected); if object_selected.inner != nil {state_destroy(object_selected.inner); free(object_selected.inner)}
	}
}

state_frame :: proc(state_machine: ^StateMachine, state: ^State) {
	switch _ in state {
	case MainMenu: _main_menu_frame(state_machine)
	case Config: _config_frame(state_machine)
	case Debug: d := &state.(Debug); if d.inner != nil {state_frame(state_machine, d.inner)}; _debug_frame(state_machine)
	case ObjectSelected: o := &state.(ObjectSelected); if o.inner != nil {state_frame(state_machine, o.inner)}; _object_selected_frame(state_machine, o)
	}
}

state_change :: proc(state_machine: ^StateMachine, state: ^State, action: Action) {
	switch _ in state {
	case MainMenu: _main_menu_change(state_machine, state, action)
	case Config: _config_change(state_machine, state, action)
	case Debug: _debug_change(state_machine, state, action)
	case ObjectSelected: _object_selected_change(state_machine, state, action)
	}
}

@(private) NO_DECOR := imgui.WindowFlags{.NoTitleBar,.NoResize,.NoMove}
@(private) NO_FLAGS :: imgui.InputTextFlags{}
@(private) NO_COMBO :: imgui.ComboFlags{}

@(private) _center_window :: proc() {
	viewport := imgui.GetMainViewport().Size; window_size := imgui.GetWindowSize()
	imgui.SetWindowPos({(viewport.x-window_size.x)*0.5,(viewport.y-window_size.y)*0.5}, imgui.Cond.Always)
}

@(private) _main_menu_frame :: proc(state_machine: ^StateMachine) {
	imgui.Begin("MainMenu", nil, NO_DECOR)
	imgui.SetWindowSize({300,100}, imgui.Cond.Always); _center_window()
	imgui.Text("SIMULADOR DE FUERZA GRAVITATORIA")
	if imgui.Button("Iniciar Simulacion") {state_machine_change(state_machine, .BEGIN_SIMULATION)}
	if imgui.Button("Configuracion") {state_machine_change(state_machine, .CONFIGURATION)}
	imgui.End()
}

@(private) _main_menu_change :: proc(state_machine: ^StateMachine, state: ^State, action: Action) {
	#partial switch action {
	case .BEGIN_SIMULATION: state_machine.simulation_init(state_machine); empty: State; inner := new_clone(empty); state_destroy(state); debug_state := _new_debug(inner); state^ = _new_object_selected(state_machine, new_clone(debug_state))
	case .CONFIGURATION: state_destroy(state); state^ = _new_config()
	}
}

@(private) _config_frame :: proc(state_machine: ^StateMachine) {
	config := state_machine.config
	imgui.Begin("Config", nil, NO_DECOR)
	imgui.SetWindowSize({750,200}, imgui.Cond.Always); _center_window()

	imgui.InputFloat("Multiplicador paso del tiempo", &config.time)

	mode := i32(config.system_creation_mode)
	_scene_preview := mode == 0 ? cstring("ALEATORIO") : cstring("FICHERO")
	if imgui.BeginCombo("Modo de creacion de la escena", _scene_preview, NO_COMBO) {
		if imgui.Selectable(cstring("ALEATORIO"), mode==0,{},{0,0}) {config.system_creation_mode=.RANDOM}
		if mode==0 {imgui.SetItemDefaultFocus()}
		if imgui.Selectable(cstring("FICHERO"), mode==1,{},{0,0}) {config.system_creation_mode=.FILE}
		if mode==1 {imgui.SetItemDefaultFocus()}
		imgui.EndCombo()
	}

	if config.system_creation_mode == .FILE {
		buffer: [100]u8; filename := config.filename; filename_len := len(filename); if filename_len>99{filename_len=99}
		intrinsics.mem_copy(&buffer[0], raw_data(filename), filename_len); buffer[filename_len]=0
		imgui.InputText("Fichero JSON", cstring(&buffer[0]), 100, NO_FLAGS)
	}
	if config.system_creation_mode == .RANDOM {
		v: c.int = c.int(config.num_objects); imgui.InputInt("Numero de objetos", &v)
		config.num_objects = int(v)
	}

	collision_choice := i32(config.collision_algorithm)
	_col_preview := collision_choice==0 ? cstring("BRUTE FORCE") : cstring("OCTREE")
	if imgui.BeginCombo("Algoritmo de deteccion de colision", _col_preview, NO_COMBO) {
		if imgui.Selectable(cstring("BRUTE FORCE"), collision_choice==0,{},{0,0}) {config.collision_algorithm=.BRUTE_FORCE}
		if collision_choice==0 {imgui.SetItemDefaultFocus()}
		if imgui.Selectable(cstring("OCTREE"), collision_choice==1,{},{0,0}) {config.collision_algorithm=.OCTREE}
		if collision_choice==1 {imgui.SetItemDefaultFocus()}
		imgui.EndCombo()
	}

	solver_choice := i32(config.solver_algorithm)
	_sol_preview := solver_choice==0 ? cstring("BRUTE FORCE") : cstring("OCTREE")
	if imgui.BeginCombo("Algoritmo de resolucion", _sol_preview, NO_COMBO) {
		if imgui.Selectable(cstring("BRUTE FORCE"), solver_choice==0,{},{0,0}) {config.solver_algorithm=.BRUTE_FORCE}
		if solver_choice==0 {imgui.SetItemDefaultFocus()}
		if imgui.Selectable(cstring("OCTREE"), solver_choice==1,{},{0,0}) {config.solver_algorithm=.OCTREE}
		if solver_choice==1 {imgui.SetItemDefaultFocus()}
		imgui.EndCombo()
	}

	if imgui.Button("Guardar") {state_machine_change(state_machine, .SAVE)}
	imgui.End()
}
@(private) _config_change :: proc(state_machine: ^StateMachine, state: ^State, action: Action) {if action == .SAVE {state_destroy(state); state^=_new_main_menu()}}

@(private) _debug_frame :: proc(state_machine: ^StateMachine) {
	imgui.Begin("Debug", nil, NO_DECOR)
	imgui.SetWindowPos({0,0}, imgui.Cond.Always)
	imgui.Text("Frametime: %.2f ms", state_machine.frame_time^)
	imgui.Text("Ticktime: %.2f µs", state_machine.tick_time^)
	imgui.End()
}
@(private) _debug_change :: proc(state_machine: ^StateMachine, state: ^State, action: Action) {}

@(private) _object_selected_frame :: proc(state_machine: ^StateMachine, o: ^ObjectSelected) {
	if o.old_id != o.object_id && o.object_id < i32(len(state_machine.objects)) && o.object_id >= 0 {
		if o.old_id>=0 && o.old_id<i32(len(state_machine.objects)) {state_machine.objects[o.old_id].selected=false}
		state_machine.objects[o.object_id].selected=true; o.old_id=o.object_id
	}
	imgui.Begin("ItemSelected", nil, NO_DECOR)
	viewport := imgui.GetMainViewport().Size; window_size := imgui.GetWindowSize()
	if window_size.x<100{window_size.x=400}; if window_size.y<100{window_size.y=200}
	imgui.SetWindowPos({viewport.x-window_size.x,0}, imgui.Cond.Always)

	object_id: c.int = c.int(o.object_id); imgui.InputInt("Id", &object_id)
	o.object_id = i32(object_id)

	if o.object_id >= 0 && o.object_id < i32(len(state_machine.objects)) {
		obj := &state_machine.objects[o.object_id]
		pos_km := [3]f32{obj.position.x*0.001, obj.position.y*0.001, obj.position.z*0.001}
		imgui.InputFloat3("posicion", &pos_km)
		obj.position = {pos_km.x*1000, pos_km.y*1000, pos_km.z*1000}
		imgui.InputFloat3("velocidad", &obj.velocity)
		acc := obj.acceleration; imgui.InputFloat3("acceleracion", &acc)
		mass_kg: f64 = obj.mass; if imgui.InputDouble("masa", &mass_kg) && mass_kg>0 {obj.mass=mass_kg}
		r_km: f32 = obj.radius*0.001; if imgui.InputFloat("radio", &r_km) {obj.radius=r_km*1000}
	}

	if imgui.Button("finalizar simulacion") {state_machine_change(state_machine, .EXIT)}
	imgui.End()
}
@(private) _object_selected_change :: proc(state_machine: ^StateMachine, state: ^State, action: Action) {if action==.EXIT {state_machine.simulation_end(state_machine); state_destroy(state); state^=_new_main_menu()}}
