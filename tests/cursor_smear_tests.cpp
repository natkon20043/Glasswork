// Tests for how the Vim cursor smears: its corners spring toward the target (or, while a key is held,
// toward a guide sliding there), and the one shape drawn from them, fading from the trail through the
// solid cursor into the glow ahead.

#include "TestHarness.hpp"

#include "CursorSmear.hpp"

#include <algorithm>
#include <cmath>
#include <initializer_list>

namespace {

constexpr double kCharWidth = 8;
constexpr double kLineHeight = 16;

const gw::SmearRect kBlock = {100, 100, kCharWidth, kLineHeight};

gw::SmearRect movedBy(const gw::SmearRect& rect, double across, double down) {
    return {rect.x + across, rect.y + down, rect.width, rect.height};
}

gw::SpringSmear smearAt(const gw::SmearRect& place) {
    gw::SpringSmear smear;
    smear.setCharWidth(kCharWidth);
    smear.jump(place);
    return smear;
}

/// Runs the smear to its end at `rate` frames a second, and returns how long that took.
double runToEnd(gw::SpringSmear& smear, double rate) {
    double time = 0;
    while (smear.advance(1 / rate) && time < 5) {
        time += 1 / rate;
    }
    return time;
}

/// How wide the whole smear is, left to right, in characters.
double smearWidth(const gw::SmearShape& shape) {
    double left = INFINITY, right = -INFINITY;
    for (const gw::SmearPoint& corner : shape.outline) {
        left = std::min(left, corner.x);
        right = std::max(right, corner.x);
    }
    return (right - left) / kCharWidth;
}

/// How far the smear reaches behind the solid cursor's left edge, in characters.
double trailBehind(const gw::SmearShape& shape) {
    double left = INFINITY;
    for (const gw::SmearPoint& corner : shape.outline) {
        left = std::min(left, corner.x);
    }
    return (shape.head.x - left) / kCharWidth;
}

double outlineArea(const gw::SmearShape& shape) {
    double area = 0;
    size_t count = shape.outline.size();
    for (size_t index = 0; index < count; ++index) {
        const gw::SmearPoint& here = shape.outline[index];
        const gw::SmearPoint& next = shape.outline[(index + 1) % count];
        area += (here.x * next.y - next.x * here.y) / 2;
    }
    return std::fabs(area);
}

/// Whether the smear is just the cursor's block at `place`, at full strength all over.
bool isJustTheBlock(const gw::SmearShape& shape, const gw::SmearRect& place) {
    bool fullStrength = true;
    for (const gw::SmearFade& fade : shape.fades) {
        fullStrength = fullStrength && fade.opacity == 1;
    }
    return fullStrength && shape.head.x == place.x && shape.head.y == place.y &&
           std::fabs(outlineArea(shape) - place.width * place.height) < 1e-6;
}

// ---- Which moves smear

TEST(onlyMovesOfACharacterOrMoreAreRealMoves) {
    auto real = [](double across, double down) {
        return gw::isRealMove(kBlock, movedBy(kBlock, across, down), kCharWidth, kLineHeight);
    };
    CHECK(real(kCharWidth, 0));
    CHECK(real(-kCharWidth, 0));
    CHECK(real(0, kLineHeight));
    CHECK(real(0, -kLineHeight));
    CHECK(real(10 * kCharWidth, 0));
    CHECK(real(0, 40 * kLineHeight));
    CHECK(!real(1, 0));  // block to bar over the same character: a pixel's difference
    CHECK(!real(0, 1));
}

TEST(aCharactersStepIsAlwaysARealMoveEvenWhenRoundingMakesItAPixelShort) {
    // A character is 8.5 points wide but the caret sits on whole pixels, so its steps alternate 9, 8, 9, 8.
    const double width = 8.5;
    for (double step : {8.0, 9.0}) {
        gw::SmearRect from = {100, 100, width, kLineHeight};
        gw::SmearRect to = {100 + step, 100, width, kLineHeight};
        CHECK(gw::isRealMove(from, to, width, kLineHeight));
    }
}

// ---- A move on its own

TEST(atRestTheCursorIsJustTheBlock) {
    gw::SpringSmear smear = smearAt(kBlock);
    CHECK(!smear.active());
    CHECK(!smear.advance(1.0 / 60));
    CHECK(isJustTheBlock(smear.shape(), kBlock));
}

TEST(aMoveGoesQuicklyAndEndsExactlyAtTheTarget) {
    gw::SpringSmear smear = smearAt(kBlock);
    gw::SmearRect to = movedBy(kBlock, kCharWidth, 0);
    smear.moveTo(to, 10.0);
    CHECK(smear.active());
    CHECK(!smear.holding());
    double time = runToEnd(smear, 60);
    CHECK(time > 0.04);
    CHECK(time < 0.15);
    CHECK(!smear.active());
    CHECK(isJustTheBlock(smear.shape(), to));  // the smear has shrunk back into the cursor
}

TEST(aLongMoveTakesLongerButIsNeverSlow) {
    gw::SpringSmear near = smearAt(kBlock), far = smearAt(kBlock);
    near.moveTo(movedBy(kBlock, kCharWidth, 0), 10.0);
    far.moveTo(movedBy(kBlock, 200 * kCharWidth, 0), 10.0);
    double nearTime = runToEnd(near, 60);
    double farTime = runToEnd(far, 60);
    CHECK(farTime > nearTime);
    CHECK(farTime < 0.35);
}

TEST(theMotionIsTheSameAtAnyRefreshRate) {
    for (double cells : {1.0, 40.0}) {
        gw::SpringSmear at60 = smearAt(kBlock), at120 = smearAt(kBlock);
        at60.moveTo(movedBy(kBlock, cells * kCharWidth, 0), 10.0);
        at120.moveTo(movedBy(kBlock, cells * kCharWidth, 0), 10.0);
        double time60 = runToEnd(at60, 60);
        double time120 = runToEnd(at120, 120);
        CHECK(std::fabs(time60 - time120) < 0.025);
    }
}

TEST(theLeadingCornersGoFirstSoTheCursorStretchesIntoASmear) {
    gw::SpringSmear smear = smearAt(kBlock);
    smear.moveTo(movedBy(kBlock, 10 * kCharWidth, 0), 10.0);
    double longest = 0;
    for (int frame = 0; frame < 8; ++frame) {
        smear.advance(1.0 / 60);
        gw::SmearShape shape = smear.shape();
        longest = std::max(longest, trailBehind(shape));
        // Going straight across, the smear stays one line tall.
        for (const gw::SmearPoint& corner : shape.outline) {
            CHECK(corner.y >= kBlock.y - 1e-9);
            CHECK(corner.y <= kBlock.y + kLineHeight + 1e-9);
        }
    }
    CHECK(longest > 1);
}

TEST(theSmearFadesFromTheTrailThroughTheCursorIntoTheGlowAhead) {
    gw::SpringSmear smear = smearAt(kBlock);
    smear.moveTo(movedBy(kBlock, 10 * kCharWidth, 0), 10.0);
    for (int frame = 0; frame < 3; ++frame) {
        smear.advance(1.0 / 60);
    }
    gw::SmearShape shape = smear.shape();
    // It fades left to right, the way the cursor goes, all along the smear.
    CHECK(shape.fadeEnd.x > shape.fadeStart.x);
    CHECK(std::fabs(shape.fadeEnd.y - shape.fadeStart.y) < 1e-9);
    double left = INFINITY, right = -INFINITY;
    for (const gw::SmearPoint& corner : shape.outline) {
        left = std::min(left, corner.x);
        right = std::max(right, corner.x);
    }
    CHECK(std::fabs(shape.fadeStart.x - left) < 1e-9);
    CHECK(std::fabs(shape.fadeEnd.x - right) < 1e-9);
    // Faint at the very end of the trail, the cursor's full strength across the solid block, and as
    // faint as Konsole's block ahead at the far end of the glow, a character ahead of the cursor.
    CHECK_EQ(shape.fades.size(), size_t(4));
    CHECK(std::fabs(shape.fades[0].opacity - gw::SpringSmear::kTailOpacity) < 1e-9);
    CHECK_EQ(shape.fades[1].opacity, 1.0);
    CHECK_EQ(shape.fades[2].opacity, 1.0);
    CHECK(std::fabs(shape.fades[3].opacity - 0.58) < 1e-9);
    CHECK(std::fabs(right - (shape.head.x + 2 * kCharWidth)) < 1e-9);
    // In order along the smear, and the solid part is exactly the cursor.
    for (size_t index = 1; index < shape.fades.size(); ++index) {
        CHECK(shape.fades[index].at >= shape.fades[index - 1].at);
    }
    double span = right - left;
    CHECK(std::fabs(left + shape.fades[1].at * span - shape.head.x) < 1e-6);
    CHECK(std::fabs(left + shape.fades[2].at * span - (shape.head.x + kCharWidth)) < 1e-6);
}

TEST(aShortTrailOrGlowIsOnlyALittleFaintSoTheyComeAndGoSmoothly) {
    gw::SpringSmear smear = smearAt(kBlock);
    smear.moveTo(movedBy(kBlock, kCharWidth, 0), 10.0);
    double lastGlowEnd = 0;
    while (smear.advance(1.0 / 120)) {
        gw::SmearShape shape = smear.shape();
        double glowEnd = shape.fades.back().opacity;
        CHECK(glowEnd >= 0.58 - 1e-9);
        CHECK(glowEnd <= 1);
        lastGlowEnd = glowEnd;
    }
    CHECK(lastGlowEnd > 0.9);  // nearly gone by the time the cursor lands
}

TEST(aSlantedSmearStaysARealSmear) {
    gw::SpringSmear slanted = smearAt(kBlock);
    slanted.moveTo(movedBy(kBlock, 30 * kCharWidth, 15 * kLineHeight), 10.0);
    for (int frame = 0; frame < 4; ++frame) {
        slanted.advance(1.0 / 60);
    }
    gw::SmearShape shape = slanted.shape();
    CHECK(shape.outline.size() >= 4);
    CHECK(outlineArea(shape) > kCharWidth * kLineHeight);
    // The fade runs down and to the right, the way the cursor goes.
    CHECK(shape.fadeEnd.x > shape.fadeStart.x);
    CHECK(shape.fadeEnd.y > shape.fadeStart.y);
}

TEST(goingStraightDownTheSmearKeepsTheCursorsWidth) {
    gw::SpringSmear smear = smearAt(kBlock);
    smear.moveTo(movedBy(kBlock, 0, 15 * kLineHeight), 10.0);
    for (int frame = 0; frame < 4; ++frame) {
        smear.advance(1.0 / 60);
    }
    gw::SmearShape shape = smear.shape();
    CHECK(std::fabs(smearWidth(shape) - 1) < 1e-9);
    CHECK(shape.fadeEnd.y > shape.fadeStart.y);
    CHECK(std::fabs(shape.fadeEnd.x - shape.fadeStart.x) < 1e-9);
}

TEST(aSmearIsNeverLongerThanTheMost) {
    gw::SpringSmear smear = smearAt(kBlock);
    smear.moveTo(movedBy(kBlock, 2000 * kCharWidth, 0), 10.0);
    for (int frame = 0; frame < 30 && smear.active(); ++frame) {
        smear.advance(1.0 / 60);
        CHECK(smearWidth(smear.shape()) <= gw::SpringSmear::kMostLength + 1 + gw::SpringSmear::kGlowLength + 1e-9);
    }
}

TEST(aVeryLateFrameDoesNotMakeTheCursorLeap) {
    gw::SpringSmear smear = smearAt(kBlock);
    smear.moveTo(movedBy(kBlock, 20 * kCharWidth, 0), 10.0);
    smear.advance(3.0);  // the app was busy for three seconds
    gw::SmearShape shape = smear.shape();
    CHECK(std::isfinite(shape.head.x));
    CHECK(shape.head.x <= kBlock.x + 20 * kCharWidth + kCharWidth);
}

TEST(aNewTargetMidMoveKeepsTheSpeedItHas) {
    gw::SpringSmear smear = smearAt(kBlock);
    smear.moveTo(movedBy(kBlock, 10 * kCharWidth, 0), 10.0);
    for (int frame = 0; frame < 3; ++frame) {
        smear.advance(1.0 / 60);
    }
    double before = smear.shape().head.x;
    smear.moveTo(movedBy(kBlock, 20 * kCharWidth, 0), 10.05);
    smear.advance(1.0 / 60);
    CHECK(smear.shape().head.x > before);  // no pulling back: it only does that from rest
}

// ---- A held key

TEST(aHeldKeyGlidesAtASteadySpeedAtAnyRepeatRate) {
    // From a very fast key repeat to the macOS default.
    for (double gap : {0.03, 0.05, 0.083}) {
        gw::SpringSmear smear = smearAt(kBlock);
        const double rate = 120;
        double x = kBlock.x;
        double time = 0, nextRepeat = 0;
        double lastHead = kBlock.x;
        double slowest = INFINITY, fastest = 0, longest = 0, mostBehind = 0;
        while (time < 1.5) {
            if (time >= nextRepeat - 1e-9) {
                x += kCharWidth;
                smear.moveTo({x, kBlock.y, kCharWidth, kLineHeight}, 10.0 + time);
                nextRepeat += gap;
            }
            smear.advance(1 / rate);
            time += 1 / rate;
            gw::SmearShape shape = smear.shape();
            if (time > 0.5) {  // once it has settled into the repeat
                CHECK(smear.holding());
                CHECK(smear.guiding());  // the guide never arrives before the next repeat
                double charactersPerRepeat = (shape.head.x - lastHead) * rate / kCharWidth * gap;
                slowest = std::min(slowest, charactersPerRepeat);
                fastest = std::max(fastest, charactersPerRepeat);
                longest = std::max(longest, trailBehind(shape));
                mostBehind = std::max(mostBehind, (x - shape.head.x) / kCharWidth);
            }
            lastHead = shape.head.x;
        }
        // The same speed as the key, frame after frame: it never stalls on a character. (At the
        // fastest repeats the frames and the repeats do not line up, so it wavers a little.)
        CHECK(slowest > 0.8);
        CHECK(fastest < 1.2);
        CHECK(longest > 1);         // it leaves a trail behind it,
        CHECK(longest < 2.5);       // but a short one,
        CHECK(mostBehind < 1.6);    // and is never far behind where the cursor really is
    }
}

TEST(lettingGoOfAHeldKeyEndsExactlyOnTheLastCharacter) {
    gw::SpringSmear smear = smearAt(kBlock);
    double x = kBlock.x;
    for (int repeat = 0; repeat < 20; ++repeat) {
        x += kCharWidth;
        smear.moveTo({x, kBlock.y, kCharWidth, kLineHeight}, 10.0 + repeat * 0.05);
        for (int frame = 0; frame < 6; ++frame) {
            smear.advance(0.05 / 6);
        }
    }
    double time = runToEnd(smear, 120);
    CHECK(time < 0.3);
    CHECK(isJustTheBlock(smear.shape(), {x, kBlock.y, kCharWidth, kLineHeight}));
}

TEST(aMoveAfterAPauseIsOnItsOwnAgain) {
    gw::SpringSmear smear = smearAt(kBlock);
    smear.moveTo(movedBy(kBlock, kCharWidth, 0), 10.0);
    smear.moveTo(movedBy(kBlock, 2 * kCharWidth, 0), 10.05);
    CHECK(smear.holding());
    smear.moveTo(movedBy(kBlock, 3 * kCharWidth, 0), 10.5);
    CHECK(!smear.holding());
    // A clock that seems to go backwards is not a held key either.
    smear.moveTo(movedBy(kBlock, 4 * kCharWidth, 0), 3.0);
    CHECK(!smear.holding());
}

}  // namespace

int main() {
    return harness::runAllTests();
}
