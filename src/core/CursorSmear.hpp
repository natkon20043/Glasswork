#pragma once

#include <vector>

namespace gw {

struct SmearRect {
    double x = 0;
    double y = 0;
    double width = 0;
    double height = 0;
};

struct SmearPoint {
    double x = 0;
    double y = 0;
};

/// How strong the smear is `at` a share of the way along its fade (0 to 1).
struct SmearFade {
    double at = 0;
    double opacity = 0;
};

/// One frame of the smear: a convex outline filled with a fade from `fadeStart` to `fadeEnd`.
struct SmearShape {
    std::vector<SmearPoint> outline;
    SmearPoint fadeStart;
    SmearPoint fadeEnd;
    std::vector<SmearFade> fades;
    SmearRect head;
};

/// The Vim cursor's smear, after smear-cursor.nvim: each corner springs toward the target, the near
/// corners hardest, so the cursor stretches into a trail and shrinks back. While a key is held the
/// corners chase a guide that slides on at a steady speed, so the cursor never stops on a character.
/// Positions are in points.
class SpringSmear {
public:
    // ---- Setters
    void setCharWidth(double charWidth) { charWidth_ = charWidth; }

    // ---- Moving
    /// Puts the cursor at `place` at once, with no smear.
    void jump(const SmearRect& place);
    /// `now` is in seconds, from any steady clock.
    void moveTo(const SmearRect& target, double now);
    /// Returns whether the smear is still going.
    bool advance(double seconds);
    void stop();

    // ---- Getters
    bool active() const { return active_; }
    bool holding() const { return holding_; }
    bool guiding() const { return guiding_; }
    const SmearRect& target() const { return target_; }
    SmearShape shape() const;

    // ---- Constants
    /// Pull per 1/60 s frame, from 0 (none) to 1 (straight there).
    static constexpr double kHeadStiffness = 0.6;
    static constexpr double kTailStiffness = 0.45;
    static constexpr double kTrailingExponent = 3;
    static constexpr double kDamping = 0.85;
    static constexpr double kAnticipation = 0.2;
    static constexpr double kBaseFrame = 1.0 / 60;
    /// In characters.
    static constexpr double kStopDistance = 0.1;
    static constexpr double kMostLength = 25;
    static constexpr double kGlowLength = 1;
    static constexpr double kVolumeReduction = 0.3;
    static constexpr double kLeastWidth = 0.7;

    static constexpr double kHeldKeyGap = 0.1;
    /// The guide takes this many repeat gaps to reach each character, so it never arrives first.
    static constexpr double kGuideStretch = 1.25;
    /// Held-key pulls at the macOS default repeat; faster repeats scale them up.
    static constexpr double kReferenceGap = 0.083;
    static constexpr double kHeldHeadStiffness = 0.5;
    static constexpr double kHeldTailStiffness = 0.12;
    static constexpr double kMostStiffness = 0.9;

    /// Shares of the cursor's strength; 0.58 is Konsole's faint block, measured from a recording.
    static constexpr double kTailOpacity = 0.15;
    static constexpr double kGlowOpacity = 0.58;

private:
    // ---- Private functions
    void setStiffnesses();

    // ---- Private variables
    bool active_ = false;
    double charWidth_ = 8;
    SmearRect target_;
    SmearPoint corners_[4];
    SmearPoint targets_[4];
    SmearPoint speeds_[4];
    double stiffnesses_[4] = {};
    double lastMove_ = -1e9;
    bool holding_ = false;
    double typicalGap_ = 0;
    SmearRect guide_;
    SmearRect guideFrom_;
    bool guiding_ = false;
    double guideTime_ = 0;
    double guideLength_ = 0;
    SmearPoint direction_;
};

/// A move of at least half a character or line (caret x is rounded, so a step can be a pixel short).
constexpr double kStepMinCells = 0.5;

bool isRealMove(const SmearRect& from, const SmearRect& to, double charWidth, double lineHeight);

}  // namespace gw
