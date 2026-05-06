# This tests that the environment variables and global state work
# correctly without actually messing with your real environment.

test_that("Runtime context aborts if pepper is missing", {
  withr::with_envvar(c("XNE_PEPPER_KEY" = NA_character_), {
    expect_error(
      .load_runtime_context(),
      class = "xpipe_runtime_pepper"
    )
  })
})

test_that("Runtime context loads correctly when pepper is present", {
  withr::with_envvar(c("XNE_PEPPER_KEY" = "fake_secret_key"), {
    ctx <- .load_runtime_context()
    expect_equal(ctx$pepper, "fake_secret_key")
    expect_true(inherits(ctx$loaded_at, "POSIXct"))
  })
})

test_that("Package environment stores and retrieves config", {
  mock_config <- structure(list(mock = TRUE), class = "xpipe_config")

  # Inject into the package environment
  .xpipe_env$config <- mock_config
  retrieved <- get_xpipe_config()
  expect_true(retrieved$mock)

  # Clear it and test the specific error class
  .xpipe_env$config <- NULL
  expect_error(
    get_xpipe_config(),
    class = "xpipe_config_missing"
  )
})
