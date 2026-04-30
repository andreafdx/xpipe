# This tests the pre-flight checks of your pipeline.
# We mock a temporary filesystem to prove the guardrails work.


test_that(".assert_batch_materializable catches collisions and missing inputs", {

  # 1. Setup a fake configuration
  mock_config <- structure(list(), class = "xpipe_config")

  # 2. Run tests inside a temporary directory that vanishes afterward
  withr::with_tempdir({

    # Create fake context
    ctx <- list(
      batch_id = "test_batch_1",
      batch_dir = fs::path_abs("data/batch/test_batch_1"),
      filepath = fs::path_abs("inbox/test_file.csv")
    )

    # Test A: The target directory already exists (Collision)
    fs::dir_create(ctx$batch_dir)
    expect_error(
      .assert_batch_materializable(ctx, mock_config),
      class = "batch_collision" # Wait, you defined it as c("batch", "collision")
    )
    # Note: testthat matches the FIRST class in the vector or uses exact match.
    # It's safer to check the error message if the class vector is complex.
    expect_error(.assert_batch_materializable(ctx, mock_config), "already exists")

    # Cleanup target dir for the next test
    fs::dir_delete(ctx$batch_dir)

    # Test B: The input file does not exist
    expect_error(.assert_batch_materializable(ctx, mock_config), "does not exist at materialization time")

    # Test C: The input file exists but is empty (0 bytes)
    fs::dir_create("inbox")
    fs::file_create(ctx$filepath)
    expect_error(.assert_batch_materializable(ctx, mock_config), "empty or unreadable")

    # Test D: Valid state (file exists and has content)
    writeLines("test data", ctx$filepath)
    expect_invisible(.assert_batch_materializable(ctx, mock_config))
  })
})
