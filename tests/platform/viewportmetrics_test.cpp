#include <gtest/gtest.h>

#include <framework/platform/viewportmetrics.h>

TEST(ViewportMetrics, ClampsNegativeValues)
{
    ViewportMetrics metrics{ -4, 8, -2, 12, -20 };
    metrics.normalize();
    EXPECT_EQ(metrics, (ViewportMetrics{ 0, 8, 0, 12, 0 }));
}

TEST(ViewportMetrics, EqualityIncludesKeyboardHeight)
{
    EXPECT_NE(
        (ViewportMetrics{ 1, 2, 3, 4, 0 }),
        (ViewportMetrics{ 1, 2, 3, 4, 240 })
    );
}
