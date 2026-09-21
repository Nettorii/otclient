set(VIEWPORT_METRICS_TEST_SOURCES
    ${CMAKE_CURRENT_SOURCE_DIR}/viewportmetrics_test.cpp
)

otclient_add_gtest(otclient_viewport_metrics_tests ${VIEWPORT_METRICS_TEST_SOURCES})
