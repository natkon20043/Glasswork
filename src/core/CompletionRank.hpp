#pragma once

#include <cstddef>
#include <deque>
#include <string>
#include <string_view>
#include <vector>

namespace gw {

/// What ranking needs to know about one suggestion from a language server.
struct CompletionCandidate {
    std::string label;
    /// What the typed letters are matched against (the label, unless the server says otherwise).
    std::string filterText;
    /// The server's own ordering key.
    std::string sortText;
    int kind = 0;  // LSP CompletionItemKind
    bool deprecated = false;
    /// The server's pick for "most likely" when nothing has been typed yet.
    bool preselect = false;
};

/// Remembers what was accepted lately, so a name you use all the time floats to the top
/// ("recently used") without drowning better matches.
class CompletionHistory {
public:
    explicit CompletionHistory(size_t capacity = 64) : capacity_(capacity) {}

    /// Notes that `label` (of this kind) was just accepted.
    void accepted(const std::string& label, int kind);
    /// 0 for something never accepted; up to `maximumBoost` for the most recent.
    int boost(const std::string& label, int kind) const;

    static constexpr int maximumBoost = 30;

private:
    struct Entry {
        std::string label;
        int kind;
    };
    size_t capacity_;
    std::deque<Entry> recent_;  // newest first
};

/// Indices into `candidates`, best first, of the ones that match `query` (everything when the
/// query is empty). Matching is fuzzy and ignores case ("gw" finds "glassWork"), and ranks:
///   * names that start with the query, exact case first, ahead of scattered matches;
///   * matches on word starts and camelCase humps, and consecutive runs, higher;
///   * recently accepted names a little higher;
///   * deprecated names lower.
/// Ties fall back to the server's sort text, then shorter names, then the server's order.
/// With no query, the server's preselected item comes first, then recently used ones.
/// At most `limit` indices are returned.
std::vector<size_t> rankCompletions(std::string_view query,
                                    const std::vector<CompletionCandidate>& candidates,
                                    const CompletionHistory& history,
                                    size_t limit = 200);

}  // namespace gw
