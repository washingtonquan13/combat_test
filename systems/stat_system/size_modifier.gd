class_name SizeModifier
extends RefCounted
## GURPS Size Modifier as a physical size (Basic Set, p. 19): the length
## of a creature's longest dimension for each SM. SM 0 is 2 yards, a man;
## every 6 SM is ten times longer, and in between it runs 1, 1.5, 2, 3, 5,
## 7. A yard is taken as a meter, as Move is (stats.md).

## Longest dimension, in yards, for SM -2 up to SM +3; the rest is this
## times a power of ten.
const STEPS: Array[float] = [1.0, 1.5, 2.0, 3.0, 5.0, 7.0]


## The longest dimension, in meters, of a creature of SM sm.
static func length_for(sm: int) -> float:
	var k: int = sm + 2
	var decade: int = floori(k / 6.0)
	return STEPS[k - decade * 6] * pow(10.0, decade)


## How much bigger a creature of SM sm is than one of SM authored: the
## scale a body built at authored's size is worn at.
static func scale_for(sm: int, authored: int = 0) -> float:
	return length_for(sm) / length_for(authored)
