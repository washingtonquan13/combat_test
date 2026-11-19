class_name CharacterPreset
extends Resource
## Who a Character Creator human is: which base body, which hairstyle, and
## the tints that make one base many people (UnitDefinition.look). The unit
## system owns it (docs/systems/unit.md).
##
## Everything is named by PATH, not by reference, so a definition with a
## preset still loads when the CC files are not there (they are not in git
## yet): make_body() then returns null and the unit wears its model_scene,
## the old body, as before.

## A CharacterModel scene over a CC base with a CCLook node
## (scenes/character_models/cc_male_model.tscn, cc_female_model.tscn).
@export_file("*.tscn") var body_scene: String = ""
## A CC hairstyle's FBX, its JSON beside it under the same name. Empty is
## bald.
@export_file("*.fbx") var hair_scene: String = ""
## Multiplies CC's skin maps.
@export var skin_tint: Color = Color.WHITE
## Multiplies CC's iris.
@export var iris_tint: Color = Color.WHITE
## The hair's colour; alpha 0 keeps the hairstyle's own.
@export var hair_color: Color = Color(0, 0, 0, 0)


## Whether every file this preset needs is in the project.
func is_available() -> bool:
	if body_scene == "" or not ResourceLoader.exists(body_scene):
		return false
	for path in [body_scene, hair_scene]:
		if path == "":
			continue
		if not ResourceLoader.exists(path):
			return false
		for dependency in ResourceLoader.get_dependencies(path):
			# "uid://...::Type::res://path", "res://path::Type" or a path.
			for part in dependency.split("::"):
				if part.begins_with("res://") and not ResourceLoader.exists(part):
					return false
	return hair_scene == "" or FileAccess.file_exists(hair_json())


func hair_json() -> String:
	return hair_scene.get_basename() + ".json"


## The body, dressed by this preset, or null when its files are missing.
func make_body() -> CharacterModel:
	if not is_available():
		push_warning("CharacterPreset '%s': its CC files are missing; wearing the definition's model_scene." % resource_path)
		return null
	var model := (load(body_scene) as PackedScene).instantiate() as CharacterModel
	if model == null:
		return null
	for child in model.get_children():
		if child is CCLook:
			(child as CCLook).preset = self
	return model
