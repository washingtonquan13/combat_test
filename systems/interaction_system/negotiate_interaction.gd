class_name NegotiateInteraction
extends InteractionOption
## Right-click "Negotiate" — the first InteractionOption to check combat
## state directly (neither AttackInteraction nor TalkInteraction do:
## Attack works both in/out of combat by design, Talk's combat-block
## lives in TalkInteraction.start). Negotiation is the opposite of
## Talk's own gating: combat-ONLY, hostile-only, and further gated on
## target.negotiable so it only ever appears on units actually authored
## to be negotiable, not every hostile unit in the game.

## Where negotiation trees live — their own folder and their own id
## namespace, never mixed into the dialogue trees.
const CONVERSATIONS_DIR: String = "res://data/negotiation/conversations"


## Starts a negotiation: the same Conversation an ordinary talk uses, set
## up the way a negotiation reads. Returns the live conversation, or null
## when it was refused.
##
## Refused unless the ACTOR is fighting. Asked as "is any combat running,"
## that was the same question while there was one world — and became "a
## demon in no fight at all is negotiable, as long as somebody somewhere
## is fighting." Everything else that could stop it (another conversation,
## an open stash) is Conversations.begin's one question to GameMode.
##
## Nothing here is negotiation LOGIC — mood, price, pardon and the endings
## are the tree's own start effects and outcome effects (see
## NegotiationOpeningEffect). This only picks the presentation (the
## negotiation panel instead of the dialogue band), lints this folder's
## trees strictly the first time one is used (every negotiation must end
## through an outcome), and echoes the transcript to SystemLog.
static func start(actor: Unit, demon: Unit) -> Conversation:
	if not is_instance_valid(actor) or not is_instance_valid(demon):
		return null
	if not actor.in_combat():
		return null
	if not demon.negotiable or not demon.is_alive() or not demon.definition:
		return null
	Conversations.lint(CONVERSATIONS_DIR, true)

	var cast: Dictionary = {"player": actor, "npc": demon}
	var c := Conversation.new(demon.definition.resolve_negotiation_root(Conversation.new(null, cast)), cast)
	c.presentation = &"negotiation"
	c.node_dir = CONVERSATIONS_DIR
	_echo_to_log(c)
	return c if Conversations.begin(c) else null


## The negotiation panel has no scrollback, and SystemLog's own panel is
## hidden while it is open, so the combat log is where a negotiation's
## asides and the player's answers are kept, as they always were. Done
## here, by the starter that knows this is a negotiation, as an observer of
## the transcript rather than a switch in the engine. The demon's own
## lines (narration) stay out: the panel is already showing them, and the
## log never carried them.
##
## The conversation is held weakly: this callable lives in the
## conversation's own signal, so a strong reference would keep it alive
## forever.
static func _echo_to_log(c: Conversation) -> void:
	var conversation: WeakRef = weakref(c)
	var seen: Array[int] = [0]
	c.changed.connect(func() -> void:
		var live: Conversation = conversation.get_ref()
		if live == null:
			return
		while seen[0] < live.transcript.size():
			var entry: Dictionary = live.transcript[seen[0]]
			seen[0] += 1
			if not entry.get("narration", false):
				SystemLog.print(DialogueFormat.entry_bbcode(entry)))


func is_available(actor: Unit, target) -> bool:
	if not target is Unit:
		return false
	var unit_target: Unit = target
	return actor.in_combat() and actor.is_hostile_to(unit_target) and unit_target.negotiable


func execute(actor: Unit, target) -> void:
	start(actor, target)
