test_that("init_xne_org_registry initializes all 6 template files", {
  tmp_dir <- fs::file_temp(pattern = "xne_org_test_")
  fs::dir_create(tmp_dir)
  on.exit(fs::dir_delete(tmp_dir), add = TRUE)

  expect_true(init_xne_org_registry(path = tmp_dir))

  org_dir <- fs::path(tmp_dir, "data", "shared", "org")
  expect_true(fs::dir_exists(org_dir))

  expected_files <- c(
    "organizations.csv",
    "structures.csv",
    "facilities.csv",
    "departments.csv",
    "units.csv",
    "unit_codes.csv"
  )

  for (f in expected_files) {
    expect_true(fs::file_exists(fs::path(org_dir, f)))
  }
})

test_that("init_xne_org_registry respects overwrite flag", {
  tmp_dir <- fs::file_temp(pattern = "xne_org_overwrite_")
  fs::dir_create(tmp_dir)
  on.exit(fs::dir_delete(tmp_dir), add = TRUE)

  init_xne_org_registry(path = tmp_dir)

  # Should error without overwrite = TRUE
  expect_error(
    init_xne_org_registry(path = tmp_dir, overwrite = FALSE),
    class = "xpipe_installer_path"
  )

  # Should succeed with overwrite = TRUE, confirm = FALSE
  expect_no_error(
    init_xne_org_registry(path = tmp_dir, overwrite = TRUE, confirm = FALSE)
  )
})
