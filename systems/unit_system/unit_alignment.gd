class_name UnitAlignment
extends RefCounted
## Categorizes and applies shifts to this unit's alignment/tendency axes
## — see Unit.alignment/Unit.tendency for the two raw running totals,
## which stay on Unit itself (@export, authored/inspected per-unit).
## Pure logic over those owner-held fields, same shape as UnitFacing —
## owns no state of its own.

var _owner: Unit

## How far from 0 counts as "still neutral" on EITHER axis — kept wide
## relative to a single shift (see ALIGNMENT_SHIFT_AMOUNT) so leaving
## neutral takes a real pattern of consistent choices, not one line of
## dialogue. Tune freely; nothing else depends on the exact number.
const ALIGNMENT_NEUTRAL_THRESHOLD: int = 25
## Per-choice nudge applied by apply_alignment_tag — see DialogueChoice
## .resolve(), the only current caller.
const ALIGNMENT_SHIFT_AMOUNT: int = 10


func _init(owner: Unit) -> void:
	_owner = owner


## -1/0/1 for Chaos/Neutral/Law — the only thing anything outside Unit
## should ever need to know to categorize the raw alignment int (see
## ALIGNMENT_NEUTRAL_THRESHOLD). party_overview.gd's 9-cell grid is the
## first caller; nothing about the category logic is UI-specific, so it
## lives here rather than being re-derived in the UI layer.
func alignment_category() -> int:
	return category_for(_owner.alignment)


## Static counterpart to alignment_category() for a caller that only has
## the raw int, not a live Unit to build an instance around — the
## overworld avatar's alignment-driven spin (PartyManager.leader_alignment()
## has no Unit at all in the overworld) is the first such caller.
static func category_for(alignment: int) -> int:
	if alignment < -ALIGNMENT_NEUTRAL_THRESHOLD:
		return -1
	if alignment > ALIGNMENT_NEUTRAL_THRESHOLD:
		return 1
	return 0


## -1/0/1 for Dark/Neutral/Light — same reasoning as alignment_category.
func tendency_category() -> int:
	if _owner.tendency < -ALIGNMENT_NEUTRAL_THRESHOLD:
		return -1
	if _owner.tendency > ALIGNMENT_NEUTRAL_THRESHOLD:
		return 1
	return 0


## Applies one authored DialogueChoice.alignment_name tag to this unit's
## running totals — the ONLY place that knows "Chaotic" means alignment
## goes down rather than up, so a dialogue choice never needs to touch
## these fields directly. Unrecognized tags (including "", and the old
## Good/Evil vocabulary this project no longer uses) are silently
## no-ops rather than errors — an author leaving alignment_name blank on
## a choice is the normal, common case, not a mistake.
func apply_alignment_tag(tag: String) -> void:
	match tag:
		"Lawful": _owner.alignment += ALIGNMENT_SHIFT_AMOUNT
		"Chaotic": _owner.alignment -= ALIGNMENT_SHIFT_AMOUNT
		"Light": _owner.tendency += ALIGNMENT_SHIFT_AMOUNT
		"Dark": _owner.tendency -= ALIGNMENT_SHIFT_AMOUNT
