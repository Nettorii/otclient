#include <gtest/gtest.h>

#include <framework/platform/pendingjnistate.h>

#include <thread>

TEST(PendingJniState, ViewportMetricsAreHeldUntilReadyAndDeliveredLatestOnly)
{
    PendingJniState state;
    state.setViewportMetrics({ 1, 2, 3, 4, 0 });
    state.setViewportMetrics({ 5, 6, 7, 8, 90 });
    EXPECT_FALSE(state.take().viewportMetrics.has_value());

    state.setReady(true);
    const auto pending = state.take();
    ASSERT_TRUE(pending.viewportMetrics.has_value());
    EXPECT_EQ(*pending.viewportMetrics, (ViewportMetrics{ 5, 6, 7, 8, 90 }));
    EXPECT_FALSE(state.take().viewportMetrics.has_value());
}

TEST(PendingJniState, AudioIsHeldUntilReady)
{
    PendingJniState state;
    state.setAudioEnabled(true);
    state.setAudioEnabled(false);
    EXPECT_FALSE(state.take().audioEnabled.has_value());

    state.setReady(true);
    const auto pending = state.take();
    ASSERT_TRUE(pending.audioEnabled.has_value());
    EXPECT_FALSE(*pending.audioEnabled);
    EXPECT_FALSE(state.take().audioEnabled.has_value());
}

TEST(PendingJniState, SystemBackBeforeReadyIsDropped)
{
    PendingJniState state;
    state.requestSystemBack();
    state.setReady(true);
    EXPECT_FALSE(state.take().systemBack);

    state.requestSystemBack();
    EXPECT_TRUE(state.take().systemBack);
    EXPECT_FALSE(state.take().systemBack);
}

TEST(PendingJniState, EverythingIsIgnoredAfterClose)
{
    PendingJniState state;
    state.setReady(true);
    state.setViewportMetrics({ 1, 2, 3, 4, 0 });
    state.close();
    state.setViewportMetrics({ 5, 6, 7, 8, 0 });
    state.setAudioEnabled(false);
    state.requestSystemBack();

    const auto pending = state.take();
    EXPECT_FALSE(pending.viewportMetrics.has_value());
    EXPECT_FALSE(pending.audioEnabled.has_value());
    EXPECT_FALSE(pending.systemBack);
}

TEST(PendingJniState, ConcurrentWritersAndDrainerDoNotLoseTheLatestValue)
{
    PendingJniState state;
    state.setReady(true);

    std::thread writer([&] {
        for (int i = 1; i <= 10000; ++i) {
            state.setViewportMetrics({ i, i, i, i, 0 });
            state.setAudioEnabled((i % 2) == 0);
        }
    });

    ViewportMetrics last;
    for (int i = 0; i < 1000; ++i) {
        if (const auto pending = state.take(); pending.viewportMetrics)
            last = *pending.viewportMetrics;
    }
    writer.join();
    if (const auto pending = state.take(); pending.viewportMetrics)
        last = *pending.viewportMetrics;

    EXPECT_EQ(last, (ViewportMetrics{ 10000, 10000, 10000, 10000, 0 }));
}
