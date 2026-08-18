class_name AlignmentPrerequisite
extends PrerequisiteRule
## Requires a unit's alignment or tendency axis to currently sit in a
## specific category — Chaos/Neutral/Law, or Dark/Neutral/Light. Sibling
## to flag_prerequisite.gd, same folder for the same reason (see that
## file's header): PrerequisiteRule's composition is general enough to
## reuse rather than inventing a second condition system.
##
## Reads the SAME category logic UnitAlignment already exposes
## (alignment_category()/tendency_category(), also used by
## party_overview.gd's alignment grid) — this never re-derives the
## Law/Chaos or Light/Dark threshold math itself, so a dialogue gate can
## never disagree with what the character sheet is showing the player.
##
## Closes the gap named in dialogue_system_bg3_gap_analysis.md: alignment
## was write-only (DialogueChoice.alignment_name shifts it, nothing read
## it back). Unlike FlagPrerequisite, this DOES care which unit is
## asking — is_satisfied(unit) checks unit's own running totals, not
## global state.

enum Axis { ALIGNMENT, TENDENCY }

@export var axis: Axis = Axis.ALIGNMENT
## -1/0/1, matching UnitAlignment's own category scale (Chaos/Neutral/Law
## on the ALIGNMENT axis, Dark/Neutral/Light on TENDENCY).
@export_range(-1, 1, 1) var required_category: int = 0


func is_satisfied(unit: Unit) -> bool:
	var category: int = unit.alignment_category() if axis == Axis.ALIGNMENT else unit.tendency_category()
	return category == required_category
