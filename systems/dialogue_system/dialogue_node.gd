class_name DialogueNode
extends Resource
## One line (or beat) of a conversation. speaker is a participant TOKEN
## ("player", "npc", ...), not a direct Unit reference — this Resource is
## static, authored data; the actual Unit it refers to only exists once
## a specific conversation is live (see DialogueManager.start_dialogue's
## participants dictionary), so a hard node reference here couldn't mean
## anything. DialogueCameraRig resolves speaker -> Unit through that same
## dictionary to know who to frame.
##
## No separate "exit node" type (the old GURPS-project had one,
## DialogueExitNode) — its only two fields beyond text (exit_comment,
## on_exit_action) were both dead, never read anywhere in that project's
## DialogueManager. A node with empty choices AND no next_node_id already
## IS the end of the conversation; DialogueManager shows an
## "End Conversation" affordance instead of response buttons rather than
## dispatching on a second type.

@export var id: String = ""
@export var speaker: String = ""
@export_multiline var text_block: String = ""
@export var choices: Array[DialogueChoice] = []
## Only consulted when choices is empty — a linear narration beat that
## advances on a manual "Continue" click with no real branch to offer.
## Empty choices AND an empty next_node_id together mean this node ends
## the conversation.
@export var next_node_id: String = ""
## Candidate reactions checked whenever something is about to navigate
## TO this node — see DialogueManager._resolve_interjection(). First
## entry whose prerequisite is satisfied (e.g. a
## ParticipantPresentPrerequisite gating on a specific companion) is
## shown INSTEAD of this node, as its own full beat — real BG3-style
## companion banter: "before the player hears this, so-and-so reacts to
## it." Reuses DialogueRootOption exactly as-is (a candidate node +
## prerequisite is the same shape whether it's a phase of an NPC's
## whole conversation or one reaction to one beat) — author the
## interjection's own next_node_id as THIS node's id, so the
## conversation lands here normally right after.
@export var interjection_options: Array[DialogueRootOption] = []
