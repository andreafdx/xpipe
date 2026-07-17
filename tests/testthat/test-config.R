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

test_that(".load_xne_config loads xne.json from project_root when present", {
  withr::with_tempdir({
    dir.create("shared")
    dir.create("inbox")
    dir.create("batch")
    dir.create("bronze")
    dir.create("silver")
    dir.create("logs")

    cfg_data <- list(
      meta = list(
        config_version = "1.0",
        project = "xne",
        description = "Path configuration for xne medallion analytic framework",
        created_at = "2026-07-17",
        last_updated_at = "2026-07-17"
      ),
      paths = list(
        shared = "shared",
        inbox = "inbox",
        batch = "batch",
        bronze = "bronze",
        silver = "silver"
      ),
      logging = list(
        level = "info",
        path = "logs/xpipe.log"
      )
    )
    jsonlite::write_json(cfg_data, "xne.json", auto_unbox = TRUE)

    loaded <- .load_xne_config(project_root = ".")
    expect_true(fs::file_exists(loaded$paths$shared))
    expect_equal(loaded$meta$project, "xne")
  })
})

test_that(".load_xne_config falls back to inst/xne.local.json when xne.json is absent", {
  withr::with_tempdir({
    dir.create("data/shared", recursive = TRUE)
    dir.create("inbox", recursive = TRUE)
    dir.create("data/inbox", recursive = TRUE)
    dir.create("data/batch", recursive = TRUE)
    dir.create("data/bronze", recursive = TRUE)
    dir.create("data/silver", recursive = TRUE)
    dir.create("logs", recursive = TRUE)

    # No xne.json in tempdir
    loaded <- .load_xne_config(project_root = ".")
    expect_type(loaded$paths, "list")
    expect_equal(loaded$meta$project, "xne")
  })
})
