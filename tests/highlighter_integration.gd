extends SceneTree

const Parser = preload("res://addons/addon_lib/gdscript_parser/gdscript_parser.gd")
const Highlighter = preload("res://addons/syntax_plus/src/highlighter/highlighter_logic.gd")
const EditorParser = Highlighter.EditorGDScriptParser
const SCRIPT_A := "res://highlight_a.gd"
const SCRIPT_B := "res://highlight_b.gd"
const SOURCE_A := "extends RefCounted\nvar alpha: int\n"
const SOURCE_B := "extends RefCounted\nvar saved: int\nfunc read(value: int):\n\treturn (saved + value)\nclass Inner:\n\tvar nested: int\n"

# Control the tab-switch window without editor signals or readiness timers.
class ControlledEditorParser extends EditorParser:
	func _ready() -> void:
		pass

var failures := 0

func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		printerr("FAIL: " + message)

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	for path in {SCRIPT_A: SOURCE_A, SCRIPT_B: SOURCE_B}:
		var file := FileAccess.open(path, FileAccess.WRITE)
		file.store_string(SOURCE_A if path == SCRIPT_A else SOURCE_B)
		file.close()
	var editor := Node.new()
	editor.name = "EditorNode"
	root.add_child(editor)
	var singleton_parent := Node.new()
	editor.add_child(singleton_parent)
	EditorParser._singleton_node_parents[EditorParser._get_singleton_node_path()] = singleton_parent
	var singleton := ControlledEditorParser.new(editor)
	singleton.name = EditorParser.get_singleton_name()
	singleton_parent.add_child(singleton)
	var edit_a := CodeEdit.new()
	var edit_b := CodeEdit.new()
	editor.add_child(edit_a)
	editor.add_child(edit_b)
	edit_a.text = SOURCE_A
	edit_b.text = SOURCE_B.replace("saved", "unsaved")
	var active = singleton.gdscript_parser
	active.active_parser = active
	active.set_parser_cache({})
	active.set_parse_cache_dir("res://.godot/highlighter-cache")
	active.set_current_script(load(SCRIPT_A))
	active.set_code_edit(edit_a)
	active.parse()
	var reader = active.get_parser_for_path(SCRIPT_B, true)
	check(reader.state == Parser.STATE_LIVE, "dependency reader is STATE_LIVE")
	check(not is_instance_valid(reader.code_edit_parser.native_manager), "dependency reader has no manager")
	var native := ClassDB.class_exists(&"GDScriptLanguageService")
	if native:
		check(reader.get_class_object().use_ts, "dependency reader uses native structure")
	Highlighter.member_enable = true
	Highlighter.argument_enable = true
	Highlighter.inner_class_member_enable = true
	Highlighter.bracket_enable = true
	var highlighter := Highlighter.new()
	highlighter.script_resource = load(SCRIPT_B)
	highlighter.set_text_edit(edit_b)
	highlighter.update_class_members()
	check(highlighter.member_highlighter.highlight_words.has("unsaved"), "opening B highlights its unsaved member while A is active")
	check(not highlighter.member_highlighter.highlight_words.has("saved"), "opening B never highlights its disk-only member")
	check(highlighter.get_gdscript_parser().code_edit == edit_b, "selected parser uses the highlighted CodeEdit")
	check(not is_instance_valid(reader.code_edit_parser.native_manager), "highlighting leaves dependency reader manager-free")
	if failures:
		quit(1)
		return
	check(highlighter.inner_class_highlighters["Inner"][Highlighter.Keys.HELPER].highlight_words.has("nested"), "inner class members are highlighted")
	check(highlighter.func_arg_highlighters[""]["read"][Highlighter.Keys.HELPER].highlight_words.has("value"), "arguments are highlighted")
	if native:
		check(not highlighter.bracket_map.is_empty(), "brackets are available on first update")
	var private_parser = highlighter.get_gdscript_parser()
	var manager = private_parser.code_edit_parser.native_manager
	var revision: int = manager.get_parse_revision() if native else -1
	highlighter.init_scan_done = true
	check(not highlighter.update_class_members(), "unchanged highlight update reuses member words")
	if native:
		check(manager.get_parse_revision() == revision, "unchanged highlight update preserves native revision")
	# The shared parser now has B's buffer, but has not parsed it yet.
	active.set_current_script(load(SCRIPT_B))
	active.set_code_edit(edit_b)
	highlighter.update_class_members()
	check(highlighter.get_gdscript_parser() == active, "adopts the editor parser after the tab switch")
	check(highlighter.member_highlighter.highlight_words.has("unsaved"), "adoption preserves unsaved member highlighting")
	if native:
		check(active.code_edit_parser.native_manager._edit == edit_b, "adoption rebinds the existing manager")
	# Matching identity with no prior parse must initialize before the native read.
	var fresh = Parser.new()
	fresh.active_parser = fresh
	fresh.set_parser_cache({})
	fresh.set_current_script(load(SCRIPT_B))
	fresh.set_code_edit(edit_b)
	singleton.gdscript_parser = fresh
	highlighter.update_class_members()
	check(highlighter.get_gdscript_parser() == fresh, "adopts an initially unparsed matching editor parser")
	check(highlighter.member_highlighter.highlight_words.has("unsaved"), "initially unparsed editor parser supplies highlights")
	# Reuse the highlighter on A while the editor singleton still points to B.
	highlighter.script_resource = load(SCRIPT_A)
	highlighter.set_text_edit(edit_a)
	highlighter.update_class_members()
	check(highlighter.get_gdscript_parser().code_edit == edit_a, "private parser follows a changed highlighter buffer")
	check(highlighter.member_highlighter.highlight_words.has("alpha"), "switching back highlights A")
	check(not highlighter.member_highlighter.highlight_words.has("unsaved"), "switching back removes B's member words")
	# Same script in a different buffer must also reject the editor parser.
	var other_edit := CodeEdit.new()
	editor.add_child(other_edit)
	other_edit.text = SOURCE_B.replace("saved", "other_buffer")
	highlighter.script_resource = load(SCRIPT_B)
	highlighter.set_text_edit(other_edit)
	highlighter.update_class_members()
	check(highlighter.get_gdscript_parser() != fresh, "same path with a different CodeEdit uses a private parser")
	check(highlighter.member_highlighter.highlight_words.has("other_buffer"), "same-path buffer highlights its own text")
	for parser in [active, fresh, private_parser, highlighter.gdscript_parser, reader]:
		if is_instance_valid(parser.code_edit_parser.native_manager):
			parser.code_edit_parser.native_manager.detach()
		parser.active_parser = null
		parser.set_parser_cache({})
	reader.code_edit.free()
	highlighter = null
	EditorParser._singleton_node_parents.clear()
	editor.free()
	if failures == 0:
		print("PASS: Syntax Plus first-open, unsaved buffers, parser adoption and tab switching (%s)" % ("native" if native else "native-absent"))
	quit(1 if failures else 0)
