#pragma once

#include "TextBuffer.hpp"

#include <optional>
#include <string>
#include <vector>

namespace gw {

/// A place in a file the caret was at.
struct NavigationLocation {
    std::string path;
    Position position;
};

/// The places you jumped away from (go to definition, go to line, a search result...), so
/// Go Back returns to them and Go Forward undoes that, like a browser's back button.
class NavigationHistory {
public:
    /// Call with the caret's place just before a jump. A new jump drops the Forward list.
    /// Stays on the same line as the last entry are not recorded twice.
    void record(const NavigationLocation& from);

    /// The place to go back to, given where the caret is now (which becomes the Forward
    /// target). Empty when there is nowhere to go.
    std::optional<NavigationLocation> back(const NavigationLocation& current);
    std::optional<NavigationLocation> forward(const NavigationLocation& current);

    bool canGoBack() const { return !backStack_.empty(); }
    bool canGoForward() const { return !forwardStack_.empty(); }

    /// Most places remembered; the oldest are dropped first.
    static constexpr size_t kLimit = 100;

private:
    std::vector<NavigationLocation> backStack_;
    std::vector<NavigationLocation> forwardStack_;
};

}  // namespace gw
