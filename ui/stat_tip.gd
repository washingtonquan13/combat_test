class_name StatTip
extends Control
## A hover target on the character sheet whose tooltip is a breakdown —
## how the number is reached, part by part, the way Owlcat's sheets do it.
## Attach to any Control (a Label, a defense tile); StatsColumn writes
## tooltip_text with tip_text() and Godot's own tooltip timer shows it.
##
## tooltip_text is lines: the first is the title, a line with a tab is a
## "part<TAB>amount" row, any other line is wrapped description.

const DIM := Color(0.553, 0.541, 0.502, 1)


## title, description, then one row per part: an {amount} as a signed
## term after the first, a {multiplier} as "×½". A zero amount (DR's
## base under its armour) is left out unless it is all there is.
static func tip_text(title: String, description: String, parts: Array[Dictionary]) -> String:
	var lines: PackedStringArray = [title]
	if description != "":
		lines.append(description)
	var shown: int = 0
	for part in parts:
		var amount: String
		if part.has("multiplier"):
			amount = "×%s" % ("½" if is_equal_approx(part.multiplier, 0.5) else String.num(part.multiplier))
		else:
			if part.amount == 0 and parts.size() > 1:
				continue
			amount = StatDefinition.format(part.amount)
			if shown > 0 and part.amount >= 0:
				amount = "+" + amount
		shown += 1
		lines.append("%s\t%s" % [part.label, amount])
	return "\n".join(lines)


func _make_custom_tooltip(for_text: String) -> Object:
	var box := VBoxContainer.new()
	var grid: GridContainer = null
	var lines := for_text.split("\n")
	for i in lines.size():
		var line: String = lines[i]
		if "\t" in line:
			if grid == null:
				grid = GridContainer.new()
				grid.columns = 2
				grid.add_theme_constant_override("h_separation", 24)
				box.add_child(grid)
			var cells := line.split("\t")
			var part := Label.new()
			part.text = cells[0]
			part.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			grid.add_child(part)
			var amount := Label.new()
			amount.text = cells[1]
			amount.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			grid.add_child(amount)
		else:
			grid = null
			var label := Label.new()
			label.text = line
			if i == 0:
				label.add_theme_font_size_override("font_size", 18)
			else:
				label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
				label.custom_minimum_size.x = 300
				label.add_theme_color_override("font_color", DIM)
			box.add_child(label)
	return box
