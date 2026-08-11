test_that("load_org loaders read 6-table registry correctly", {
  tmp_dir <- fs::file_temp(pattern = "xne_org_load_")
  fs::dir_create(fs::path(tmp_dir, "data", "shared", "org"), recurse = TRUE)
  on.exit(fs::dir_delete(tmp_dir), add = TRUE)

  # Copy templates directly to avoid triggering full init_xne_project batch hash checks
  tmpl_dir <- fs::path_abs(testthat::test_path("../../inst/templates/shared/org"))
  fs::dir_copy(tmpl_dir, fs::path(tmp_dir, "data", "shared", "org"), overwrite = TRUE)

  mock_cfg <- structure(
    list(
      xne = list(
        paths = list(
          shared = fs::path(tmp_dir, "data", "shared")
        )
      )
    ),
    class = "xpipe_config"
  )
  .xpipe_env$config <- mock_cfg

  orgs <- load_organizations(validate = FALSE)
  expect_s3_class(orgs, "tbl_df")
  expect_equal(orgs$organization_uid, "cardarelli")

  structs <- load_structures(validate = FALSE)
  expect_s3_class(structs, "tbl_df")
  expect_equal(structs$structure_code, "150901")

  facs <- load_facilities(validate = FALSE)
  expect_s3_class(facs, "tbl_df")
  expect_equal(facs$facility_code, "15090100")

  deps <- load_departments(validate = FALSE)
  expect_s3_class(deps, "tbl_df")

  units <- load_units(validate = FALSE)
  expect_s3_class(units, "tbl_df")

  unit_codes <- load_unit_codes(validate = FALSE)
  expect_s3_class(unit_codes, "tbl_df")

  expect_true(validate_org_registry())
})

test_that("validate_org_registry detects invalid structure_code", {
  tmp_dir <- fs::file_temp(pattern = "xne_org_invalid_struct_")
  fs::dir_create(fs::path(tmp_dir, "data", "shared", "org"), recurse = TRUE)
  on.exit(fs::dir_delete(tmp_dir), add = TRUE)

  tmpl_dir <- fs::path_abs(testthat::test_path("../../inst/templates/shared/org"))
  fs::dir_copy(tmpl_dir, fs::path(tmp_dir, "data", "shared", "org"), overwrite = TRUE)

  mock_cfg <- structure(
    list(
      xne = list(
        paths = list(
          shared = fs::path(tmp_dir, "data", "shared")
        )
      )
    ),
    class = "xpipe_config"
  )
  .xpipe_env$config <- mock_cfg

  # Corrupt structure_code
  struct_path <- fs::path(tmp_dir, "data", "shared", "org", "structures.csv")
  bad_structs <- readr::read_csv(struct_path, show_col_types = FALSE)
  bad_structs$structure_code <- "999" # invalid (needs 6 digits)
  readr::write_csv(bad_structs, struct_path)

  expect_error(
    validate_org_registry(),
    class = "xpipe_org_structures"
  )
})

test_that("validate_org_registry detects invalid facility_code", {
  tmp_dir <- fs::file_temp(pattern = "xne_org_invalid_fac_")
  fs::dir_create(fs::path(tmp_dir, "data", "shared", "org"), recurse = TRUE)
  on.exit(fs::dir_delete(tmp_dir), add = TRUE)

  tmpl_dir <- fs::path_abs(testthat::test_path("../../inst/templates/shared/org"))
  fs::dir_copy(tmpl_dir, fs::path(tmp_dir, "data", "shared", "org"), overwrite = TRUE)

  mock_cfg <- structure(
    list(
      xne = list(
        paths = list(
          shared = fs::path(tmp_dir, "data", "shared")
        )
      )
    ),
    class = "xpipe_config"
  )
  .xpipe_env$config <- mock_cfg

  # Corrupt facility_code
  fac_path <- fs::path(tmp_dir, "data", "shared", "org", "facilities.csv")
  bad_facs <- readr::read_csv(fac_path, show_col_types = FALSE)
  bad_facs$facility_code <- "12345" # invalid (needs 8 digits)
  readr::write_csv(bad_facs, fac_path)

  expect_error(
    validate_org_registry(),
    class = "xpipe_org_facilities"
  )
})

test_that("validate_org_registry detects unknown foreign keys", {
  tmp_dir <- fs::file_temp(pattern = "xne_org_invalid_fk_")
  fs::dir_create(fs::path(tmp_dir, "data", "shared", "org"), recurse = TRUE)
  on.exit(fs::dir_delete(tmp_dir), add = TRUE)

  tmpl_dir <- fs::path_abs(testthat::test_path("../../inst/templates/shared/org"))
  fs::dir_copy(tmpl_dir, fs::path(tmp_dir, "data", "shared", "org"), overwrite = TRUE)

  mock_cfg <- structure(
    list(
      xne = list(
        paths = list(
          shared = fs::path(tmp_dir, "data", "shared")
        )
      )
    ),
    class = "xpipe_config"
  )
  .xpipe_env$config <- mock_cfg

  # Set unknown organization_uid in departments
  dep_path <- fs::path(tmp_dir, "data", "shared", "org", "departments.csv")
  bad_deps <- readr::read_csv(dep_path, show_col_types = FALSE)
  bad_deps$organization_uid <- "non_existent_org"
  readr::write_csv(bad_deps, dep_path)

  expect_error(
    validate_org_registry(),
    class = "xpipe_org_departments"
  )
})
