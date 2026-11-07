class_name FormationPlanner
extends RefCounted
## Issues a leader-driven, deterministic group move — the free-roam
## (non-combat) formation logic pulled out of ground_click_target.gd's
## _command_move(), since that router's job is deciding WHAT a click
## means, not owning the formation math itself.
##
## Leader-driven, but not live: every mover is planned ONCE, by a single
## move_to() per unit below. Each move ignores the whole group (selected
## movers plus chain followers), since they are all about to leave where
## they stand; every other unit is avoided at its live position (the
## grid checks occupancy on every query, see NavigationGrid). A live
## "followers re-target the leader's CURRENT position" version was tried
## and reverted, when occupancy was still a manual snapshot; it would
## need re-checking before trying again.
##
## The leader goes exactly to the clicked point; everyone else gets a
## destination offset onto an evenly-spaced ring around that SAME point,
## not tied to any unit's current position — a fixed personal offset read
## as "everyone lining up side by side" when this was tried before.

## Commands every unit in `units` to move toward `destination` as a
## group: decides where each unit is headed and issues the move.
## The leader is whoever PlayerInteractionState.get_active_unit()
## resolves to ("first selected" out of combat); if that's null (nothing
## selected), every unit is just sent straight to destination instead.
##
## Chaining (BG3 style): out of combat, the party members the player did
## NOT move come along too — see PartyManager.chain_followers for who
## qualifies. Living here because this is the one place every free-roam
## group move passes through (ClickRouter.command_move calls it for every
## move that isn't a lone combatant on its turn), so no click path needs
## to know chaining exists. Chain followers share the movers' ring: they
## take the slots after the selected followers, so nobody is sent to the
## same spot.
static func command_group_move(units: Array[Unit], destination: Vector3) -> void:
	var leader: Unit = _leader_of(units)
	if not leader:
		for unit in units:
			unit.move_to(destination, units)
		return

	var followers: Array[Unit] = []
	for unit in units:
		if unit != leader:
			followers.append(unit)

	var chain: Array[Unit] = PartyManager.chain_followers(leader, units)
	followers.append_array(chain)
	var everyone: Array = group_of(units, chain)

	leader.move_to(destination, everyone)
	for i in followers.size():
		var offset: Vector3 = ring_offset(i, followers.size(), leader.formation_spread_radius)
		followers[i].move_to(destination + offset, everyone)

	if not chain.is_empty():
		PartyManager.note_chain_walkers(chain)


## The ignore list a move order to `units` routes with: empty for a lone
## combatant on its turn (ClickRouter.command_move's own split), else
## everyone command_group_move sets walking. The movement preview passes
## this, so it draws the route the move will take.
static func move_ignore(units: Array[Unit]) -> Array:
	if units.is_empty() or (units.size() == 1 and units[0].in_combat()):
		return []
	var leader: Unit = _leader_of(units)
	if not leader:
		return units.duplicate()
	return group_of(units, PartyManager.chain_followers(leader, units))


static func _leader_of(units: Array[Unit]) -> Unit:
	return PartyManager.leader if PartyManager.leader in units else PlayerInteractionState.get_active_unit()


## Everyone a group move sets walking: the movers and their chain
## followers. Each one's route ignores the rest.
static func group_of(units: Array, chain: Array) -> Array:
	var everyone: Array = []
	everyone.append_array(units)
	everyone.append_array(chain)
	return everyone


## One point on an evenly-spaced ring of `count` points around the
## origin, at index `index` — the same "everyone lining up side by side"
## math command_group_move uses for its followers, factored out so
## PartyManager.spawn_party() can spread a freshly-spawned party around
## its own landing point instead of stacking every member on the exact
## same coordinate (see that file's own header for why coincident spawns
## are a real bug, not just a visual nicety).
static func ring_offset(index: int, count: int, radius: float) -> Vector3:
	var angle: float = TAU * float(index) / float(count)
	return Vector3(cos(angle), 0.0, sin(angle)) * radius
