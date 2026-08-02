extends RichTextLabel
## System log display. Despite the filename (kept as-is so the existing
## scene node doesn't need re-attaching to a renamed script), this is no
## longer combat-specific at all — it's a pure renderer for SystemLog,
## which any system in the game can write to. It has zero knowledge of
## CombatManager, Unit, or anything else that might be logging; it just
## listens to SystemLog.line_logged and displays whatever comes through.
##
## Expects to be the child of a ScrollContainer (Panel > ScrollContainer
## > RichTextLabel), which OWNS scrolling — this RichTextLabel grows to
## fit all its content (fit_content = true) rather than doing its own
## internal scrolling. Its horizontal size should fill the
## ScrollContainer's width (size_flags_horizontal = Fill, or matching
## anchors); fit_content only grows it vertically.
##
## On _ready(), replays whatever's already in SystemLog.lines — combat
## (or anything else) may have started logging before this UI node even
## existed in the tree, and those lines shouldn't be lost.
##
## Auto-scroll only follows new lines if the view was ALREADY at the
## bottom before they arrived — reading back through older entries
## shouldn't get yanked back down every time something new is logged,
## same as any chat/log UI (Discord, a terminal, etc). The "was at
## bottom" check has to happen BEFORE new content is appended, not
## after — checking after would already reflect the taller content and
## incorrectly say "yes, at the bottom" even when the view didn't move.

@export var font_size: int = 12
@export var auto_scroll_to_bottom: bool = true

var _scroll_container: ScrollContainer


func _ready() -> void:
	bbcode_enabled = true
	fit_content = true
	scroll_active = false
	add_theme_font_size_override("normal_font_size", font_size)
	add_theme_font_size_override("bold_font_size", font_size)
	add_theme_font_size_override("italics_font_size", font_size)
	add_theme_font_size_override("bold_italics_font_size", font_size)

	_scroll_container = get_parent() as ScrollContainer
	if not _scroll_container:
		push_warning("combat_log.gd expects its parent to be a ScrollContainer — found %s instead. Auto-scroll-to-bottom will be disabled." % get_parent())

	SystemLog.line_logged.connect(_on_line_logged)
	SystemLog.log_rebuilt.connect(_on_log_rebuilt)

	_on_log_rebuilt()  # initial full render, catching up on anything already logged


func _on_line_logged(bbcode_line: String) -> void:
	var was_at_bottom: bool = _is_scrolled_to_bottom()
	append_text(bbcode_line + "\n")
	if was_at_bottom:
		_scroll_to_bottom_deferred()


## Called on startup (to catch up) and whenever SystemLog trims its
## oldest entries — rebuilds from scratch rather than appending, since
## this display otherwise has no way to "un-append" text that's no
## longer in SystemLog.lines.
func _on_log_rebuilt() -> void:
	var was_at_bottom: bool = _is_scrolled_to_bottom()
	clear()
	for line in SystemLog.lines:
		append_text(line + "\n")
	if was_at_bottom:
		_scroll_to_bottom_deferred()


## True if there's no meaningful room left to scroll down further — on
## a freshly-cleared/empty log (nothing to scroll at all yet) this is
## trivially true too, which is exactly the behavior wanted on first
## opening the log: no prior scroll position to preserve, so it should
## just track the bottom from the start.
func _is_scrolled_to_bottom() -> bool:
	if not _scroll_container:
		return false
	var v_scroll: VScrollBar = _scroll_container.get_v_scroll_bar()
	if not v_scroll:
		return false
	return v_scroll.value + v_scroll.page >= v_scroll.max_value - 1.0


func _scroll_to_bottom_deferred() -> void:
	if auto_scroll_to_bottom and _scroll_container:
		# Deferred, not immediate — append_text/fit_content resizing this
		# RichTextLabel happens through Godot's layout system, which
		# hasn't necessarily run yet on the same line this was called
		# from. Scrolling immediately would use the PREVIOUS (shorter)
		# content height and land short of the true new bottom.
		_scroll_to_bottom.call_deferred()


func _scroll_to_bottom() -> void:
	if not _scroll_container:
		return
	var v_scroll: VScrollBar = _scroll_container.get_v_scroll_bar()
	if v_scroll:
		_scroll_container.scroll_vertical = int(v_scroll.max_value)
