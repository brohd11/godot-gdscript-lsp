#include "structural_document.hpp"
#include <godot_cpp/core/class_db.hpp>

namespace godot {
void GDScriptLSPDocument::_bind_methods() {
    ClassDB::bind_method(D_METHOD("get_revision"), &GDScriptLSPDocument::get_revision);
    ClassDB::bind_method(D_METHOD("get_source_code"), &GDScriptLSPDocument::get_source_code);
    ClassDB::bind_method(D_METHOD("get_source_hash"), &GDScriptLSPDocument::get_source_hash);
    ClassDB::bind_method(D_METHOD("parse_script", "script_path"), &GDScriptLSPDocument::parse_script);
    ClassDB::bind_method(D_METHOD("sparse_parse"), &GDScriptLSPDocument::sparse_parse);
    ClassDB::bind_method(D_METHOD("set_bracket_mode", "enabled"), &GDScriptLSPDocument::set_bracket_mode);
    ClassDB::bind_method(D_METHOD("get_bracket_mode"), &GDScriptLSPDocument::get_bracket_mode);
    ClassDB::bind_method(D_METHOD("get_brackets"), &GDScriptLSPDocument::get_brackets);
    ClassDB::bind_method(D_METHOD("clear_brackets"), &GDScriptLSPDocument::clear_brackets);
}

String GDScriptLSPDocument::get_source_code() const {
    if (!_snapshot) return {};
    const auto &source = _snapshot->source();
    return String::utf8(source.data(), static_cast<int64_t>(source.size()));
}

String GDScriptLSPDocument::get_source_hash() {
    if (_source_hash.is_empty()) _source_hash = get_source_code().sha256_text();
    return _source_hash;
}

void GDScriptLSPDocument::set_snapshot(std::shared_ptr<const gdscript_lsp::Document> snapshot,
        std::optional<int64_t> revision) {
    const bool incremental = _snapshot && snapshot->edit().has_value();
    _source_hash = String();
    _snapshot = std::move(snapshot);
    _revision = revision.value_or(_snapshot->version());
    _tree = _snapshot->concrete_tree();
    _src_len = static_cast<uint32_t>(_snapshot->source().size());
    _full_revision = _sparse_revision = -1;
    if (!_bracket_mode) return;
    _rebuild_line_starts();
    if (incremental) {
        const auto &edit = *_snapshot->edit();
        const auto &ranges = _snapshot->changed_ranges();
        _brackets_after_edit(edit.start_point.row, edit.old_end_point.row, edit.new_end_point.row,
            ranges.data(), static_cast<uint32_t>(ranges.size()), _tree);
    } else {
        _brackets_full_scan();
    }
}
}
