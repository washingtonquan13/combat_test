extends Control
## Static mockup of the level-up wizard (Kael Varros, Magus 1 -> 2). Every
## page is authored in wizard_mockup.tscn; this script only switches pages
## and fills the class Tree, since TreeItems cannot be saved in a scene.

const STEP_TITLES: Array[String] = ["Class", "What you gain", "Attributes", "Skills", "Summary"]
const HINTS: Array[String] = [
	"Magus 2 chosen",
	"Arcane Guard learned",
	"All 3 attribute points spent",
	"All 2 skill points spent",
	"Nothing left to fix",
]

@onready var _pages: TabContainer = %Pages
@onready var _back: Button = %BackButton
@onready var _next: Button = %NextButton
@onready var _hint: Label = %Hint
@onready var _count: Label = %StepCount
@onready var _class_tree: Tree = %ClassTree

var _steps: Array[Button] = []


func _ready() -> void:
	for child in %Stepper.get_children():
		if child is Button:
			child.pressed.connect(go.bind(_steps.size()))
			_steps.append(child)
	_back.pressed.connect(func() -> void: go(_pages.current_tab - 1))
	_next.pressed.connect(func() -> void: go(_pages.current_tab + 1))
	_fill_class_tree()
	go(_pages.current_tab)


func go(index: int) -> void:
	index = clampi(index, 0, _steps.size() - 1)
	_pages.current_tab = index
	_steps[index].button_pressed = true
	_count.text = "Step %d of %d" % [index + 1, _steps.size()]
	_back.disabled = index == 0
	_hint.text = HINTS[index]
	if index == _steps.size() - 1:
		_next.text = "Level Up"
	else:
		_next.text = "Next: %s  >" % STEP_TITLES[index + 1]


func _fill_class_tree() -> void:
	_class_tree.columns = 2
	_class_tree.set_column_expand(1, false)
	_class_tree.set_column_custom_minimum_width(1, 84)
	_class_tree.select_mode = Tree.SELECT_ROW
	var root := _class_tree.create_item()
	var groups := {
		"Your classes": [["Fighter", "2 / 3", true], ["Magus", "1 > 2", true]],
		"New class": [["Warden", "0 / 3", true]],
		"Specialty": [["Arcane Archer", "Magus 2", false]],
		"Prestige": [["Spellblade", "F3 + M2", false]],
	}
	for group: String in groups:
		var header := _class_tree.create_item(root)
		header.set_text(0, group.to_upper())
		header.set_selectable(0, false)
		header.set_selectable(1, false)
		header.set_custom_color(0, Color("9b968c"))
		for entry: Array in groups[group]:
			var item := _class_tree.create_item(header)
			item.set_text(0, entry[0])
			item.set_text(1, entry[1])
			item.set_text_alignment(1, HORIZONTAL_ALIGNMENT_RIGHT)
			if not entry[2]:
				item.set_custom_color(0, Color("6f6a62"))
				item.set_custom_color(1, Color("6f6a62"))
			if entry[0] == "Magus":
				item.set_custom_color(1, Color("9fd49a"))
				item.select(0)
