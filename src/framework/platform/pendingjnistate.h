#pragma once

#include <atomic>
#include <mutex>
#include <optional>
#include <utility>

#include "viewportmetrics.h"

// Written from the Android UI thread through JNI and drained by the native main
// thread. JNI may fire before the engine (dispatcher, sound, Lua) is initialized
// and after it has shut down, so writers never touch engine state directly.
class PendingJniState
{
public:
    struct Pending
    {
        std::optional<ViewportMetrics> viewportMetrics;
        std::optional<bool> audioEnabled;
        bool systemBack{ false };
    };

    void setViewportMetrics(const ViewportMetrics& viewportMetrics)
    {
        if (m_closed.load())
            return;
        std::scoped_lock lock(m_mutex);
        m_viewportMetrics = viewportMetrics;
    }

    void setAudioEnabled(const bool enabled)
    {
        if (m_closed.load())
            return;
        std::scoped_lock lock(m_mutex);
        m_audioEnabled = enabled;
    }

    // A Back press before the engine is ready has nothing to act on.
    void requestSystemBack()
    {
        if (m_closed.load() || !m_ready.load())
            return;
        std::scoped_lock lock(m_mutex);
        m_systemBack = true;
    }

    void setReady(const bool ready) { m_ready.store(ready); }

    void close()
    {
        m_closed.store(true);
        m_ready.store(false);
        std::scoped_lock lock(m_mutex);
        m_viewportMetrics.reset();
        m_audioEnabled.reset();
        m_systemBack = false;
    }

    // Nothing is delivered until ready; the latest viewport/audio values are kept.
    Pending take()
    {
        Pending pending;
        if (m_closed.load() || !m_ready.load())
            return pending;

        std::scoped_lock lock(m_mutex);
        pending.viewportMetrics = std::exchange(m_viewportMetrics, std::nullopt);
        pending.audioEnabled = std::exchange(m_audioEnabled, std::nullopt);
        pending.systemBack = std::exchange(m_systemBack, false);
        return pending;
    }

private:
    std::mutex m_mutex;
    std::atomic_bool m_ready{ false };
    std::atomic_bool m_closed{ false };
    std::optional<ViewportMetrics> m_viewportMetrics;
    std::optional<bool> m_audioEnabled;
    bool m_systemBack{ false };
};
