set(VIEWPORT_METRICS_TEST_SOURCES
    ${CMAKE_CURRENT_SOURCE_DIR}/viewportmetrics_test.cpp
)

otclient_add_gtest(otclient_viewport_metrics_tests ${VIEWPORT_METRICS_TEST_SOURCES})

set(PENDING_JNI_STATE_TEST_SOURCES
    ${CMAKE_CURRENT_SOURCE_DIR}/pendingjnistate_test.cpp
)

otclient_add_gtest(otclient_pending_jni_state_tests ${PENDING_JNI_STATE_TEST_SOURCES})

set(ASSET_STAMP_TEST_SOURCES
    ${CMAKE_CURRENT_SOURCE_DIR}/assetstamp_test.cpp
)

otclient_add_gtest(otclient_asset_stamp_tests ${ASSET_STAMP_TEST_SOURCES})
