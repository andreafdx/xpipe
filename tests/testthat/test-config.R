# This tests that the environment variables and global state work
# correctly without actually messing with your real environment.

test_that("Runtime context aborts if pepper is missing", {
  # Temporarily unset the pepper key
  withr::with_envvar(c("XNE_PEPPER_KEY" = NA_character_), {
    expect_error(.load_runtime_context(), "Environment variable")
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
  # Mock a config object
  mock_config <- structure(list(mock = TRUE), class = "xpipe_config")

  # Inject into environment
  .xpipe_env$config <- mock_config

  # Retrieve it
  retrieved <- get_xpipe_config()
  expect_true(retrieved$mock)

  # Clear it and test abortion
  .xpipe_env$config <- NULL
  expect_error(get_xpipe_config(), class = "config_missing")
})
