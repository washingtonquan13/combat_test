extends GameArea
## The spider cave under the quarry's south cliff: a dark chamber with a
## raised ledge, a gallery and a squeeze looping round it, and one shaft of
## daylight from a hole in the roof. The roof is one-sided to the camera
## (see tools/cave/bake_spider_cave.gd), so the tactical view looks in from
## above like a dollhouse.


func _ready() -> void:
	StartingParty.bootstrap(self, $PartySpawnPoint)
