# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# test-silver_promotion.R
#
# Tests for Silver promotion and harmonization, specifically verifying EMUR.
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

test_that("EMUR silver promotion and harmonization works end-to-end", {
  proj_root <- fs::path_abs(testthat::test_path("../.."))
  base_cfg <- load_xpipe_config(project_root = proj_root)
  inbox_src <- fs::path_abs(testthat::test_path("../../inbox/emur"))

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

    tables <- DBI::dbListTables(con)
    expect_true("harmonized__ps" %in% tables)
    expect_true("harmonized__procedure" %in% tables)
    expect_true("harmonized__obi" %in% tables)
    expect_true("harmonized__anagrafica" %in% tables)

    # Check that OBI, procedures, and anagrafica are joined into harmonized__ps
    df <- DBI::dbGetQuery(
      con,
      "SELECT * FROM harmonized__ps LIMIT 5"
    )
    expect_s3_class(df, "data.frame")
    expect_true("procedura_principale" %in% colnames(df))
    expect_true("tutte_le_procedure" %in% colnames(df))
    expect_true("codice_fiscale" %in% colnames(df))
    expect_true("problema_principale_obi" %in% colnames(df))

    # Restore base config
    assign("config", base_cfg, envir = xpipe:::.xpipe_env)
  })
})
