class_name FormationPlanner
extends RefCounted
## Issues a leader-driven, deterministic group move — the free-roam
## (non-combat) formation logic pulled out of ground_click_target.gd's
## _command_move(), since that router's job is deciding WHAT a click
## means, not owning the formation math itself.
##
## Leader-driven, but not live: every mover is planned ONCE, by the
## caller's single move_to() per unit below, against whatever
## NavigationGrid occupancy snapshot the caller already took (see
## NavigationGrid.update_occupancy) — exactly like every other move in
## this game. A live "followers re-target the leader's CURRENT position"
## version was tried and reverted: it meant repeatedly re-planning
## against NavigationGrid.find_path(), which never refreshes occupancy
## itself, so every re-plan read an increasingly stale snapshot in which
## every mover was still excluded from occupancy, and followers walked
## straight through each other and the leader for the whole trip.
##
## The leader goes exactly to the clicked point; everyone else gets a
## destination offset onto an evenly-spaced ring around that SAME point,
## not tied to any unit's current position — a fixed personal offset read
## as "everyone lining up side by side" when this was tried before.

## Commands every unit in `units` to move toward `destination` as a
## group. Caller is responsible for refreshing NavigationGrid occupancy
## first (see ground_click_target.gd) — this only decides where each
## unit is headed and issues the move, it doesn't touch occupancy itself.
## The leader is whoever PlayerInteractionState.get_active_unit()
## resolves to ("first selected" out of combat); if that's null (nothing
## selected), every unit is just sent straight to destination instead.
static func command_group_move(units: Array[Unit], destination: Vector3) -> void:
	var leader: Unit = PartyManager.leader if PartyManager.leader in units else PlayerInteractionState.get_active_unit()
	if not leader:
		for unit in units:
			unit.move_to(destination)
		return

	var followers: Array[Unit] = []
	for unit in units:
		if unit != leader:
			followers.append(unit)

	leader.move_to(destination)
	for i in followers.size():
		var offset: Vector3 = ring_offset(i, followers.size(), leader.formation_spread_radius)
		followers[i].move_to(destination + offset)


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
