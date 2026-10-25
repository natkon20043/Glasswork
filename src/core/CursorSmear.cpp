#include "CursorSmear.hpp"

#include <algorithm>
#include <cmath>

namespace gw {

namespace {

/// The four corners of `rect`: top-left, top-right, bottom-right, bottom-left.
void cornersOf(const SmearRect& rect, SmearPoint (&corners)[4]) {
    corners[0] = {rect.x, rect.y};
    corners[1] = {rect.x + rect.width, rect.y};
    corners[2] = {rect.x + rect.width, rect.y + rect.height};
    corners[3] = {rect.x, rect.y + rect.height};
}

SmearPoint centerOf(const SmearPoint (&corners)[4]) {
    SmearPoint center;
    for (const SmearPoint& corner : corners) {
        center.x += corner.x / 4;
        center.y += corner.y / 4;
    }
    return center;
}

SmearPoint centerOf(const SmearRect& rect) {
    return {rect.x + rect.width / 2, rect.y + rect.height / 2};
}

SmearRect between(const SmearRect& from, const SmearRect& to, double amount) {
    return {from.x + (to.x - from.x) * amount, from.y + (to.y - from.y) * amount, to.width, to.height};
}

double distanceBetween(const SmearPoint& a, const SmearPoint& b) {
    return std::hypot(a.x - b.x, a.y - b.y);
}

double along(const SmearPoint& point, const SmearPoint& direction) {
    return point.x * direction.x + point.y * direction.y;
}

/// The area inside the four corners, by the shoelace formula.
double areaOf(const SmearPoint (&corners)[4]) {
    double twice = 0;
    for (int index = 0; index < 4; ++index) {
        const SmearPoint& here = corners[index];
        const SmearPoint& next = corners[(index + 1) % 4];
        twice += here.x * next.y - next.x * here.y;
    }
    return std::fabs(twice) / 2;
}

/// The corner nearest its own place at the target: the one leading the way.
int leadingCorner(const SmearPoint (&corners)[4], const SmearPoint (&targets)[4]) {
    int leading = 0;
    double nearest = INFINITY;
    for (int index = 0; index < 4; ++index) {
        double distance = distanceBetween(corners[index], targets[index]);
        if (distance < nearest) {
            nearest = distance;
            leading = index;
        }
    }
    return leading;
}

/// The smallest convex shape holding all of `points`, its corners in order around it.
std::vector<SmearPoint> convexHull(std::vector<SmearPoint> points) {
    std::sort(points.begin(), points.end(), [](const SmearPoint& a, const SmearPoint& b) {
        return a.x < b.x || (a.x == b.x && a.y < b.y);
    });
    auto turn = [](const SmearPoint& a, const SmearPoint& b, const SmearPoint& c) {
        return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
    };
    std::vector<SmearPoint> hull;
    // The lower side, left to right, then the upper side, right to left.
    for (int pass = 0; pass < 2; ++pass) {
        size_t start = hull.size();
        for (const SmearPoint& point : points) {
            while (hull.size() >= start + 2 && turn(hull[hull.size() - 2], hull.back(), point) <= 1e-9) {
                hull.pop_back();
            }
            hull.push_back(point);
        }
        hull.pop_back();  // it starts the other side
        std::reverse(points.begin(), points.end());
    }
    return hull;
}

}  // namespace

bool isRealMove(const SmearRect& from, const SmearRect& to, double charWidth, double lineHeight) {
    double cellsAcross = std::fabs(to.x - from.x) / charWidth;
    double cellsDown = std::fabs(to.y - from.y) / lineHeight;
    return std::max(cellsAcross, cellsDown) >= kStepMinCells - 1e-9;
}

void SpringSmear::jump(const SmearRect& place) {
    target_ = place;
    guide_ = place;
    guiding_ = false;
    cornersOf(place, corners_);
    cornersOf(place, targets_);
    for (SmearPoint& speed : speeds_) {
        speed = {};
    }
    active_ = false;
}

void SpringSmear::stop() {
    jump(target_);
}

void SpringSmear::moveTo(const SmearRect& target, double now) {
    double gap = now - lastMove_;
    bool wasHeld = holding_;
    lastMove_ = now;
    holding_ = gap >= 0 && gap < kHeldKeyGap;

    SmearPoint from = centerOf(corners_);
    SmearPoint to = centerOf(target);
    double distance = distanceBetween(from, to);
    if (distance > 1e-9) {
        direction_ = {(to.x - from.x) / distance, (to.y - from.y) / distance};
    }

    target_ = target;
    if (holding_) {
        // Repeats are not perfectly even; averaging the recent gaps keeps one late or early repeat
        // from changing the guide's speed.
        typicalGap_ = wasHeld ? (typicalGap_ + gap) / 2 : gap;
        guideFrom_ = guide_;
        guideTime_ = 0;
        guideLength_ = kGuideStretch * typicalGap_;
        guiding_ = true;
    } else {
        guide_ = target;
        guiding_ = false;
    }
    cornersOf(guide_, targets_);
    setStiffnesses();
    if (!active_) {
        // From rest, the cursor first pulls back a little before it goes.
        for (int index = 0; index < 4; ++index) {
            speeds_[index].x = (corners_[index].x - targets_[index].x) * kAnticipation;
            speeds_[index].y = (corners_[index].y - targets_[index].y) * kAnticipation;
        }
    }
    active_ = true;
}

void SpringSmear::setStiffnesses() {
    double headStiffness = kHeadStiffness;
    double tailStiffness = kTailStiffness;
    if (holding_) {
        double faster = kReferenceGap / std::max(typicalGap_, 1e-3);
        headStiffness = std::min(kMostStiffness, kHeldHeadStiffness * faster);
        tailStiffness = std::min(kMostStiffness, kHeldTailStiffness * faster);
    }
    // The nearer a corner is to the middle of the target, the harder it is pulled.
    SmearPoint targetCenter = centerOf(target_);
    double distances[4];
    double nearest = INFINITY;
    double farthest = 0;
    for (int index = 0; index < 4; ++index) {
        distances[index] = distanceBetween(corners_[index], targetCenter);
        nearest = std::min(nearest, distances[index]);
        farthest = std::max(farthest, distances[index]);
    }
    for (int index = 0; index < 4; ++index) {
        if (farthest == nearest) {
            stiffnesses_[index] = headStiffness;
            continue;
        }
        double share = (distances[index] - nearest) / (farthest - nearest);
        double stiffness = headStiffness + (tailStiffness - headStiffness) * std::pow(share, kTrailingExponent);
        stiffnesses_[index] = std::min(1.0, stiffness);
    }
}

bool SpringSmear::advance(double seconds) {
    if (!active_) {
        return false;
    }
    // A frame that came very late (the app was busy) moves the springs on as if a few frames had
    // passed, not all of them, so the cursor does not leap.
    double elapsed = std::clamp(seconds, 0.0, 0.1);
    double frames = elapsed / kBaseFrame;

    if (guiding_) {
        guideTime_ += elapsed;
        double share = std::min(1.0, guideTime_ / guideLength_);
        guide_ = between(guideFrom_, target_, share);
        guiding_ = share < 1;
        cornersOf(guide_, targets_);
    }

    double keptSpeed = std::pow(1 - kDamping, frames);
    // The plugin's correction, which keeps the time a smear takes about the same whatever the damping.
    double dampingCorrection = 1 / (1 + 2.5 * keptSpeed);

    for (int index = 0; index < 4; ++index) {
        double pull = 1 - std::pow(1 - stiffnesses_[index] * dampingCorrection, frames);
        SmearPoint& corner = corners_[index];
        SmearPoint& speed = speeds_[index];
        speed.x += (targets_[index].x - corner.x) * pull;
        speed.y += (targets_[index].y - corner.y) * pull;
        corner.x += speed.x;
        corner.y += speed.y;
        speed.x *= keptSpeed;
        speed.y *= keptSpeed;
    }

    // Too long a smear is pulled in toward its leading corner.
    int leading = leadingCorner(corners_, targets_);
    double length = 0;
    for (int index = 0; index < 4; ++index) {
        length = std::max(length, distanceBetween(corners_[index], corners_[leading]));
    }
    double mostLength = kMostLength * charWidth_;
    if (length > mostLength) {
        double share = mostLength / length;
        for (int index = 0; index < 4; ++index) {
            corners_[index].x = corners_[leading].x + (corners_[index].x - corners_[leading].x) * share;
            corners_[index].y = corners_[leading].y + (corners_[index].y - corners_[leading].y) * share;
        }
    }

    double farthest = 0;
    double fastest = 0;
    for (int index = 0; index < 4; ++index) {
        farthest = std::max(farthest, distanceBetween(corners_[index], targets_[index]));
        fastest = std::max(fastest, std::hypot(speeds_[index].x, speeds_[index].y));
    }
    double close = kStopDistance * charWidth_;
    if (!guiding_ && farthest <= close && fastest <= close) {
        stop();
        return false;
    }
    return true;
}

SmearShape SpringSmear::shape() const {
    SmearShape shape;

    // The solid cursor rides on the leading corner.
    int leading = leadingCorner(corners_, targets_);
    shape.head = guide_;
    shape.head.x += corners_[leading].x - targets_[leading].x;
    shape.head.y += corners_[leading].y - targets_[leading].y;

    // The trail: a slanted smear is thinned across the way each corner goes. A straight one (along a
    // line, or straight up or down) keeps the cursor's own width.
    SmearPoint trail[4];
    for (int index = 0; index < 4; ++index) {
        trail[index] = corners_[index];
    }
    SmearPoint center = centerOf(corners_);
    SmearPoint targetCenter = centerOf(targets_);
    bool straight = std::fabs(targetCenter.y - center.y) < target_.height / 8 ||
                    std::fabs(targetCenter.x - center.x) < charWidth_ / 8;
    double cells = areaOf(corners_) / (charWidth_ * target_.height);
    if (!straight && cells > 1) {
        double width = std::max(kLeastWidth, std::pow(1 / cells, kVolumeReduction / 2));
        for (int index = 0; index < 4; ++index) {
            SmearPoint toTarget = {targets_[index].x - corners_[index].x, targets_[index].y - corners_[index].y};
            double length = std::hypot(toTarget.x, toTarget.y);
            if (length == 0) {
                continue;
            }
            SmearPoint across = {-toTarget.y / length, toTarget.x / length};
            double outward = (corners_[index].x - center.x) * across.x + (corners_[index].y - center.y) * across.y;
            double shift = outward * (1 - width);
            trail[index].x -= across.x * shift;
            trail[index].y -= across.y * shift;
        }
    }

    SmearPoint head[4];
    cornersOf(shape.head, head);
    SmearPoint ahead[4];
    cornersOf(target_, ahead);
    double headBack = INFINITY, headFront = -INFINITY, targetFront = -INFINITY;
    for (int index = 0; index < 4; ++index) {
        headBack = std::min(headBack, along(head[index], direction_));
        headFront = std::max(headFront, along(head[index], direction_));
        targetFront = std::max(targetFront, along(ahead[index], direction_));
    }

    // The glow ahead reaches toward the far side of the target, a character at most.
    double cell = std::fabs(direction_.x) * charWidth_ + std::fabs(direction_.y) * target_.height;
    double glow = std::clamp(targetFront - headFront, 0.0, kGlowLength * cell);

    std::vector<SmearPoint> points(trail, trail + 4);
    for (const SmearPoint& corner : head) {
        points.push_back(corner);
        if (glow > 0) {
            points.push_back({corner.x + direction_.x * glow, corner.y + direction_.y * glow});
        }
    }
    shape.outline = convexHull(points);

    // The fade runs along the way the cursor goes: faint at the very end of the trail, the cursor's
    // full strength across the solid block, and faint again at the far end of the glow.
    double start = INFINITY, end = -INFINITY;
    for (const SmearPoint& corner : shape.outline) {
        start = std::min(start, along(corner, direction_));
        end = std::max(end, along(corner, direction_));
    }
    SmearPoint middle = centerOf(shape.head);
    double here = along(middle, direction_);
    shape.fadeStart = {middle.x + direction_.x * (start - here), middle.y + direction_.y * (start - here)};
    shape.fadeEnd = {middle.x + direction_.x * (end - here), middle.y + direction_.y * (end - here)};
    double span = end - start;
    if (span < 1e-6 || (direction_.x == 0 && direction_.y == 0)) {
        shape.fades = {{0, 1}, {1, 1}};
        return shape;
    }
    // A short trail or glow is only a little faint at its end, so they come and go smoothly.
    auto at = [&](double position) { return std::clamp((position - start) / span, 0.0, 1.0); };
    auto faintest = [&](double length, double opacity) { return 1 - (1 - opacity) * std::min(1.0, length / cell); };
    shape.fades.push_back({0, faintest(headBack - start, kTailOpacity)});
    shape.fades.push_back({at(headBack), 1});
    shape.fades.push_back({at(headFront), 1});
    shape.fades.push_back({1, faintest(glow, kGlowOpacity)});
    return shape;
}

}  // namespace gw
