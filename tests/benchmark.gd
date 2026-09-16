extends SceneTree

func _initialize() -> void:
	_run.call_deferred()

func percentile(values: Array[int], fraction: float) -> int:
	values.sort()
	return values[mini(values.size() - 1, int(values.size() * fraction))]

func _run() -> void:
	if not ClassDB.class_exists(&"GDScriptTreeParser"):
		quit()
		return
	var old: Object = ClassDB.instantiate(&"GDScriptTreeParser")
	var native: Object = ClassDB.instantiate(&"GDScriptLanguageService")
	var source := "extends RefCounted\n"
	for index in range(250):
		source += "func method_%s(value: int = 0):\n\tvar data = [value, (1 + 2)]\n\treturn data\n\n" % index
	old.open_text(source)
	old.set_bracket_mode(true)
	native.update_document("res://benchmark.gd", source, 1)
	native.document("res://benchmark.gd").set_bracket_mode(true)
	var old_times: Array[int] = []
	var new_times: Array[int] = []
	for index in range(120):
		var edited := source.replace("(1 + 2)", "(1 + %s)" % (index % 2 + 2))
		var started := Time.get_ticks_usec()
		old.update_text(edited)
		old.sparse_parse()
		var old_elapsed := Time.get_ticks_usec() - started
		started = Time.get_ticks_usec()
		native.update_document("res://benchmark.gd", edited, index + 2)
		native.document("res://benchmark.gd").sparse_parse()
		var new_elapsed := Time.get_ticks_usec() - started
		if index >= 20:
			old_times.append(old_elapsed)
			new_times.append(new_elapsed)
	print("Edit + sparse + brackets (1001 lines), microseconds: old p50=%s p95=%s; new p50=%s p95=%s" % [percentile(old_times, 0.5), percentile(old_times, 0.95), percentile(new_times, 0.5), percentile(new_times, 0.95)])
	quit()
