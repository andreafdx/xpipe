# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# test-guardrails.R
# Tests for pre-materialization guardrails (.assert_batch_materializable).
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

test_that(".assert_batch_materializable catches collisions and missing inputs", {
  mock_config <- structure(list(), class = "xpipe_config")

  withr::with_tempdir({
    ctx <- list(
      batch_id = "test_batch_1",
      batch_dir = fs::path_abs("data/batch/test_batch_1"),
      filepath = fs::path_abs("inbox/test_file.csv")
    )

    # Test A: target directory already exists (collision)
    fs::dir_create(ctx$batch_dir)
    expect_error(
      .assert_batch_materializable(ctx, mock_config),
      class = "xpipe_batch_collision"
    )
    expect_error(
      .assert_batch_materializable(ctx, mock_config),
      "already exists"
    )

    fs::dir_delete(ctx$batch_dir)

    # Test B: input file does not exist at materialization time
    expect_error(
      .assert_batch_materializable(ctx, mock_config),
      class = "xpipe_batch_input"
    )
    expect_error(
      .assert_batch_materializable(ctx, mock_config),
      "does not exist at materialization time"
    )

    # Test C: input file exists but is empty (0 bytes)
    fs::dir_create("inbox")
    fs::file_create(ctx$filepath)
    expect_error(
      .assert_batch_materializable(ctx, mock_config),
      class = "xpipe_batch_input"
    )
    expect_error(
      .assert_batch_materializable(ctx, mock_config),
      "empty or unreadable"
    )

    # Test D: valid state — file exists and has content
    writeLines("test data", ctx$filepath)
    expect_invisible(.assert_batch_materializable(ctx, mock_config))
  })
})
