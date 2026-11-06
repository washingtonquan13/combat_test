extends SceneTree
# Temporary probe: a warning said from a never-waited WorkerThreadPool task.

static func _later(texts: PackedStringArray) -> void:
	WorkerThreadPool.add_task(func():
		for text in texts:
			push_warning(text), false, "probe")

func _initialize() -> void:
	var t := Time.get_ticks_usec()
	_later(PackedStringArray(["one", "two", "three"]))
	print("queued in %.2f ms" % [(Time.get_ticks_usec() - t) / 1e3])
	quit(0)
