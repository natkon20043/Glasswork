#pragma once

#include "TextBuffer.hpp"

#include <string>
#include <vector>

namespace gw {

/// A marked place found from comments in any line-comment style (//, #, --, ;) or one-line block comments:
///     // MARK: - Networking   (divider above)    // MARK: Helpers    #pragma mark - Drawing
///     // TODO: handle errors                      // FIXME: this leaks
struct Section {
    // Comment keyword -> which kind of section it marks.
    enum class Kind { Mark, Todo, Fixme };

    size_t line = 0;
    std::string title;
    Kind kind = Kind::Mark;
    /// "MARK: -" and "#pragma mark -" draw a divider above.
    bool divider = false;
};

// ---- Finding

std::vector<Section> findSections(const TextBuffer& buffer);

/// The last MARK at or above `line`, or -1.
long sectionContaining(const std::vector<Section>& sections, size_t line);

}  // namespace gw
