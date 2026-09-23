#pragma once

#include <algorithm>

struct ViewportMetrics
{
    int safeLeft{ 0 };
    int safeTop{ 0 };
    int safeRight{ 0 };
    int safeBottom{ 0 };
    int keyboardHeight{ 0 };
    int viewportWidth{ 0 };
    int viewportHeight{ 0 };

    void normalize()
    {
        safeLeft = std::max(0, safeLeft);
        safeTop = std::max(0, safeTop);
        safeRight = std::max(0, safeRight);
        safeBottom = std::max(0, safeBottom);
        keyboardHeight = std::max(0, keyboardHeight);
        viewportWidth = std::max(0, viewportWidth);
        viewportHeight = std::max(0, viewportHeight);
    }

    bool operator==(const ViewportMetrics&) const = default;
};
