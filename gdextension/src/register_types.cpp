#include "register_types.h"
#include "navigation_grid.h"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

// Registered as an Engine singleton named "NavigationGrid" — every existing
// GDScript call site (unit_movement.gd, movement_indicator.gd,
// combat_manager.gd, ground_click_target.gd, knockback_effect.gd,
// ground_point_targeting.gd, unit.gd) already calls NavigationGrid.foo(...)
// against what used to be a `class_name NavigationGrid extends RefCounted`
// GDScript static-method class. A singleton under the same name is called
// with the exact same syntax from GDScript, so none of those files change —
// only navigation_grid.gd itself is deleted, replaced by this extension.
static NavigationGrid *navigation_grid_singleton = nullptr;

void initialize_navigation_grid_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	ClassDB::register_class<NavigationGrid>();
	navigation_grid_singleton = memnew(NavigationGrid);
	Engine::get_singleton()->register_singleton("NavigationGrid", navigation_grid_singleton);
}

void uninitialize_navigation_grid_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	if (navigation_grid_singleton) {
		Engine::get_singleton()->unregister_singleton("NavigationGrid");
		memdelete(navigation_grid_singleton);
		navigation_grid_singleton = nullptr;
	}
}

extern "C" {
GDExtensionBool GDE_EXPORT navigation_grid_library_init(
		GDExtensionInterfaceGetProcAddress p_get_proc_address,
		GDExtensionClassLibraryPtr p_library,
		GDExtensionInitialization *r_initialization) {
	godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);

	init_obj.register_initializer(initialize_navigation_grid_module);
	init_obj.register_terminator(uninitialize_navigation_grid_module);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);

	return init_obj.init();
}
}
