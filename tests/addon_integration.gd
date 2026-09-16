extends SceneTree

# Run in the integration project containing AddonLib and SyntaxPlus.
const Parser = preload("res://addons/addon_lib/gdscript_parser/gdscript_parser.gd")
var failures := 0

func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		printerr("FAIL: " + message)

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var editor := Node.new()
	editor.name = "EditorNode"
	root.add_child(editor)
	var script := GDScript.new()
	script.source_code = "extends RefCounted\nvar amount: int = 2\nfunc read(value: int) -> int:\n\treturn amount + value\n"
	script.reload()
	var edit := CodeEdit.new()
	editor.add_child(edit)
	edit.text = script.source_code
	var native = Parser.new()
	native.set_current_script(script)
	native.set_code_edit(edit)
	native.parse()
	if not ClassDB.class_exists("GDScriptLanguageService"):
		check(not native.use_native_backend, "AddonLib selects GDScript when the extension is absent")
		check(native.get_class_object().get_member_data("amount").member_name == &"amount", "extension-absent extraction")
		check(native.get_class_object().get_function("read") != null, "extension-absent function extraction")
		editor.free()
		print("PASS: AddonLib without any native parser extension")
		quit(1 if failures else 0)
		return
	check(native.use_native_backend, "AddonLib selects native backend")
	check(native.get_class_object().get_member_data("amount").type == &"int", "AddonLib native member projection")
	check(native.get_class_object().get_function("read") != null, "AddonLib native function projection")
	var manager = native.get_code_edit_parser().native_manager
	var revision: int = manager.get_parse_revision()
	# A highlighter consumes the sparse read before the full parser gets to run.
	edit.text = "\n" + script.source_code.replace("amount", "total")
	manager.sparse_parse()
	native.parse()
	check(native.get_class_object().get_member_data("total").type == &"int", "full parser observes a revision already read by highlighting")
	check(manager.get_parse_revision() > revision, "shared revision advanced")
	var full_revision: int = manager.get_parse_revision()
	native.parse()
	check(manager.get_parse_revision() == full_revision, "full parser repeat reuses syntax snapshot")
	edit.text = "\n" + edit.text
	native.sync_line_ranges()
	check(native.get_class_object().get_function("read").declaration_line == 4, "sparse line synchronization updates functions")
	var fallback = Parser.new()
	fallback.set_use_native_backend(false)
	fallback.set_current_script(script)
	fallback.set_code_edit(edit)
	fallback.parse(true)
	check(fallback.get_class_object().get_member_data("total").member_name == &"total", "AddonLib GDScript fallback retains extraction")
	manager.detach()
	native = null
	fallback = null
	editor.free()
	if failures == 0:
		print("PASS: AddonLib native integration, revision isolation, ranges and GDScript fallback")
	quit(1 if failures else 0)
