#pragma once

#include <algorithm>

// Vertical layout of the creature information block (name above a stack of bar rows) when it is
// drawn above the creature's head instead of over the sprite. All values are in the coordinate
// space of the creature information draw pool, i.e. already divided by the information scale.
struct CreatureInformationAboveHead
{
    static constexpr int ROW_HEIGHT = 4;
    // each row starts on the previous row's bottom line (Rect::bottom() is inclusive)
    static constexpr int ROW_STRIDE = ROW_HEIGHT - 1;
    static constexpr int NAME_BAR_SPACING = 2;
    static constexpr int HEAD_GAP = 1;

    static constexpr int stackHeight(const int rows) { return rows > 0 ? ROW_HEIGHT + (rows - 1) * ROW_STRIDE : 0; }

    int textTop;
    int barsTop;

    // anchorY is the creature top the default layout hangs the bars from, headLift how much
    // higher the head is considered to be, and boundTop the map top: a block that would cross it
    // is pushed down rather than clipped.
    static constexpr CreatureInformationAboveHead compute(const int anchorY, const int headLift, const int nameHeight, const int barRows, const int boundTop)
    {
        const int bottom = anchorY - std::max(0, headLift) - HEAD_GAP;
        const int barsTop = bottom - stackHeight(barRows);
        const int textTop = (barRows > 0 ? barsTop - NAME_BAR_SPACING : bottom) - nameHeight;
        const int push = std::max(0, boundTop - textTop);
        return { textTop + push, barsTop + push };
    }
};
