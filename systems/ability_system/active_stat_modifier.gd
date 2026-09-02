class_name ActiveStatModifier
extends RefCounted
## One modifier's per-REGISTRATION record — the modifier data
## (StatModifierBehavior, a shared/reusable Resource) plus where THIS
## application of it came from. Source can't live on the
## StatModifierBehavior itself: that resource is the same shared object
## across every unit currently affected by a given status (weakened.tres
## is one .tres, loaded once), so a source string written onto it would
## work today by coincidence — every applier of Weakened wants
## source="Weakened" anyway — but breaks the moment two different
## sources ever register the identical shared modifier object. Same
## "shared definition vs. per-application instance" split ActiveStatus
## already draws for StatusEffect itself.

var modifier: StatModifierBehavior
var source: String


func _init(p_modifier: StatModifierBehavior, p_source: String) -> void:
	modifier = p_modifier
	source = p_source
