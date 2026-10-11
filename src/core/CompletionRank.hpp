#pragma once

#include <cstddef>
#include <deque>
#include <string>
#include <string_view>
#include <vector>

namespace gw {

struct CompletionCandidate {
    std::string label;
    /// What typed letters are matched against (the label unless the server says otherwise).
    std::string filterText;
    std::string sortText;
    /// LSP CompletionItemKind.
    int kind = 0;
    bool deprecated = false;
    /// The server's pick for "most likely" when nothing is typed yet.
    bool preselect = false;
};

/// Recently accepted names, so a name used all the time floats up without drowning better matches.
class CompletionHistory {
public:
    // ---- Constructors
    explicit CompletionHistory(size_t capacity = 64) : capacity_(capacity) {}

    // ---- Recording and querying
    void accepted(const std::string& label, int kind);
    /// 0 if never accepted, up to `maximumBoost` for the most recent.
    int boost(const std::string& label, int kind) const;

    // ---- Constants
    static constexpr int maximumBoost = 30;

private:
    struct Entry {
        std::string label;
        int kind;
    };

    // ---- Private variables
    size_t capacity_;
    // Newest first.
    std::deque<Entry> recent_;
};

/// Indices into `candidates`, best first, of those matching `query` (all when empty), at most `limit`.
/// Fuzzy, case-insensitive. Higher: prefix matches (exact case first), word-start/camelCase hits,
/// consecutive runs, recently accepted. Lower: deprecated. Ties: server sortText, shorter, server order.
/// With no query the server's preselected item leads, then recently used ones.
std::vector<size_t> rankCompletions(std::string_view query,
                                    const std::vector<CompletionCandidate>& candidates,
                                    const CompletionHistory& history,
                                    size_t limit = 200);

}  // namespace gw
