#pragma once
#include "core/document.hpp"
#include <optional>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>

namespace godot {
// A projection of the service's document. It never owns a separate parser.
class GDScriptLSPDocument : public RefCounted {
    GDCLASS(GDScriptLSPDocument, RefCounted)
public:
    void set_snapshot(std::shared_ptr<const gdscript_lsp::Document> snapshot,
        std::optional<int64_t> revision = {});
    const auto &snapshot() const { return _snapshot; }
    int64_t get_revision() const { return _revision; }
    String get_source_code() const;
    String get_source_hash();
    Dictionary parse_script(const String &script_path);
    Dictionary sparse_parse();
    void set_bracket_mode(bool enabled);
    bool get_bracket_mode() const;
    Dictionary get_brackets() const;
    void clear_brackets();
protected:
    static void _bind_methods();
private:
    std::shared_ptr<const gdscript_lsp::Document> _snapshot;
    int64_t _revision = -1;
    const TSTree *_tree = nullptr;
    uint32_t _src_len = 0;
    int64_t _full_revision = -1, _sparse_revision = -1;
    String _full_path, _source_hash;
    Dictionary _full_cache, _sparse_cache;
    struct BracketLine {
        std::vector<std::pair<int32_t, int32_t>> entries;
        int32_t end_depth = 0;
    };
    bool _bracket_mode = false;
    std::vector<BracketLine> _bracket_lines;
    std::vector<uint32_t> _line_starts;
    Dictionary _brackets_dict;
    void _rebuild_line_starts();
    void _scan_brackets(TSNode scope, int32_t depth, uint32_t from, uint32_t to);
    void _brackets_full_scan();
    void _brackets_after_edit(uint32_t start, uint32_t old_end, uint32_t new_end,
        const TSRange *ranges, uint32_t count, const TSTree *tree);
};
}
