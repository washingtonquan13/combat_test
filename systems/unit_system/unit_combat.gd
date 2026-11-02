class_name UnitCombat
extends RefCounted
## Owns ability resolution and damage-taking logic for ONE unit. Owned
## by that Unit (see Unit._combat), same pattern as StatusManager/
## UnitActionState/UnitFacing/UnitSelection/UnitMovement.
##
## Owns NO data fields at all — every stat this touches (read through
## Unit.get_stat()/get_pool(), abilities, ...) stays on Unit, same editor-safety reasoning as every
## previous component's exports. This is purely the LOGIC that resolves
## against those fields through the owner reference — same shape as
## UnitFacing, which also owns nothing of its own.
##
## use_ability()/take_damage() reach back into Unit for cross-cutting
## coordination rather than touching other components directly —
## _owner.snap_face_point() (facing), _owner.notify_status_of_damage()
## (status), _owner.handle_death() (death cleanup, owned by UnitDeath) —
## components talk to their owner, never to each other, same rule
## UnitMovement's notify_movement_idle_check() established.

var _owner: Unit

## Applied to the attacker on a critical-failure to-hit roll — see
## roll_vs()'s critical_failure detection and use_ability()'s miss
## branch below. default_duration=2, not 1: StatusManager.
## tick_turn_start() fires (and decrements) at the START of the owning
## unit's own turn, before that turn's actions are available, so a
## duration-1 status applied mid-turn would already be ticked to 0 and
## removed before the attacker could ever act under it. 2 survives the
## attacker's own next turn (ticks 2->1, stays active) and expires at
## the start of the turn after that (ticks 1->0).
const CRIT_FAIL_PENALTY: StatusEffect = preload("res://data/statuses/crit_fail_penalty.tres")

## General ranged high-ground rule — a live position comparison for
## THIS attack, not a persistent condition on either unit, so it's
## applied directly here rather than through StatusManager's per-status
## aggregation the way Prone/Bless/etc. are. See AltitudeAdvantageBehavior's
## own header for why it used to be Flying-status-only and no longer is.
const PICK_UP: Ability = preload("res://data/abilities/pick_up.tres")

## Multiples of HP below zero at which a unit on the downed rule is dead
## outright, no roll — GURPS's -5x HP.
const DEATH_DEPTH: int = 5

const ALTITUDE_ADVANTAGE: AltitudeAdvantageBehavior = preload("res://data/altitude_advantage.tres")

## Toggles every unit has, whatever its own abilities list: where to aim
## (hit_location_for). The hotbar shows them beside Common's abilities,
## and the AI picks among them per attack (AiScorer._score_plan).
const AIM_TOGGLES: Array[Ability] = [
	preload("res://data/abilities/target_vitals.tres"),
	preload("res://data/abilities/target_head.tres"),
]

## Deceptive Attack (B369): at level N, -2N to the attacker's skill
## and -N to the defender's Dodge, Parry or Block. Every unit has it,
## like the aim toggles, and it goes with any of them.
const DECEPTIVE_ATTACK: Ability = preload("res://data/abilities/deceptive_attack.tres")

## Toggle abilities switched on (Ability.is_toggle), at most one per
## toggle_group. Not saved: a loaded game starts aiming at the torso.
var _toggles: Array[Ability] = []
## Level per leveled toggle (Ability.max_level), kept while it is off.
## Not saved either.
var _toggle_levels: Dictionary = {}
## GURPS off-hand attack penalty (B417). No Ambidexterity here.
const OFF_HAND_PENALTY: int = -4
## See attack_hits().
var _hits: int = 1

## Template Ability -> {[AttackRow, off_hand] -> its bound copy}. See
## _bound_to.
var _bound: Dictionary = {}


## GURPS ST-based swing/thrust damage: the Basic Set damage table (B16)
## as a formula, for any ST. Ported from GCS's BasicSet progression
## (github.com/richardwilkes/gcs, model/gurps/enums/progression), which
## matches the table through ST 100 and the book's +1d per 10 ST past it.
##
## Damage climbs a ladder of quarter-dice — 1d-1, 1d, 1d+1, 1d+2, 2d-1 —
## and ST climbs it more slowly the higher it goes: swing a step per ST
## to 27, then roughly a step per 2 ST; thrust a step per 2 ST to 50;
## both slower again past that. The odd constants in _damage_dice are
## those breakpoints. Below 1 die the table never drops to 0d: it keeps
## stacking a penalty on a single d6 (thrust 1d-6 at ST 1).
##
## Lives on the unit, not on StDamageEffect or GearDamageEffect: it is
## this unit's own ST-derived capability, and the character sheet reads
## it too.
enum DamageType { SWING, THRUST }


func _init(owner: Unit) -> void:
	_owner = owner


## Rolls this unit's ST-derived swing/thrust damage plus bonus (an
## ability's own flat bonus, or an equipped weapon's damage_bonus — see
## StDamageEffect/GearDamageEffect, the two current callers).
func roll_damage(damage_type: DamageType, bonus: int, st: int = 0) -> int:
	var dice: Dictionary = _damage_dice(damage_type, st)
	var total: int = 0
	for _i in int(dice.count):
		total += randi_range(1, 6)  # GURPS damage dice are always d6
	return total + int(dice.flat_bonus) + bonus


## Maximum possible swing/thrust damage plus bonus — every die at its
## highest face — for critical hits (GearDamageEffect/StDamageEffect),
## which deal guaranteed max damage instead of rolling.
func max_damage(damage_type: DamageType, bonus: int, st: int = 0) -> int:
	var dice: Dictionary = _damage_dice(damage_type, st)
	return int(dice.count) * 6 + int(dice.flat_bonus) + bonus


## Expected injury of roll_damage() against target without actually
## rolling (DamageResolver.expected_injury; no target is the raw roll) —
## used by AiScorer to rank candidate actions by expected damage rather
## than sampling a live roll (which would make the AI's own decision
## non-deterministic and untestable independent of RNG).
func expected_damage(damage_type: DamageType, bonus: int, target: Unit = null, wound_type: DamageResolver.WoundType = DamageResolver.WoundType.CRUSHING, armor_divisor: float = 1.0, location: HitLocation = null, st: int = 0) -> float:
	var dice: Dictionary = _damage_dice(damage_type, st)
	return DamageResolver.expected_injury(int(dice.count), 6, int(dice.flat_bonus) + bonus, target, wound_type, armor_divisor, false, location)


## Same formula as roll_damage(), without rolling — e.g. "1d+2" — for
## display (see stats_column.gd's Thrust/Swing rows, shown with bonus 0
## for the character's own base capability).
func describe_damage(damage_type: DamageType, bonus: int, st: int = 0) -> String:
	var dice: Dictionary = _damage_dice(damage_type, st)
	var flat: int = int(dice.flat_bonus) + bonus
	var text: String = "%dd" % int(dice.count)
	if flat > 0:
		text += "+%d" % flat
	elif flat < 0:
		text += str(flat)
	return text


## Whole ST: Exhausted halves ST, but not the damage it deals (B426).
## st > 0 is a bow's own ST instead (AttackRow.weapon_st).
func _damage_dice(damage_type: DamageType, st: int = 0) -> Dictionary:
	if st <= 0:
		st = floori(_owner.get_stat_unhalved(StatIds.ST))
	return _swing_dice(st) if damage_type == DamageType.SWING else _thrust_dice(st)


static func _thrust_dice(st: int) -> Dictionary:
	if st < 19:
		return {"count": 1, "flat_bonus": -(6 - (st - 1) / 2)}
	var steps: int = st - 11
	if st > 50:
		steps -= 1
		if st > 79:
			steps -= 1 + (st - 80) / 5
	return _ladder(steps)


static func _swing_dice(st: int) -> Dictionary:
	if st < 10:
		return {"count": 1, "flat_bonus": -(5 - (st - 1) / 2)}
	if st < 28:
		return {"count": (st - 9) / 4 + 1, "flat_bonus": (st - 9) % 4 - 1}
	var steps: int = st
	if st > 40:
		steps -= (st - 40) / 5
	if st > 59:
		steps += 1
	return _ladder(steps + 9)


## Half-steps to dice: every 8 is a die, the rest walk -1, +0, +1, +2.
static func _ladder(steps: int) -> Dictionary:
	return {"count": steps / 8 + 1, "flat_bonus": steps % 8 / 2 - 1}


## Every attack — melee, ranged, any weapon — resolves against this one
## skill rather than a skill per weapon type, by design (see
## data/skills/basic_attack.tres's own description for the reasoning).
## Explicitly trainable independent of raw DX: SkillCalculator.
## get_skill_level() always keeps the better of a unit's actual trained
## level and Basic Attack's own DX default (modifier 0), so an untrained
## unit gets exactly plain DX — identical to this method's old
## placeholder behavior — and training only ever helps, never hurts,
## relative to that floor.
func attack_skill() -> int:
	return SkillCalculator.get_skill_level(_owner, "Basic Attack").skill_level


## combat_abilities()[0], or null if this unit has none. Used as the
## fallback when nothing's explicitly armed via AbilityManager — see that
## autoload's doc comment.
func default_ability() -> Ability:
	var all: Array[Ability] = combat_abilities()
	return all[0] if not all.is_empty() else null


## Every row this unit can attack with of one kind in its main hand:
## the held weapon's, then its body's natural attacks. A melee unit with
## neither punches. Ranged with neither has none. The off hand's are
## off_hand_rows().
func attack_rows(kind: AttackRow.Kind) -> Array[AttackRow]:
	var rows: Array[AttackRow] = _held_rows(kind, false)
	for row in _owner.natural_attacks:
		if row and row.kind == kind:
			rows.append(row)
	if rows.is_empty() and kind == AttackRow.Kind.MELEE:
		rows.append(GearDamageEffect.PUNCH)
	return rows


## The off-hand weapon's rows of one kind, each its own attack at
## OFF_HAND_PENALTY — except a row marked off_hand_ok (a shield's bash).
func off_hand_rows(kind: AttackRow.Kind) -> Array[AttackRow]:
	return _held_rows(kind, true)


## A melee hand's ranged rows count too: that is a thrown weapon (a
## throwing axe's Throw), fired from the hand that swings it and never
## used up.
func _held_rows(kind: AttackRow.Kind, off_hand: bool) -> Array[AttackRow]:
	var rows: Array[AttackRow] = []
	var slots: Array = [_hand_slot(kind, off_hand)]
	if kind == AttackRow.Kind.RANGED:
		slots.append(_hand_slot(AttackRow.Kind.MELEE, off_hand))
	for slot in slots:
		var item: ItemInstance = _owner.get_equipped_item(slot)
		if item and item.gear_data and item.gear_data.weapon_data:
			rows.append_array(item.gear_data.weapon_data.rows_of(kind))
	return rows


## The held copy whose weapon has row — whose magazine an attack with
## row fires from. Null for a natural attack or a punch.
func item_holding(row: AttackRow) -> ItemInstance:
	for slot in HAND_SLOTS:
		var item: ItemInstance = _owner.get_equipped_item(slot)
		if item and item.gear_data and item.gear_data.weapon_data and item.gear_data.weapon_data.attacks.has(row):
			return item
	return null


## Rounds left for ability's weapon, or -1 when it has no magazine.
func shots_left(ability: Ability) -> int:
	var effect: GearDamageEffect = _gear_effect(ability)
	var item: ItemInstance = item_holding(effect.row_for(_owner)) if effect else null
	return item.shots_left() if item else -1


## Every held weapon with a magazine, filled. Returns how many were.
func reload_all() -> int:
	var reloaded: int = 0
	for slot in HAND_SLOTS:
		var item: ItemInstance = _owner.get_equipped_item(slot)
		if item and item.magazine() > 0 and item.shots_left() < item.magazine():
			item.reload()
			reloaded += 1
	return reloaded


func _holds_magazine_weapon() -> bool:
	for slot in HAND_SLOTS:
		var item: ItemInstance = _owner.get_equipped_item(slot)
		if item and item.magazine() > 0:
			return true
	return false


const HAND_SLOTS: Array[EquipSlot.Slot] = [
	EquipSlot.Slot.MELEE_MAIN_HAND, EquipSlot.Slot.MELEE_OFF_HAND,
	EquipSlot.Slot.RANGED_MAIN_HAND, EquipSlot.Slot.RANGED_OFF_HAND,
]


static func _hand_slot(kind: AttackRow.Kind, off_hand: bool) -> EquipSlot.Slot:
	if kind == AttackRow.Kind.MELEE:
		return EquipSlot.Slot.MELEE_OFF_HAND if off_hand else EquipSlot.Slot.MELEE_MAIN_HAND
	return EquipSlot.Slot.RANGED_OFF_HAND if off_hand else EquipSlot.Slot.RANGED_MAIN_HAND


## unit.abilities with each generic weapon attack (an ability carrying an
## unbound GearDamageEffect — basic_attack_melee/ranged.tres) replaced by
## one attack per row it can use right now: a sword's Swing and Thrust,
## a beast's Claws and Bite. What the hotbar shows and the AI picks
## from. unit.abilities itself, and saves, keep the generic one.
##
## Holding a weapon is enough: a unit with a bow in its ranged hands but
## no ranged template among its abilities (most PCs) still gets the bow's
## attacks, from the shared template of that kind. Both sets are live at
## once, so switching between melee and ranged costs nothing.
func combat_abilities() -> Array[Ability]:
	var result: Array[Ability] = []
	var abilities: Array[Ability] = _owner.abilities.duplicate()
	var kinds_covered := {}
	for ability in abilities:
		var template: GearDamageEffect = _unbound_weapon_effect(ability)
		if template:
			kinds_covered[template.kind()] = true
	for kind in DEFAULT_TEMPLATES:
		if not kinds_covered.has(kind) and not (_held_rows(kind, false) + _held_rows(kind, true)).is_empty():
			abilities.append(load(DEFAULT_TEMPLATES[kind]))
	for ability in abilities:
		var template: GearDamageEffect = _unbound_weapon_effect(ability)
		var rows: Array[AttackRow] = []
		var off_rows: Array[AttackRow] = []
		if template:
			rows = attack_rows(template.kind())
			off_rows = off_hand_rows(template.kind())
		if rows.is_empty() and off_rows.is_empty():
			result.append(ability)
			continue
		for row in rows:
			result.append(_bound_to(ability, row, false))
		for row in off_rows:
			result.append(_bound_to(ability, row, not row.off_hand_ok))
	if _holds_magazine_weapon():
		result.append(load(RELOAD))
	return result


## Offered while a held weapon has a magazine. Loaded lazily like
## DEFAULT_TEMPLATES.
const RELOAD := "res://data/abilities/reload.tres"


## The generic attack a held weapon of each kind falls back to. Loaded
## lazily, not preloaded: those .tres files reach back into this script.
const DEFAULT_TEMPLATES := {
	AttackRow.Kind.MELEE: "res://data/abilities/basic_attack_melee.tres",
	AttackRow.Kind.RANGED: "res://data/abilities/basic_attack_ranged.tres",
}


static func _unbound_weapon_effect(ability: Ability) -> GearDamageEffect:
	if not ability:
		return null
	for effect in ability.effects:
		if effect is GearDamageEffect and effect.row == null:
			return effect
	return null


## The copy of template bound to row in one hand, made once and kept,
## so the same row is the same Ability every time (armed, on the
## hotbar, in a custom slot). A row held in both hands is two attacks.
func _bound_to(template: Ability, row: AttackRow, off_hand: bool) -> Ability:
	var per_row: Dictionary = _bound.get_or_add(template, {})
	var key: Array = [row, off_hand]
	if per_row.has(key):
		return per_row[key]
	var bound: Ability = template.duplicate()
	bound.ability_name = row.label + (" (off hand)" if off_hand else "")
	var effects: Array[AbilityEffect] = []
	for effect in template.effects:
		if effect is GearDamageEffect and effect.row == null:
			var bound_effect := GearDamageEffect.new()
			bound_effect.category = effect.category
			bound_effect.row = row
			bound_effect.off_hand = off_hand
			effects.append(bound_effect)
		else:
			effects.append(effect)
	bound.effects = effects
	if template.targeting is MeleeEnemyTargeting:
		var reach: MeleeEnemyTargeting = template.targeting.duplicate()
		reach.melee_range = row.reach
		bound.targeting = reach
	elif template.targeting is RangedEnemyTargeting and row.max_range > 0.0:
		var span: RangedEnemyTargeting = template.targeting.duplicate()
		span.max_range = row.max_range
		bound.targeting = span
	per_row[key] = bound
	return bound


## Whichever ability would fire if `acting_unit` left-clicks this unit
## right now, or null if the click should fall through to normal
## selection instead — called by ClickRouter.click_unit, through
## Unit.click_ability_for.
## Lives on the CLICKED unit's _combat (answering "if acting_unit clicked
## ME, what fires") rather than the acting unit's, matching the existing
## defender-perspective shape incoming_attack_to_hit_modifier() already
## uses, and avoiding a cross-unit forward acting_unit._combat couldn't
## otherwise reach.
##
## Which clicks count depends on the resolved ability's own targeting: an
## ordinary (non-ally) ability only fires on a HOSTILE click; one with
## AbilityTargeting.requires_ally set (a heal, a buff) only fires on a
## click on the SAME faction instead — see
## AbilityTargeting.requires_ally_target's doc comment for why this is a
## flag there rather than a separate targeting subclass. Resolving the
## ability before checking hostility (rather than after) is what makes
## that possible — the routing decision depends on which ability would
## actually be used, not a fixed rule.
##
## A Downed ally takes priority over all of that: clicking one with
## nothing armed picks it up (PICK_UP).
func resolve_click_ability(acting_unit: Unit) -> Ability:
	if not AbilityManager.armed_ability and _owner.is_downed() 			and acting_unit != _owner and not acting_unit.is_hostile_to(_owner):
		return PICK_UP
	var ability: Ability = AbilityManager.armed_ability if AbilityManager.armed_ability else acting_unit.default_ability()
	if not ability:
		return null
	var wants_ally: bool = ability.targeting and ability.targeting.requires_ally_target()
	if wants_ally:
		return ability if not acting_unit.is_hostile_to(_owner) else null
	# Non-ally abilities (ordinary attacks) are routable at anyone who
	# isn't your own side — a neutral or allied-faction unit is a valid
	# target, not just an already-hostile one. See
	## AttackInteraction.is_available()'s own identical rule (right-click
	## menu) and FactionRelations/_maybe_trigger_combat below (what
	## actually happens the instant the attack lands).
	return ability if not _owner.is_player_controlled() else null


## Resolves using ability against target. Range/LoS rules come from
## ability.targeting; what happens on a hit comes from ability.effects
## (see those classes' doc comments) — this method's job is purely turn
## state (the once-per-turn attack action) and the single to-hit roll
## that gates ALL of an ability's effects together, not per-effect
## resolution. A miss still spends the action if the ability uses one,
## same as before: the attempt itself is what's spent, not the hit.
##
## Rejects outright (busy=true in the result, nothing else evaluated) if
## this unit already has something in flight — movement, or a previous
## ability's async effect (e.g. mid-Jump-animation) still resolving —
## OR if a status effect (Sleep, Stun, ...) prevents it from acting at
## all this turn. Both share the same "busy" result key rather than
## separate flags, since from every existing caller's perspective
## (CombatAI, click routing) they mean the same thing: nothing happened,
## try something else or end the turn.
##
## Returns a result dict for logging/UI:
## { in_range, invalid_target, already_acted, busy, hit, damage, to_hit, effects, ability }
## damage is the SUM of every effect's own "damage" key, for convenience
## — usually zero or one DamageEffect, but this doesn't assume that; see
## effects for the individual per-effect results if more detail is
## needed than the aggregate.
##
## Emits ability_use_started BEFORE to-hit is even rolled — see that
## signal's doc comment on Unit for why: animation/VFX need to react to
## "this is happening" immediately (to start a swing, launch a
## projectile), not wait for the final outcome. If ability.timing is
## assigned and its waits_for_impact is set, effects don't actually
## apply until Unit.notify_impact() fires (or a timeout elapses) AFTER a
## confirmed hit — see _wait_for_impact_or_timeout. Most abilities have
## no AbilityTiming at all (see that class), in which case effects apply
## immediately, same as always. ability_used (the final result, same
## signal as always) only fires once effects have actually resolved,
## which may now be meaningfully later than when this method was called
## for abilities that do wait.
func use_ability(ability: Ability, target) -> Dictionary:
	var result := {
		"attacker": _owner,
		"target": target,
		"ability": ability,
		# can_act(), the STRICT form, which still counts walking: a unit
		# mid-path cannot also swing. Only being ORDERED is permissive
		# while moving (see UnitActionState.can_be_commanded).
		"busy": not _owner.can_act(),
		"invalid_target": false,
		"in_range": false,
		"already_acted": false,
		"cant_afford_move_cost": false,
		"cant_afford_fp_cost": false,
		"hit": false,
		"damage": 0,
		"effects": [],
	}

	if result.busy:
		return result

	# Turn order, as a hard precondition rather than a UI convention.
	#
	# There was no check here at all: out-of-turn use was prevented only
	# because the hotbar never showed a non-current unit's abilities. Now
	# that the bar follows the SELECTION, that accident is gone and this
	# has to be real — and it should have been anyway, since every AI
	# attack comes through this same path and nothing else was stopping a
	# misbehaving caller from acting out of turn.
	#
	# Only binding on a unit actually IN a fight, the same way move_to()
	# treats it: standing outside a battle means acting freely while it
	# rages.
	if _owner.in_combat() and not _owner.is_my_turn():
		result["busy"] = true
		return result

	# A structural mismatch, independent of range or turn economy — an
	# ally-only ability (heal.tres/cure.tres/bless.tres, anything with
	# AbilityTargeting.requires_ally set) aimed at a hostile target can
	# never be legal, so it's rejected here rather than in is_in_range's
	# geometry check. This is what actually stops a misconfigured
	# AiBehavior (see systems/ai_system) — or any other future caller —
	# from healing an enemy: previously requires_ally_target() was only
	# ever checked in resolve_click_ability(), the PLAYER's click-routing
	# path, never here in the resolution path CombatAI also calls.
	# Deliberately one-directional: an ordinary (non-ally) ability aimed
	# at an ally is NOT rejected — that targeting is hostility-agnostic
	# by design already (see AbilityTargeting.requires_ally's own doc
	# comment; friendly-fire-capable AoE already relies on this).
	if ability.targeting and ability.targeting.requires_ally_target() and target is Unit and _owner.is_hostile_to(target):
		result["invalid_target"] = true
		return result

	result["in_range"] = ability.is_in_range(_owner, target)
	result["already_acted"] = ability.attack_action_spent_by(_owner)
	# Hard precondition, not a clamp — same pattern Ladder.required_move
	# already uses (see Ability.move_cost's own header): an ability with a
	# flat move_cost either fully executes or is refused outright, never
	# "half cast." Out of combat, budget is effectively unlimited (same
	# convention UnitMovement.move_to() uses), so this only ever applies
	# mid-combat.
	result["cant_afford_move_cost"] = _owner.in_combat() and ability.move_cost > 0.0 and _owner.move_remaining < ability.move_cost
	# NOT wrapped in CombatManager.in_combat, unlike move_cost above — FP
	# is a persistent resource that exists whether or not a fight is
	# happening (move_remaining is meaningless out of combat; the FP pool
	# isn't), so casting an FP-costing ability outside combat still has
	# to be affordable. See Ability.fp_cost's own header.
	result["cant_afford_fp_cost"] = ability.fp_cost > 0.0 and _owner.get_pool(StatIds.FP) < ability.fp_cost
	result["out_of_ammo"] = ability.out_of_ammo(_owner)

	if result.already_acted:
		return result

	if not result.in_range:
		return result

	if result.cant_afford_move_cost:
		return result

	if result.cant_afford_fp_cost:
		return result

	if result.out_of_ammo:
		return result

	if _owner.in_combat() and ability.uses_attack_action:
		_owner.has_attacked = true

	if _owner.in_combat() and ability.move_cost > 0.0:
		_owner.spend_move(ability.move_cost)

	if ability.fp_cost > 0.0:
		_owner.set_pool(StatIds.FP, maxi(_owner.get_pool(StatIds.FP) - int(ability.fp_cost), 0))

	_owner.ability_use_started.emit(_owner, target, ability)

	# Face the target the instant the action is confirmed to happen, not
	# gradually — this is what gives CombatAI-driven attacks correct
	# facing too (AI never goes through mouse-hover aiming at all), and
	# covers Jump's facing for free (target is the landing point, so
	# facing it here IS facing the jump direction — no separate rotation
	# logic needed in MoveCasterEffect itself).
	if target is Vector3 or target is Unit:
		_owner.snap_face_point(target if target is Vector3 else target.global_position)

	# Rounds leave the magazine whether or not they hit.
	var gear: GearDamageEffect = _gear_effect(ability)
	var row: AttackRow = gear.row_for(_owner) if gear else null
	var shots: int = row.rof if row else 1
	var item: ItemInstance = item_holding(row) if row else null
	if item:
		shots = item.fire(shots)
	_hits = 1

	if ability.requires_to_hit:
		# The DEFENDER's active statuses (Prone, etc.) can modify how
		# easy THEY are to hit — summed onto the attacker's own skill
		# before rolling, so e.g. Prone's melee bonus/ranged penalty
		# applies regardless of which ability is being used against them.
		# The ATTACKER's own active statuses (Bless, etc.) modify the
		# same target number from the other side — see
		# StatusBehavior.modify_outgoing_attack_to_hit. See _roll_to_hit
		# for the actual target-number math.
		var to_hit := _roll_to_hit(target, ability)
		result["to_hit"] = to_hit
		# Rapid fire (B373): one hit, plus one per full Rcl of margin,
		# up to the shots fired.
		if row and shots > 1 and to_hit.success:
			_hits = mini(shots, 1 + maxi(int(to_hit.margin), 0) / maxi(row.recoil, 1))
		if not to_hit.success:
			SystemLog.print(_miss_log_line(target, ability))
			if to_hit.critical_failure:
				_owner.apply_status(CRIT_FAIL_PENALTY)
			_owner.ability_used.emit(_owner, target, result)
			_maybe_trigger_combat(target)
			return result
		# Every hit but a critical one meets the defender's best defense
		# before anything lands — see best_defense.
		var defense: Dictionary = {} if to_hit.critical_success or not target is Unit 			else defense_against(target, ability)
		if not defense.is_empty():
			target.spend_defense(defense.kind)
			var roll := SuccessRoll.roll_vs(defense.target)
			result["defense"] = defense.merged(roll)
			# A defense stops one hit, plus one per point it made it by
			# (B375) — against a single shot, the whole attack.
			if roll.success:
				_hits -= 1 + maxi(int(roll.margin), 0)
			if _hits <= 0:
				SystemLog.print(_defense_log_line(target, ability, defense.kind))
				_owner.ability_used.emit(_owner, target, result)
				_maybe_trigger_combat(target)
				return result

	result["hit"] = true
	result["hits"] = _hits

	if ability.timing and ability.timing.waits_for_impact:
		_owner.begin_busy()
		await _wait_for_impact_or_timeout(ability.timing.impact_timeout)
		_owner.end_busy()

	# Abilities with requires_to_hit=false never populate "to_hit" above,
	# so they correctly never critical-hit — there's no roll for a crit
	# to attach to (see this project's ability-by-ability scope check:
	# only the two GearDamageEffect basic attacks currently roll to-hit
	# at all).
	var is_critical: bool = result.get("to_hit", {}).get("critical_success", false)

	var effect_data: Dictionary = _apply_effects(target, ability, is_critical)
	result["effects"] = effect_data.effects
	result["damage"] = effect_data.damage

	if effect_data.damage > 0:
		SystemLog.print(_hit_log_line(target, ability))
	else:
		SystemLog.print(_use_log_line(target, ability))

	_owner.ability_used.emit(_owner, target, result)
	_maybe_trigger_combat(target)
	return result


## Attacker's to-hit target number against target for ability — own
## skill plus outgoing modifiers, defender's incoming modifiers and
## altitude advantage if target is a Unit. The one place that sum is
## built: the roll, the AI's expected damage and the player's hit-chance
## readout all start here.
func to_hit_target(target, ability: Ability) -> int:
	var number: int = attack_skill() + _hands_modifier(ability)
	number += _owner.outgoing_attack_to_hit_modifier(target, ability)
	if target is Unit:
		number += floori(target.get_stat(StatIds.SM))
		number += target.incoming_attack_to_hit_modifier(_owner, ability)
		number += ALTITUDE_ADVANTAGE.modify_incoming_attack_to_hit(target, _owner, ability)
		var location: HitLocation = hit_location_for(ability)
		if location:
			number += location.to_hit_penalty
		if ability.requires_to_hit:
			number -= 2 * deceptive_level()
		var gear: GearDamageEffect = _gear_effect(ability)
		if gear and gear.row_for(_owner).kind == AttackRow.Kind.RANGED:
			number += range_penalty(_owner.edge_distance_to(target))
	return number


## B550's speed/range column for distance alone, in metres as yards: 0
## out to 2, -1 at 3, -2 at 5, -3 at 7, -4 at 10, -5 at 15, -6 at 20, and
## on by the same 1-1.5-2-3-5-7 steps. A distance past a step takes the
## next one.
static func range_penalty(distance: float) -> int:
	var penalty: int = 0
	var step: float = 2.0
	var mantissas: Array[float] = [2.0, 3.0, 5.0, 7.0, 10.0, 15.0]
	var i: int = 0
	var scale: float = 1.0
	while distance > step + 0.001:
		penalty -= 1
		i += 1
		if i == mantissas.size():
			i = 0
			scale *= 10.0
		step = mantissas[i] * scale
	return penalty


## The weapon's own say in the roll: -1 per point of ST short of the
## row's minimum (B270; Exhausted's halved ST counts), -4 in the off
## hand (B417), Acc when aimed, and the rapid-fire bonus.
func _hands_modifier(ability: Ability) -> int:
	var effect: GearDamageEffect = _gear_effect(ability)
	if not effect:
		return 0
	var row: AttackRow = effect.row_for(_owner)
	var short: int = row.min_st - floori(_owner.get_stat(StatIds.ST))
	return -maxi(short, 0) + (OFF_HAND_PENALTY if effect.off_hand else 0) \
		+ _aim_bonus(row) + _rof_bonus(row.rof)


## Acc (B269) for a shooter who has aimed. GURPS spends a whole turn on
## an Aim maneuver; here not moving this turn is the aim, so standing to
## shoot is rewarded without another button. Out of combat, always aimed.
func _aim_bonus(row: AttackRow) -> int:
	if row.kind != AttackRow.Kind.RANGED or row.acc <= 0:
		return 0
	if _owner.in_combat() and _owner.move_remaining < _owner.move_per_turn() - 0.001:
		return 0
	return row.acc


## B373's to-hit bonus for many shots at once: +1 at RoF 5, +2 at 9, ...
static func _rof_bonus(rof: int) -> int:
	var bonus: int = 0
	for step in [5, 9, 13, 17, 25, 50]:
		if rof >= step:
			bonus += 1
	return bonus


func _gear_effect(ability: Ability) -> GearDamageEffect:
	if not ability:
		return null
	for e in ability.effects:
		if e is GearDamageEffect:
			return e
	return null


## How many hits the attack being resolved landed — more than one only
## for rapid fire. GearDamageEffect rolls each against DR on its own.
func attack_hits() -> int:
	return _hits


# --- Toggles ------------------------------------------------------------

func is_toggled(toggle: Ability) -> bool:
	return _toggles.has(toggle)


## Switches toggle on or off. On switches off every other toggle in its
## toggle_group — aiming at the head stops aiming at the vitals.
func set_toggled(toggle: Ability, on: bool, notify: bool = true) -> void:
	if on == is_toggled(toggle):
		return
	if on:
		if toggle.toggle_group != &"":
			_toggles = _toggles.filter(func(other: Ability) -> bool: return other.toggle_group != toggle.toggle_group)
		_toggles.append(toggle)
	else:
		_toggles.erase(toggle)
	if notify:
		_owner.toggles_changed.emit(_owner)


## A leveled toggle's level, on or off: 1 until it is first changed.
func toggle_level(toggle: Ability) -> int:
	return _toggle_levels.get(toggle, 1)


func set_toggle_level(toggle: Ability, level: int, notify: bool = true) -> void:
	level = clampi(level, 1, toggle.max_level)
	if level == toggle_level(toggle):
		return
	_toggle_levels[toggle] = level
	if notify:
		_owner.toggles_changed.emit(_owner)


## Deceptive Attack's level while it is on, 0 while it is off.
func deceptive_level() -> int:
	return toggle_level(DECEPTIVE_ATTACK) if is_toggled(DECEPTIVE_ATTACK) else 0


## Deceptive Attack on at level, or off for 0 - set_aim's counterpart,
## for the AI.
func set_deceptive_level(level: int, notify: bool = true) -> void:
	if level > 0:
		set_toggle_level(DECEPTIVE_ATTACK, level, notify)
	set_toggled(DECEPTIVE_ATTACK, level > 0, notify)


## The aim toggle switched on, or null for the torso.
func aim() -> Ability:
	for toggle in _toggles:
		if toggle.hit_location:
			return toggle
	return null


## Aims at toggle's location, or at the torso for null. notify off is
## the AI trying each aim on for size (AiScorer._score_plan) without the
## hotbar redrawing for every guess.
func set_aim(toggle: Ability, notify: bool = true) -> void:
	var current: Ability = aim()
	if current == toggle:
		return
	if toggle:
		set_toggled(toggle, true, notify)
	else:
		set_toggled(current, false, notify)


## Where ability lands if it hits: the aimed location, or null for the
## torso. Only an attack that rolls to hit can be aimed, and only one
## whose damage the location takes — a cutting blow aimed at the vitals
## goes to the torso instead, without the penalty. An attack with no
## damage of a single wound type to aim (an area blast) hits the torso.
func hit_location_for(ability: Ability) -> HitLocation:
	var current: Ability = aim()
	if not (current and ability and ability.requires_to_hit):
		return null
	var location: HitLocation = current.hit_location
	var aimed: bool = false
	for effect in ability.effects:
		var wound_type: int = effect.located_wound_type(_owner)
		if wound_type < 0:
			continue
		if not location.allows(wound_type):
			return null
		aimed = true
	return location if aimed else null


## Pure computation; use_ability() still owns deciding what a miss DOES
## (crit-fail status, log, signal, early return).
func _roll_to_hit(target, ability: Ability) -> Dictionary:
	return SuccessRoll.roll_vs(to_hit_target(target, ability))


## Chance, 0..1, that ability lands on target: the to-hit roll, then the
## defender's best defense against every hit but a critical one. Exactly
## what use_ability() rolls, as odds — an ability that does not roll to
## hit always lands.
func hit_chance(target, ability: Ability) -> float:
	if not ability.requires_to_hit:
		return 1.0
	var attack: Dictionary = SuccessRoll.chances(to_hit_target(target, ability))
	var defense: Dictionary = defense_against(target, ability) if target is Unit else {}
	if defense.is_empty():
		return attack.success
	var defended: float = SuccessRoll.chances(defense.target).success
	return attack.critical_success + (attack.success - attack.critical_success) * (1.0 - defended)


## target's best defense against ability from this unit, as it rolls
## it: less Deceptive Attack's level.
func defense_against(target: Unit, ability: Ability) -> Dictionary:
	var defense: Dictionary = target.best_defense(_owner, ability)
	if not defense.is_empty():
		defense.target -= deceptive_level()
	return defense


## Whether this unit defends at all. A Downed unit is on the ground, and
## one whose status stops its turn (Sleep, Stun, ...) cannot react
## either.
func can_dodge() -> bool:
	return _owner.is_alive() and not _owner.is_downed() and not _owner.status_prevents_turn()


# --- Active defenses (B374-376) ---------------------------------------
# One defense per attack, the highest this unit has right now. Dodge has
# no limit. Parry is 3 + half Basic Attack, -4 for each parry already
# made; Block the same number, once, and only with a shield in hand. Both
# limits run until this unit's own next turn (reset_defenses).

const PARRY_PENALTY: int = -4
## Parrying a weapon with an empty hand.
const BARE_HAND_PARRY: int = -3

var parries: int = 0
var blocked: bool = false


func reset_defenses() -> void:
	parries = 0
	blocked = false


## The defense this unit would roll against ability from attacker:
## {kind: &"dodge"/&"parry"/&"block", target: int}, or {} when it cannot
## defend. The highest target wins; a tie goes to Dodge, then Parry, which
## leave Block for later. Parry is melee only: nothing here is thrown.
func best_defense(attacker: Unit, ability: Ability) -> Dictionary:
	if not can_dodge():
		return {}
	var best: Dictionary = {"kind": &"dodge", "target": dodge_target()}
	if ability.targeting is MeleeEnemyTargeting and parry_target(attacker) > best.target:
		best = {"kind": &"parry", "target": parry_target(attacker)}
	if not blocked and holds_shield() and block_target() > best.target:
		best = {"kind": &"block", "target": block_target()}
	return best


## Counts a defense against its limit — attempted, not only succeeded.
func spend_defense(kind: StringName) -> void:
	if kind == &"parry":
		parries += 1
	elif kind == &"block":
		blocked = true


func parry_target(attacker: Unit) -> int:
	var number: int = _half_skill_defense() + PARRY_PENALTY * parries
	if not _holds_melee_weapon(_owner) and _holds_melee_weapon(attacker):
		number += BARE_HAND_PARRY
	return number


func block_target() -> int:
	return _half_skill_defense()


## Dodge plus DB. The shield's DB is added here rather than in the Dodge
## stat so that halving Dodge (Bloodied, Exhausted) leaves it whole —
## the shield is no smaller for its bearer being hurt.
func dodge_target() -> int:
	return floori(_owner.get_stat(StatIds.DODGE)) + floori(_owner.get_stat(StatIds.DB))


func holds_shield() -> bool:
	for slot in [EquipSlot.Slot.MELEE_MAIN_HAND, EquipSlot.Slot.MELEE_OFF_HAND]:
		var item: ItemInstance = _owner.get_equipped_item(slot)
		if item and item.gear_data and item.gear_data.is_shield:
			return true
	return false


func _half_skill_defense() -> int:
	return 3 + floori(attack_skill() / 2.0) + floori(_owner.get_stat(StatIds.DB))


static func _holds_melee_weapon(unit: Unit) -> bool:
	for slot in [EquipSlot.Slot.MELEE_MAIN_HAND, EquipSlot.Slot.MELEE_OFF_HAND]:
		var item: ItemInstance = unit.get_equipped_item(slot)
		if item and item.gear_data and item.gear_data.weapon_data:
			return true
	return false


## Whether this unit shrugs off status as it lands, by a roll against
## the stat the status names (StatusEffect.resisted_by). Asleep or Downed
## still rolls: resisting is the body or the mind, not a reaction.
func resists(status: StatusEffect, source: Unit) -> bool:
	if not _rolls_to_resist(status, source):
		return false
	var roll: Dictionary = SuccessRoll.roll_vs(resistance_target(status))
	if roll.success:
		SystemLog.print(_resist_log_line(status))
	return roll.success


## The chance status lands on this unit from source, 0..1 — the same
## odds resists() rolls, for the readout.
func status_land_chance(status: StatusEffect, source: Unit) -> float:
	if not _rolls_to_resist(status, source):
		return 1.0
	return 1.0 - SuccessRoll.chances(resistance_target(status)).success


func resistance_target(status: StatusEffect) -> int:
	return floori(_owner.get_stat(status.resisted_by)) + status.resistance_modifier


## Nothing to roll for a status that names no stat, or one from this
## unit itself or an ally: a willing target never resists. No source at
## all (a surface) is rolled against like a hostile one.
func _rolls_to_resist(status: StatusEffect, source: Unit) -> bool:
	if status.resisted_by == &"":
		return false
	return source == null or not is_instance_valid(source) or source.is_hostile_to(_owner)


## Applies every one of ability's effects against target in order,
## aggregating each effect's own "damage" key into one total — usually
## zero or one DamageEffect, but this doesn't assume that; see effects
## for the individual per-effect results if more detail is needed than
## the aggregate.
func _apply_effects(target, ability: Ability, is_critical: bool) -> Dictionary:
	var effect_results: Array = []
	var total_damage: int = 0
	for effect in ability.effects:
		var effect_result: Dictionary = effect.apply(_owner, target, ability, is_critical)
		effect_results.append(effect_result)
		if effect_result.has("damage"):
			total_damage += effect_result["damage"]
	return {"effects": effect_results, "damage": total_damage}


## Starts real combat if this was an out-of-combat hostile act against a
## living Unit — miss or hit, doesn't matter, an attempted attack is still
## aggression. No-op for point/ground-targeted abilities (target isn't a
## Unit) — AoE/ground-targeted hostile abilities deliberately don't
## trigger combat yet; see CombatManager.start_combat_from_hostile_act.
func _maybe_trigger_combat(target) -> void:
	# THIS unit, not the world. Another fight running somewhere else is no
	# reason for an attack over here not to start its own.
	if _owner.in_combat():
		return
	if not target is Unit or not target.is_alive():
		return
	if not _owner.is_hostile_to(target):
		# Not already hostile — but the attack just happened regardless,
		# so it's a provocation: escalate the two FACTIONS to temporary
		# hostility (see FactionRelations), then re-check. Without the
		# re-check, combat would never actually start against a freshly-
		# provoked target, since the base relation is still non-hostile
		# at this exact instant.
		_owner.attacked_non_hostile_unit.emit(_owner, target)
		FactionRelations.escalate_to_temporary_hostile(_owner.faction, target.faction)
		if not _owner.is_hostile_to(target):
			return
	CombatManager.start_combat_from_hostile_act(_owner, target)


## Awaits Unit.impact_triggered, or `timeout` seconds, whichever comes
## first. The timeout exists so an ability with waits_for_impact set,
## but whose animation/VFX ISN'T actually wired up to call
## notify_impact(), doesn't hang the whole turn forever — it just
## resolves a little late instead, a far safer failure mode than a
## stuck game. Polls once per frame rather than trying to build a true
## signal "race" — simpler to reason about, and the cost is negligible
## given timeouts here are measured in single-digit seconds at most.
##
## `done` is wrapped in a single-element Array rather than a bare bool —
## GDScript lambda closures capture local PRIMITIVE variables (bool,
## int, ...) BY VALUE, not by reference, so `done = true` inside the
## lambda would silently mutate a private copy scoped to the lambda
## itself, never the polling loop's own variable below, even though the
## lambda executes correctly and the assignment "succeeds." Arrays are a
## reference type — the lambda and the loop both hold a reference to the
## SAME array object, so mutating its contents (not reassigning the
## variable) actually propagates. This was a real, confirmed bug (found
## via diagnostic prints — both finish() calls fired exactly as
## expected, but the loop never saw it), not a hypothetical one.
func _wait_for_impact_or_timeout(timeout: float) -> void:
	var done := [false]
	var finish := func(): done[0] = true

	_owner.impact_triggered.connect(finish, CONNECT_ONE_SHOT)
	_owner.get_tree().create_timer(timeout).timeout.connect(finish, CONNECT_ONE_SHOT)

	while not done[0]:
		await _owner.get_tree().process_frame


## Describes an ability's target for log messages — a Unit gets its
## colored name, a Vector3 (ground/area targeting) gets a generic label,
## since there's no "name" to show for a point in space.
func _log_target_desc(target) -> String:
	return LogFormat.unit_name(target) if target is Unit else "the target area"


func _miss_log_line(target, ability: Ability) -> String:
	return "%s [i]misses[/i] %s with %s." % [LogFormat.unit_name(_owner), _log_target_desc(target), ability.ability_name]


const _DEFENSE_VERBS: Dictionary = {&"dodge": "dodges", &"parry": "parries", &"block": "blocks"}


func _defense_log_line(target, ability: Ability, kind: StringName) -> String:
	return "%s [i]%s[/i] %s's %s." % [_log_target_desc(target), _DEFENSE_VERBS[kind], LogFormat.unit_name(_owner), ability.ability_name]


func _resist_log_line(status: StatusEffect) -> String:
	return "%s [i]resists[/i] %s." % [LogFormat.unit_name(_owner), status.status_name]


func _hit_log_line(target, ability: Ability) -> String:
	var location: HitLocation = hit_location_for(ability) if target is Unit else null
	if location:
		return "%s hits %s in the %s with %s." % [LogFormat.unit_name(_owner), _log_target_desc(target), location.display_name.to_lower(), ability.ability_name]
	return "%s hits %s with %s." % [LogFormat.unit_name(_owner), _log_target_desc(target), ability.ability_name]


func _use_log_line(target, ability: Ability) -> String:
	return "%s uses %s on %s." % [LogFormat.unit_name(_owner), ability.ability_name, _log_target_desc(target)]


func _damage_log_line(amount: int) -> String:
	return "%s takes %s damage." % [LogFormat.unit_name(_owner), LogFormat.damage(amount)]


func _death_log_line() -> String:
	return "[b]%s has died.[/b]" % LogFormat.unit_name(_owner)


## Restores amount HP, clamped at maximum HP — the positive-direction
## counterpart to take_damage() below. Emits healed() so anything
## watching for an HP change (unit_portrait.gd's live overlay, notably)
## refreshes on the way up too, not just the way down — take_damage()
## already emitted took_damage() for that; nothing on the heal side ever
## emitted its own equivalent, which is why healing correctly changed
## HP but never visibly showed it: HealEffect/AreaHealEffect/
## HealOverTimeBehavior each mutated HP directly, with no
## caller-side way to know it needed to redraw anything. Returns the
## amount ACTUALLY restored (may be less than amount once near/at
## maximum) so callers can log/report exactly how much landed without
## re-deriving before/after themselves.
##
## Any heal that lands on a Downed unit is also a pick-up from range,
## however small — HP stays wherever the heal left it, negative or not.
func heal(amount: int) -> int:
	if amount <= 0:
		return 0
	var before: int = _owner.get_pool(StatIds.HP)
	_owner.set_pool(StatIds.HP, mini(_owner.get_pool(StatIds.HP) + amount, floori(_owner.get_stat(StatIds.HP))))
	var applied: int = _owner.get_pool(StatIds.HP) - before
	if applied > 0:
		_owner.healed.emit(_owner, applied)
		pick_up()
	return applied


## A unit on the downed rule (Unit.uses_downed_rule) keeps going below 0
## HP. Each time a hit carries it past a threshold — 0, -1x HP, -2x HP,
## -3x HP, -4x HP — it rolls HT once, at the deepest threshold reached,
## or goes Downed. -5x HP is death outright. GURPS's negative-HP death
## checks, turned into a downed state: see downed_status().
##
## A Downed unit has no further threshold rolls; every hit on it is
## instead a mark toward death (DeathRollsBehavior), on top of the
## damage.
func take_damage(amount: int, critical: bool = false) -> void:
	if amount <= 0:
		return
	var before: int = _owner.get_pool(StatIds.HP)
	var floor_hp: int = -DEATH_DEPTH * _hp_step() if _owner.uses_downed_rule() else 0
	_owner.set_pool(StatIds.HP, max(before - amount, floor_hp))
	_owner.took_damage.emit(_owner, amount)
	SystemLog.print(_damage_log_line(amount))
	var was_downed: bool = _owner.is_downed()
	# Downed's own behaviors mark the hit here — and kill, if it was the
	# third mark toward death.
	_owner.notify_status_of_damage(amount, critical)
	if _owner.has_died:
		return

	if _owner.get_pool(StatIds.HP) <= floor_hp:
		_die()
	elif not was_downed:
		var crossed: int = _thresholds_crossed(before, _owner.get_pool(StatIds.HP))
		if crossed > 0:
			_roll_to_stay_up(crossed)


func hp_to_death() -> int:
	if _owner.uses_downed_rule():
		return _owner.get_pool(StatIds.HP) + DEATH_DEPTH * _hp_step()
	return _owner.get_pool(StatIds.HP)


## Clears Downed and leaves HP negative — getting back up does not heal
## anything. No roll until the next threshold. Healing calls this too.
func pick_up() -> bool:
	if not _owner.is_downed():
		return false
	_owner.remove_status(downed_status())
	SystemLog.print("%s is back on their feet at %d HP." % [LogFormat.unit_name(_owner), _owner.get_pool(StatIds.HP)])
	_owner.downed_changed.emit(_owner)
	return true


## The Downed status (data/statuses/downed.tres) is the only record of
## being Downed: its tally is the two tracks, its behaviors roll and
## mark them. Loaded rather than preloaded — the .tres's
## behavior scripts name Unit, which names this.
static var _downed_status: StatusEffect

static func downed_status() -> StatusEffect:
	if _downed_status == null:
		_downed_status = load("res://data/statuses/downed.tres")
	return _downed_status


func stabilize() -> void:
	if not _owner.is_downed() or _owner.is_stable():
		return
	_owner.downed_tally()["stable"] = DeathRollsBehavior.TO_END
	_owner.downed_tally_changed.emit(_owner)
	SystemLog.print("%s is stable, but still down at %d HP." % [LogFormat.unit_name(_owner), _owner.get_pool(StatIds.HP)])


## Thresholds sit at 0 and every negative multiple of HP above the death
## line. Reaching one exactly counts as crossing it.
func _thresholds_crossed(before: int, after: int) -> int:
	var crossed: int = 0
	for depth in DEATH_DEPTH:
		var threshold: int = -depth * _hp_step()
		if before > threshold and after <= threshold:
			crossed += 1
	return crossed


## HT, minus 1 per full multiple of HP below zero (the GURPS depth
## penalty), minus 1 more per threshold this one hit crossed — a single
## blow that goes through several is that much harder to stay standing
## through.
func _roll_to_stay_up(crossed: int) -> void:
	var penalty: int = _depth() + crossed
	var roll: Dictionary = SuccessRoll.roll_vs(floori(_owner.get_stat(StatIds.HT)) - penalty)
	var verdict: String = "stays up" if roll["success"] else "goes down"
	SystemLog.print("%s rolls HT-%d to stay up: %d vs %d — %s." % [
		LogFormat.unit_name(_owner), penalty, roll["roll"], roll["target"], verdict])
	if roll["success"]:
		return
	_owner.apply_status(downed_status())
	SystemLog.print("[b]%s is Downed![/b]" % LogFormat.unit_name(_owner))
	_owner.downed_changed.emit(_owner)


## Each Downed turn's roll (DeathRollsBehavior): HT minus the same depth
## penalty as staying up.
func roll_while_downed() -> Dictionary:
	var penalty: int = _depth()
	var roll: Dictionary = SuccessRoll.roll_vs(floori(_owner.get_stat(StatIds.HT)) - penalty)
	var verdict: String = "success" if roll["success"] else "failure"
	if roll["critical_success"] or roll["critical_failure"]:
		verdict = "critical " + verdict
	SystemLog.print("%s rolls HT-%d while down: %d vs %d — %s." % [
		LogFormat.unit_name(_owner), penalty, roll["roll"], roll["target"], verdict])
	return roll


## Full multiples of HP below zero.
func _depth() -> int:
	var hp: int = _owner.get_pool(StatIds.HP)
	return -hp / _hp_step() if hp < 0 else 0


func _hp_step() -> int:
	return maxi(floori(_owner.get_stat(StatIds.HP)), 1)


## A dead owned demon stays in the roster, marked dead, rather than being
## released — so it can be revived.
func _die() -> void:
	SystemLog.print(_death_log_line())
	if _owner.owned_demon:
		_owner.owned_demon.capture_pools(_owner)
		_owner.owned_demon.is_dead = true
	_owner.handle_death()
	_owner.died.emit(_owner)
