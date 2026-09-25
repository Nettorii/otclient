#include <gtest/gtest.h>

#include <client/creatureinformationlayout.h>

namespace {
constexpr int ROW = CreatureInformationAboveHead::ROW_HEIGHT;
constexpr int STRIDE = CreatureInformationAboveHead::ROW_STRIDE;
constexpr int GAP = CreatureInformationAboveHead::HEAD_GAP;
constexpr int SPACING = CreatureInformationAboveHead::NAME_BAR_SPACING;
constexpr int FAR_TOP = -100000;

int blockBottom(const CreatureInformationAboveHead& layout, int nameHeight, int barRows)
{
    return barRows > 0 ? layout.barsTop + CreatureInformationAboveHead::stackHeight(barRows) : layout.textTop + nameHeight;
}
}

TEST(CreatureInformationAboveHead, RowsShareTheirBorderLikeDrawInformation)
{
    // drawInformation steps rows with moveTop(bottom()), and Rect::bottom() is inclusive
    EXPECT_EQ(ROW, 4);
    EXPECT_EQ(STRIDE, 3);
    EXPECT_EQ(CreatureInformationAboveHead::stackHeight(0), 0);
    EXPECT_EQ(CreatureInformationAboveHead::stackHeight(1), 4);
    EXPECT_EQ(CreatureInformationAboveHead::stackHeight(5), 16);
}

TEST(CreatureInformationAboveHead, MonsterHealthBarSitsJustAboveTheHead)
{
    const auto layout = CreatureInformationAboveHead::compute(200, 0, 12, 1, FAR_TOP);
    EXPECT_EQ(layout.barsTop + ROW, 200 - GAP);
    EXPECT_EQ(layout.textTop + 12, layout.barsTop - SPACING);
}

TEST(CreatureInformationAboveHead, EveryLocalPlayerRowStaysAboveTheHead)
{
    // health + mana shield + mana + harmony + serene
    const auto layout = CreatureInformationAboveHead::compute(200, 0, 14, 5, FAR_TOP);
    EXPECT_EQ(blockBottom(layout, 14, 5), 200 - GAP);
    EXPECT_EQ(layout.barsTop, 200 - GAP - 16);
    EXPECT_LT(layout.textTop + 14, layout.barsTop);
}

TEST(CreatureInformationAboveHead, NameOnlyCreatureKeepsItsNameAboveTheHead)
{
    const auto layout = CreatureInformationAboveHead::compute(200, 0, 12, 0, FAR_TOP);
    EXPECT_EQ(layout.textTop + 12, 200 - GAP);
}

TEST(CreatureInformationAboveHead, HeadLiftRaisesTheWholeBlock)
{
    const auto base = CreatureInformationAboveHead::compute(200, 0, 12, 2, FAR_TOP);
    const auto lifted = CreatureInformationAboveHead::compute(200, 20, 12, 2, FAR_TOP);
    EXPECT_EQ(lifted.textTop, base.textTop - 20);
    EXPECT_EQ(lifted.barsTop, base.barsTop - 20);

    const auto negative = CreatureInformationAboveHead::compute(200, -5, 12, 2, FAR_TOP);
    EXPECT_EQ(negative.textTop, base.textTop);
}

TEST(CreatureInformationAboveHead, BlockIsPushedDownInsteadOfClippedAtTheMapTop)
{
    const auto layout = CreatureInformationAboveHead::compute(10, 0, 12, 2, 0);
    EXPECT_EQ(layout.textTop, 0);
    EXPECT_EQ(layout.barsTop, 12 + SPACING);

    const auto free = CreatureInformationAboveHead::compute(100, 0, 12, 2, 0);
    EXPECT_EQ(free.barsTop + ROW + STRIDE, 100 - GAP);
}
