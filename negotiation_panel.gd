extends Control
## Thin, reactive negotiation UI — purely a listener over
## NegotiationManager's signals, never touches its state directly, same
## "the manager owns state, this just renders" split as
## dialogue_overlay.gd. Deliberately similar subtitle-style layout for
## visual consistency, but NOT built on dialogue_overlay.gd or its scene
## — this is the "different, lighter flow" negotiation was explicitly
## scoped to be, not a reskin of the full conversation system.

@export var tactical_ui: Control

@onready var _demon_label: RichTextLabel = $VBoxContainer/PanelContainer/MarginContainer/BodyVBox/DemonLabel
@onready var _responses_text: RichTextLabel = $VBoxContainer/PanelContainer/MarginContainer/BodyVBox/ResponsesText
@onready var _offer_bar: HBoxContainer = $VBoxContainer/PanelContainer/MarginContainer/BodyVBox/OfferBar
@onready var _offer_hp_button: Button = $VBoxContainer/PanelContainer/MarginContainer/BodyVBox/OfferBar/OfferHpButton
@onready var _offer_fp_button: Button = $VBoxContainer/PanelContainer/MarginContainer/BodyVBox/OfferBar/OfferFpButton
@onready var _decline_offer_button: Button = $VBoxContainer/PanelContainer/MarginContainer/BodyVBox/OfferBar/DeclineOfferButton

## Fixed sacrifice amounts for these simple HP/FP offer buttons — real
## content/balance tuning, not architecture; a future pass could vary
## this per negotiation or let the player choose an amount instead of
## one flat constant each.
const HP_OFFER_AMOUNT: int = 5
const FP_OFFER_AMOUNT: int = 5

var _current_responses: Array[NegotiationResponse] = []


func _ready() -> void:
	visible = false
	_offer_bar.visible = false

	_responses_text.meta_clicked.connect(_on_response_meta_clicked)
	_offer_hp_button.pressed.connect(func(): NegotiationManager.make_offer(NegotiationManager.OfferType.HP, HP_OFFER_AMOUNT))
	_offer_fp_button.pressed.connect(func(): NegotiationManager.make_offer(NegotiationManager.OfferType.FP, FP_OFFER_AMOUNT))
	_decline_offer_button.pressed.connect(NegotiationManager.decline_offer)

	NegotiationManager.negotiation_started.connect(_on_negotiation_started)
	NegotiationManager.responses_shown.connect(_on_responses_shown)
	NegotiationManager.offer_requested.connect(_on_offer_requested)
	NegotiationManager.negotiation_ended.connect(_on_negotiation_ended)


func _on_negotiation_started(demon: Unit) -> void:
	visible = true
	_offer_bar.visible = false
	_demon_label.text = "[b]%s[/b] is willing to talk." % demon.name
	if tactical_ui:
		tactical_ui.visible = false


func _on_responses_shown(responses: Array[NegotiationResponse]) -> void:
	_current_responses = responses
	_offer_bar.visible = false
	var lines: Array[String] = []
	for i in responses.size():
		lines.append("[url=%d]%d. %s[/url]" % [i, i + 1, responses[i].text])
	_responses_text.text = "\n".join(lines)


func _on_offer_requested() -> void:
	_responses_text.text = "The demon doesn't seem convinced..."
	_offer_bar.visible = true


func _on_negotiation_ended(_outcome: int) -> void:
	visible = false
	_offer_bar.visible = false
	if tactical_ui:
		tactical_ui.visible = true


func _on_response_meta_clicked(meta) -> void:
	NegotiationManager.choose_response(_current_responses[int(meta)])
