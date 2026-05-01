# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# test-inspect.R
# Tests for Batch layer inspection and formatting utilities.
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

test_that("inspect_batch_layer correctly identifies complete and incomplete batches", {
  # Mock a minimal configuration object
  mock_config <- structure(
    list(local = list(paths = list(batch = "mock_batch_layer"))),
    class = "xpipe_config"
  )

  withr::with_tempdir({
    # Setup mock batch root
    fs::dir_create("mock_batch_layer")

    # 1. Create a COMPLETE batch
    fs::dir_create("mock_batch_layer/batch_healthy")
    jsonlite::write_json(
      list(
        batch_id = "batch_healthy",
        stream = list(id = "sdo", schema_domain = "sdo"),
        method = list(id = "xml_campania_2026", type = "xml_sdo_trac_b"),
        input = list(path = "test.xml"),
        execution = list(created_at = "2026-04-30T10:00:00Z", tool = "xpipe")
      ),
      "mock_batch_layer/batch_healthy/_batch_metadata.json",
      auto_unbox = TRUE
    )

    # 2. Create an INCOMPLETE batch (no metadata file)
    fs::dir_create("mock_batch_layer/batch_corrupt")

    # Run inspection
    inspection <- inspect_batch_layer(mock_config)

    # Assertions
    expect_s3_class(inspection, "xpipe_batch_layer")
    expect_equal(inspection$count, 2)

    # Check that it flagged the corrupt one
    expect_equal(inspection$batches$batch_corrupt$.status, "incomplete")

    # Check that it parsed the healthy one
    expect_equal(inspection$batches$batch_healthy$batch_id, "batch_healthy")
    expect_null(inspection$batches$batch_healthy$.status)
  })
})

test_that("print.xpipe_batch_layer does not crash when ALL batches are incomplete", {
  mock_config <- structure(
    list(local = list(paths = list(batch = "mock_batch_layer"))),
    class = "xpipe_config"
  )

  withr::with_tempdir({
    fs::dir_create("mock_batch_layer")

    # Create ONLY incomplete batches (simulating a catastrophic pipeline failure)
    fs::dir_create("mock_batch_layer/broken_1")
    fs::dir_create("mock_batch_layer/broken_2")

    inspection <- inspect_batch_layer(mock_config)

    # The primary assertion: printing this object should NOT throw an error.
    # expect_error(..., NA) means "expect no error".
    expect_error(suppressMessages(print(inspection)), NA)
    # It should also invisibly return the object itself
    res <- withVisible(suppressMessages(print(inspection)))
    expect_false(res$visible)
    expect_identical(res$value, inspection)
  })
})

test_that("inspect_batch_layer aborts cleanly if the batch layer path does not exist", {
  mock_config <- structure(
    list(local = list(paths = list(batch = "path_that_does_not_exist"))),
    class = "xpipe_config"
  )

  # Should fail with the specific class defined in layers_inspect.R
  expect_error(
    inspect_batch_layer(mock_config),
    class = "paths"
  )
})
