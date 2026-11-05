extends GameArea
## test_arena's own content: the starting-party bootstrap, so tests and
## probes that load straight into this area still get a party. The goblin
## raid quest lives in goblin_quarry now; the goblinoids here are plain
## test fixtures.


func _ready() -> void:
	StartingParty.bootstrap(self, $PartySpawnPoint)
