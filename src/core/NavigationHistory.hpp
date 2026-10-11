#pragma once

#include "TextBuffer.hpp"

#include <optional>
#include <string>
#include <vector>

namespace gw {

struct NavigationLocation {
    std::string path;
    Position position;
};

/// Places you jumped away from, so Go Back returns to them and Go Forward undoes that.
class NavigationHistory {
public:
    // ---- Recording
    /// Call with the caret's place just before a jump. A new jump drops the Forward list; the same
    /// line as the last entry isn't recorded twice.
    void record(const NavigationLocation& from);

    // ---- Moving
    /// `current` becomes the opposite target. Empty when there is nowhere to go.
    std::optional<NavigationLocation> back(const NavigationLocation& current);
    std::optional<NavigationLocation> forward(const NavigationLocation& current);

    // ---- Getters
    bool canGoBack() const { return !backStack_.empty(); }
    bool canGoForward() const { return !forwardStack_.empty(); }

    // ---- Constants
    /// Oldest places are dropped first.
    static constexpr size_t kLimit = 100;

private:
    // ---- Private variables
    std::vector<NavigationLocation> backStack_;
    std::vector<NavigationLocation> forwardStack_;
};

}  // namespace gw
