setup_org_test_project <- function(pattern = "xne_org_test_") {
  tmp_dir <- fs::file_temp(pattern = pattern)
  fs::dir_create(fs::path(tmp_dir, "data", "shared", "org"), recurse = TRUE)

  tmpl_dir <- system.file(
    "templates",
    "shared",
    "org",
    package = "xpipe"
  )

  testthat::expect_true(fs::dir_exists(tmpl_dir))

  fs::dir_copy(
    tmpl_dir,
    fs::path(tmp_dir, "data", "shared", "org"),
    overwrite = TRUE
  )

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

  xenv <- get(".xpipe_env", envir = asNamespace("xpipe"))
  xenv$config <- mock_cfg

  tmp_dir
}


test_that("load_org loaders read 6-table registry correctly", {
  tmp_dir <- setup_org_test_project("xne_org_load_")
  on.exit(fs::dir_delete(tmp_dir), add = TRUE)

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
  tmp_dir <- setup_org_test_project("xne_org_invalid_struct_")
  on.exit(fs::dir_delete(tmp_dir), add = TRUE)

  struct_path <- fs::path(tmp_dir, "data", "shared", "org", "structures.csv")
  bad_structs <- readr::read_csv(struct_path, show_col_types = FALSE)
  bad_structs$structure_code <- "999"
  readr::write_csv(bad_structs, struct_path)

  expect_error(
    validate_org_registry(),
    class = "xpipe_org_structures"
  )
})


test_that("validate_org_registry detects invalid facility_code", {
  tmp_dir <- setup_org_test_project("xne_org_invalid_fac_")
  on.exit(fs::dir_delete(tmp_dir), add = TRUE)

  fac_path <- fs::path(tmp_dir, "data", "shared", "org", "facilities.csv")
  bad_facs <- readr::read_csv(fac_path, show_col_types = FALSE)
  bad_facs$facility_code <- "12345"
  readr::write_csv(bad_facs, fac_path)

  expect_error(
    validate_org_registry(),
    class = "xpipe_org_facilities"
  )
})


test_that("validate_org_registry detects unknown foreign keys", {
  tmp_dir <- setup_org_test_project("xne_org_invalid_fk_")
  on.exit(fs::dir_delete(tmp_dir), add = TRUE)

  dep_path <- fs::path(tmp_dir, "data", "shared", "org", "departments.csv")
  bad_deps <- readr::read_csv(dep_path, show_col_types = FALSE)
  bad_deps$organization_uid <- "non_existent_org"
  readr::write_csv(bad_deps, dep_path)

  expect_error(
    validate_org_registry(),
    class = "xpipe_org_departments"
  )
})


test_that("validate_org_registry detects structure validity outside organization window", {
  tmp_dir <- setup_org_test_project("xne_org_bad_struct_period_")
  on.exit(fs::dir_delete(tmp_dir), add = TRUE)

  org_path <- fs::path(tmp_dir, "data", "shared", "org", "organizations.csv")
  orgs <- readr::read_csv(org_path, show_col_types = FALSE)
  orgs$valid_from <- as.Date("2022-01-01")
  orgs$valid_to <- as.Date("2022-12-31")
  readr::write_csv(orgs, org_path)

  struct_path <- fs::path(tmp_dir, "data", "shared", "org", "structures.csv")
  structs <- readr::read_csv(struct_path, show_col_types = FALSE)
  structs$valid_from <- as.Date("2023-01-01")
  structs$valid_to <- NA
  readr::write_csv(structs, struct_path)

  expect_error(
    validate_org_registry(),
    class = "xpipe_org_structures"
  )
})


test_that("validate_org_registry detects overlapping structure periods", {
  tmp_dir <- setup_org_test_project("xne_org_overlap_struct_")
  on.exit(fs::dir_delete(tmp_dir), add = TRUE)

  struct_path <- fs::path(tmp_dir, "data", "shared", "org", "structures.csv")
  structs <- readr::read_csv(struct_path, show_col_types = FALSE)

  structs <- dplyr::bind_rows(
    structs,
    dplyr::mutate(
      structs,
      valid_from = as.Date("2022-06-01"),
      valid_to = NA
    )
  )

  readr::write_csv(structs, struct_path)

  expect_error(
    validate_org_registry(),
    class = "xpipe_org_structures"
  )
})


test_that("validate_org_registry detects overlapping facility periods", {
  tmp_dir <- setup_org_test_project("xne_org_overlap_fac_")
  on.exit(fs::dir_delete(tmp_dir), add = TRUE)

  fac_path <- fs::path(tmp_dir, "data", "shared", "org", "facilities.csv")
  facs <- readr::read_csv(fac_path, show_col_types = FALSE)

  facs <- dplyr::bind_rows(
    facs,
    dplyr::mutate(
      facs,
      valid_from = as.Date("2022-06-01"),
      valid_to = NA
    )
  )

  readr::write_csv(facs, fac_path)

  expect_error(
    validate_org_registry(),
    class = "xpipe_org_facilities"
  )
})


test_that("validate_org_registry detects internal unit code without parent_unit_code", {
  tmp_dir <- setup_org_test_project("xne_org_missing_parent_code_")
  on.exit(fs::dir_delete(tmp_dir), add = TRUE)

  code_path <- fs::path(tmp_dir, "data", "shared", "org", "unit_codes.csv")

  codes <- readr::read_csv(
    code_path,
    col_types = readr::cols(
      facility_code = readr::col_character(),
      unit_code = readr::col_character(),
      short_name = readr::col_character(),
      uo_uid = readr::col_character(),
      parent_unit_code = readr::col_character(),
      is_external = readr::col_logical(),
      in_week = readr::col_logical(),
      valid_from = readr::col_date(),
      valid_to = readr::col_date()
    )
  )

  codes <- dplyr::bind_rows(
    codes,
    tibble::tibble(
      facility_code = "15090100",
      unit_code = "0991",
      short_name = "Internal test",
      uo_uid = codes$uo_uid[[1]],
      parent_unit_code = NA_character_,
      is_external = FALSE,
      in_week = TRUE,
      valid_from = as.Date("2022-01-01"),
      valid_to = as.Date(NA)
    )
  )

  readr::write_csv(codes, code_path)

  expect_error(
    validate_org_registry(),
    class = "xpipe_org_unit_codes"
  )
})

test_that("validate_org_registry detects internal unit code with missing external parent", {
  tmp_dir <- setup_org_test_project("xne_org_missing_external_parent_")
  on.exit(fs::dir_delete(tmp_dir), add = TRUE)

  code_path <- fs::path(tmp_dir, "data", "shared", "org", "unit_codes.csv")

  codes <- readr::read_csv(
    code_path,
    col_types = readr::cols(
      facility_code = readr::col_character(),
      unit_code = readr::col_character(),
      short_name = readr::col_character(),
      uo_uid = readr::col_character(),
      parent_unit_code = readr::col_character(),
      is_external = readr::col_logical(),
      in_week = readr::col_logical(),
      valid_from = readr::col_date(),
      valid_to = readr::col_date()
    )
  )

  codes <- dplyr::bind_rows(
    codes,
    tibble::tibble(
      facility_code = "15090100",
      unit_code = "0991",
      short_name = "Internal test",
      uo_uid = codes$uo_uid[[1]],
      parent_unit_code = "9999",
      is_external = FALSE,
      in_week = TRUE,
      valid_from = as.Date("2022-01-01"),
      valid_to = as.Date(NA)
    )
  )

  readr::write_csv(codes, code_path)

  expect_error(
    validate_org_registry(),
    class = "xpipe_org_unit_codes"
  )
})
