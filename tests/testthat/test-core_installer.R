test_that("init_xne_project creates full directory structure and loads configuration", {
  tmp_dir <- fs::file_temp(pattern = "xne_test_project_")
  fs::dir_create(tmp_dir)
  on.exit(fs::dir_delete(tmp_dir), add = TRUE)

  test_pepper <- "test_pepper_key_12345"

  cfg <- init_xne_project(path = tmp_dir, pepper = test_pepper)

  expect_s3_class(cfg, "xpipe_config")
  expect_true(fs::file_exists(fs::path(tmp_dir, "xne.json")))
  expect_true(fs::dir_exists(fs::path(tmp_dir, "inbox")))
  expect_true(fs::dir_exists(fs::path(tmp_dir, "logs")))
  expect_true(fs::file_exists(fs::path(tmp_dir, "data", "shared", "streams.json")))
  expect_true(fs::file_exists(fs::path(tmp_dir, "data", "shared", "methods.json")))
  expect_true(fs::file_exists(fs::path(tmp_dir, "data", "shared", "silver.json")))
  expect_true(fs::file_exists(fs::path(tmp_dir, "data", "batch", "layer.json")))
  expect_true(fs::file_exists(fs::path(tmp_dir, "data", "bronze", "layer.json")))
  expect_true(fs::file_exists(fs::path(tmp_dir, "data", "silver", "layer.json")))

  # Check creation date format YYYY-MM-DD
  today <- format(Sys.Date(), "%Y-%m-%d")
  batch_layer <- jsonlite::fromJSON(fs::path(tmp_dir, "data", "batch", "layer.json"))
  expect_equal(batch_layer$created_at, today)

  bronze_layer <- jsonlite::fromJSON(fs::path(tmp_dir, "data", "bronze", "layer.json"))
  expect_equal(bronze_layer$created_at, today)

  silver_layer <- jsonlite::fromJSON(fs::path(tmp_dir, "data", "silver", "layer.json"))
  expect_equal(silver_layer$created_at, today)
})

test_that("init_xne_project requires path parameter", {
  expect_error(init_xne_project(), regexp = "path")
})

test_that("init_xne_project throws error if project exists and overwrite is FALSE", {
  tmp_dir <- fs::file_temp(pattern = "xne_test_overwrite_")
  fs::dir_create(tmp_dir)
  on.exit(fs::dir_delete(tmp_dir), add = TRUE)

  test_pepper <- "test_pepper_key_12345"

  init_xne_project(path = tmp_dir, pepper = test_pepper)

  expect_error(
    init_xne_project(path = tmp_dir, overwrite = FALSE, pepper = test_pepper),
    class = "xpipe_installer_path"
  )

  # With overwrite = TRUE in non-interactive session it should succeed
  expect_no_error(
    init_xne_project(path = tmp_dir, overwrite = TRUE, pepper = test_pepper)
  )
})

test_that("init_xne_project cancels overwrite if response is not 'yes'", {
  tmp_dir <- fs::file_temp(pattern = "xne_test_cancel_")
  fs::dir_create(tmp_dir)
  on.exit(fs::dir_delete(tmp_dir), add = TRUE)

  test_pepper <- "test_pepper_key_12345"
  init_xne_project(path = tmp_dir, pepper = test_pepper)

  testthat::with_mocked_bindings(
    .confirm_overwrite = function(target_root) {
      cli::cli_abort(
        c(
          "Project initialization cancelled",
          "x" = "Confirmation answer was 'no' instead of 'yes'."
        ),
        class = c("xpipe_installer_cancelled", "xpipe_installer_error", "xpipe_error")
      )
    },
    code = {
      expect_error(
        init_xne_project(path = tmp_dir, overwrite = TRUE, pepper = test_pepper),
        class = "xpipe_installer_cancelled"
      )
    }
  )
})

test_that("init_xne_project throws error if pepper key is missing", {
  tmp_dir <- fs::file_temp(pattern = "xne_test_no_pepper_")
  fs::dir_create(tmp_dir)
  on.exit(fs::dir_delete(tmp_dir), add = TRUE)

  old_pepper <- Sys.getenv("XNE_PEPPER_KEY", unset = NA)
  Sys.unsetenv("XNE_PEPPER_KEY")
  on.exit({
    if (!is.na(old_pepper)) Sys.setenv(XNE_PEPPER_KEY = old_pepper)
  }, add = TRUE)

  expect_error(
    init_xne_project(path = tmp_dir, pepper = NULL),
    class = "xpipe_installer_pepper"
  )
})

test_that("load_xpipe_config failure suggests running init_xne_project", {
  non_existent_dir <- fs::file_temp(pattern = "non_existent_xne_")

  err <- expect_error(
    load_xpipe_config(project_root = non_existent_dir),
    class = "xpipe_config_error"
  )

  expect_match(conditionMessage(err), "init_xne_project")
})
