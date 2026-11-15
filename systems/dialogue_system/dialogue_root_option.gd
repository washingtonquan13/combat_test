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
## The same node by id, for one written in a dialogue file (see
## DialogueScript), which has no resource of its own to point at.
@export var root_id: String = ""
@export var prerequisite: PrerequisiteRule = null


## The node this option opens on, looked up in `dir` when it is named by id.
func node_in(dir: String) -> DialogueNode:
	if root or root_id == "":
		return root
	return Conversation.index_for(dir).find_node(root_id)
