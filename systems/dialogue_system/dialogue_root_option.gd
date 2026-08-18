class_name DialogueRootOption
extends Resource
## One candidate entry point into a conversation with an NPC, paired
## with the prerequisite deciding whether it's the right one right now
## — see Unit.dialogue_options and Unit.resolve_dialogue_root(). An NPC
## with multiple relationship phases (first meeting / quest active /
## quest resolved) gets one small, separate DialogueNode tree PER phase
## instead of every phase packed into one tree and gated choice-by-
## choice — the greeting text_block itself can finally vary with state,
## which gating individual choices alone could never do (DialogueNode
## .text_block is one fixed string per node).
##
## Evaluated in array order — first entry whose prerequisite is
## satisfied (or has none at all, prerequisite left null) wins. Author
## the most specific/latest-state options first, the guaranteed
## fallback last.

@export var root: DialogueNode = null
@export var prerequisite: PrerequisiteRule = null
