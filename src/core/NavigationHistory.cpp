#include "NavigationHistory.hpp"

namespace gw {

namespace {

bool sameLine(const NavigationLocation& a, const NavigationLocation& b) {
    return a.path == b.path && a.position.line == b.position.line;
}

void pushLimited(std::vector<NavigationLocation>& stack, const NavigationLocation& location) {
    if (!stack.empty() && sameLine(stack.back(), location)) {
        stack.back() = location;
        return;
    }
    stack.push_back(location);
    if (stack.size() > NavigationHistory::kLimit) {
        stack.erase(stack.begin());
    }
}

}  // namespace

void NavigationHistory::record(const NavigationLocation& from) {
    forwardStack_.clear();
    pushLimited(backStack_, from);
}

std::optional<NavigationLocation> NavigationHistory::back(const NavigationLocation& current) {
    // Places on the very line we are on are not worth going back to.
    while (!backStack_.empty() && sameLine(backStack_.back(), current)) {
        backStack_.pop_back();
    }
    if (backStack_.empty()) {
        return std::nullopt;
    }
    NavigationLocation target = backStack_.back();
    backStack_.pop_back();
    pushLimited(forwardStack_, current);
    return target;
}

std::optional<NavigationLocation> NavigationHistory::forward(const NavigationLocation& current) {
    while (!forwardStack_.empty() && sameLine(forwardStack_.back(), current)) {
        forwardStack_.pop_back();
    }
    if (forwardStack_.empty()) {
        return std::nullopt;
    }
    NavigationLocation target = forwardStack_.back();
    forwardStack_.pop_back();
    pushLimited(backStack_, current);
    return target;
}

}  // namespace gw
