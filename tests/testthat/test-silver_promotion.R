# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# test-silver_promotion.R
#
# Tests for Silver promotion and harmonization, specifically verifying EMUR.
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

test_that("EMUR silver promotion and harmonization works end-to-end", {
  proj_root <- fs::path_abs(testthat::test_path("../.."))
  inbox_src <- fs::path_abs(testthat::test_path("../../inbox/emur"))

  # This is a full integration test that requires the real project directory
  # structure (inbox/emur/, data/shared/). Skip gracefully when running under
  # R CMD check or any other environment that doesn't have those paths.
  skip_if_not(
    fs::dir_exists(inbox_src),
    "inbox/emur not found; skipping integration test"
  )
  skip_if_not(
    fs::dir_exists(fs::path(proj_root, "data", "shared")),
    "data/shared not found; skipping integration test"
  )

  base_cfg <- load_xpipe_config(project_root = proj_root)

  withr::with_tempdir({
    # Copy inbox emur to local tempdir
    fs::dir_create("inbox")
    fs::dir_copy(inbox_src, "inbox/emur")

    # Construct a test config
    test_config <- load_xpipe_config(project_root = proj_root)
    test_config$local$paths$inbox <- "inbox"
    test_config$local$paths$batch <- "batch"
    test_config$local$paths$bronze <- "bronze"
    test_config$local$paths$silver <- "silver"

    # Create all directories
    fs::dir_create("batch")
    fs::dir_create("bronze")
    fs::dir_create("silver")

    # Store test_config in active env
    assign("config", test_config, envir = xpipe:::.xpipe_env)

    # 1. Ingest
    ingest_batch(
      filename = "emur",
      method = "xml_emur_campania_2026",
      stream = "emur",
      config = test_config
    )

    # 2. Bronze
    promote_to_bronze(config = test_config)

    # 3. Silver
    promote_to_silver(
      config = test_config,
      stream = "emur",
      phase = "all",
      confirm = FALSE
    )

    # 4. Validate
    silver_db <- "silver/emur.duckdb"
    expect_true(file.exists(silver_db))

    con <- DBI::dbConnect(duckdb::duckdb(), dbdir = silver_db, read_only = TRUE)
    on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

    expect_true(DBI::dbExistsTable(con, DBI::Id(schema = "harmonized", table = "ps")))
    expect_true(DBI::dbExistsTable(con, DBI::Id(schema = "harmonized", table = "procedure")))
    expect_true(DBI::dbExistsTable(con, DBI::Id(schema = "harmonized", table = "obi")))
    expect_true(DBI::dbExistsTable(con, DBI::Id(schema = "harmonized", table = "anagrafica")))

    # Check that OBI, procedures, and anagrafica are joined into harmonized.ps
    df <- DBI::dbGetQuery(
      con,
      "SELECT * FROM harmonized.ps LIMIT 5"
    )
    expect_s3_class(df, "data.frame")
    expect_true("procedura_principale" %in% colnames(df))
    expect_true("tutte_le_procedure" %in% colnames(df))
    expect_true("codice_fiscale" %in% colnames(df))
    expect_true("problema_principale_obi" %in% colnames(df))
    expect_true("t0" %in% colnames(df))
    expect_true("t1" %in% colnames(df))
    expect_true("t2" %in% colnames(df))
    expect_true("t3" %in% colnames(df))
    expect_true("t4" %in% colnames(df))
    expect_true("t5" %in% colnames(df))
    expect_s3_class(df$t0, "POSIXt")

    # Test unified inspect_silver
    insp <- inspect_silver(stream_id = "emur", config = test_config)
    expect_s3_class(insp, "xpipe_silver_inspection")
    expect_equal(insp$silver_status, "UP TO DATE")
    expect_equal(insp$alignment$status, "ALIGNED")
    expect_true(nrow(insp$row_counts) > 0)
    expect_true(nrow(insp$harmonized_tables) > 0)

    # Restore base config
    assign("config", base_cfg, envir = xpipe:::.xpipe_env)
  })
})
