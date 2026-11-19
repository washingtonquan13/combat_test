"""The Morrow overworld's fixed layout: the map's size, the town's streets,
the landmarks every stage builds round. Read by morrow_terrain.py (stage 1,
the ground) and morrow_overworld.py (the scene), so a door moved here moves
its flattened pad, its paint and its node together.
"""

HALF = 800.0           # the playable map is 1600 m square
STREET = 80.0          # street pitch downtown
ROAD = 20.0            # street width
DOWNTOWN = 240.0       # downtown streets run from -240 to 240
OUTSKIRTS = 440.0      # houses thin out into the woods past this
SQUARE = 70.0          # half-size of the open central square
DOOR_SCALE = 4.0

# Doors: name, area id, position (x, z), yaw in degrees.
DOORS = [
    ("CathedralSteps", "cathedral_of_shadows", (0.0, -60.0), 0.0),
    ("ArenaGate", "test_arena", (-55.0, 30.0), 0.0),
    ("MarketHall", "test_area_2", (160.0, 120.0), 0.0),
    ("OldDocks", "test_area_3", (-160.0, -200.0), 0.0),
    ("OldQuarry", "goblin_quarry", (-640.0, 40.0), 0.0),
]
START = (0.0, 20.0)
SAFE_SPOT = (55.0, 30.0)   # the inn on the square: free rests (rest_spot.gd)
INN_HOUSE = (0.0, -12.0)   # the inn's house, from SAFE_SPOT

QUARRY_CLEARING = (-640.0, 40.0)
LAKE = (520.0, -480.0, 110.0)   # x, z, radius

# The Greywood's shapes. A ridge across the north, crossed by the north
# trail in a cutting, and a river down the west, forded by the quarry road.
RIDGE = [(-320.0, 720.0), (80.0, 600.0), (440.0, 650.0), (840.0, 560.0)]
RIDGE_HEIGHT = 42.0
RIDGE_HALF_WIDTH = 200.0
RIVER = [(-540.0, -1030.0), (-470.0, -560.0), (-395.0, -170.0), (-455.0, 160.0),
         (-375.0, 520.0), (-430.0, 1030.0)]


def street_lines():
    n = int(DOWNTOWN // STREET)
    return [i * STREET for i in range(-n, n + 1)]
