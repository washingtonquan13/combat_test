extends Node
## Autoload singleton. Register as "SystemLog" under
## Project > Project Settings > AutoLoad.
##
## The single, game-wide log — not specific to combat. Any system
## (combat, dialogue, inventory, saves, quests, whatever gets built
## later) calls SystemLog.print("message") directly at the point
## something worth recording happens, with zero knowledge of whether any
## UI is even listening. The UI (see combat_log.gd) just displays
## whatever comes through line_logged — it doesn't know or care WHERE a
## message came from, which is what keeps this reusable for anything,
## not rebuilt per-system.
##
## Persists across scene changes (autoloads always do) — lines logged
## before any log UI even exists in the tree yet aren't lost; a UI that
## opens later can read `lines` directly on its own _ready() to catch up
## on everything that already happened.

signal line_logged(bbcode_line: String)
## Emitted instead of line_logged specifically when adding a line also
## triggered trimming — listeners should throw away whatever they've
## rendered so far and rebuild fresh from `lines`, rather than just
## appending one more line, since the OLDEST entries silently dropped
## out from under them and a simple append would leave their display
## growing forever even though the underlying data here is capped.
signal log_rebuilt()

var lines: Array[String] = []

## Prevents unbounded growth over a long session. Trimmed here, at the
## single source of truth, rather than in every UI that might display
## this data — if you ever have more than one log view (a combat-only
## filtered one AND a full system log, say), they'd otherwise each need
## their own trimming logic instead of sharing one.
var max_lines: int = 500


func print(bbcode_line: String) -> void:
	lines.append(bbcode_line)
	if lines.size() > max_lines:
		lines = lines.slice(lines.size() - max_lines, lines.size())
		log_rebuilt.emit()
	else:
		line_logged.emit(bbcode_line)


func clear_log() -> void:
	lines.clear()
