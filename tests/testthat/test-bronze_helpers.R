test_that(".make_key creates composite keys correctly", {
  df <- data.frame(
    id = c(1, 2),
    sub_id = c("A", "B"),
    stringsAsFactors = FALSE
  )

  keys <- .make_key(df, c("id", "sub_id"))
  expect_equal(keys, c("1\rA", "2\rB"))
})

test_that(".validate_anchor_definitions passes valid config", {
  valid_config <- structure(
    list(
      methods = list(
        test_method = list(
          anchor_table = "main_table",
          partition_column = "date_col",
          identity_keys = c("id_1", "id_2")
        )
      )
    ),
    class = "xpipe_config"
  )

  # Should run silently and return TRUE invisibly
  expect_invisible(.validate_anchor_definitions(valid_config, "test_method"))
})

test_that(".validate_anchor_definitions catches missing anchor_table", {
  invalid_config <- structure(
    list(
      methods = list(
        test_method = list(
          partition_column = "date_col",
          identity_keys = "id_1"
          # anchor_table is missing
        )
      )
    ),
    class = "xpipe_config"
  )

  expect_error(
    .validate_anchor_definitions(invalid_config, "test_method"),
    class = "xpipe_bronze_anchor"
  )
})

test_that(".validate_anchor_definitions catches missing identity_keys", {
  invalid_config <- structure(
    list(
      methods = list(
        test_method = list(
          anchor_table = "main_table",
          partition_column = "date_col"
          # identity_keys is missing
        )
      )
    ),
    class = "xpipe_config"
  )

  expect_error(
    .validate_anchor_definitions(invalid_config, "test_method"),
    class = "xpipe_bronze_anchor"
  )
})

test_that("Bronze DuckDB promotion is atomic and append-only", {

  load_xpipe_config(project_root = normalizePath(testthat::test_path("..", ".."), winslash = "/", mustWork = TRUE))
  cfg <- get_xpipe_config()

  withr::with_tempdir({

    batch_dir <- fs::path("batch_one")
    fs::dir_create(batch_dir)

    meta <- list(
      batch_id = "b001_sdo_xml",
      stream = list(id = "sdo", schema_domain = "sdo", anchor = "end"),
      method = list(id = "xml_campania_2026", type = "xml"),
      input = list(path = "xml", input_type = "directory"),
      execution = list(
        created_at = "2026-05-06 12:21:32",
        tool = "xpipe",
        tool_version = "dev"
      ),
      components = list(tracciato_a = "*_A.xml", tracciato_b = "*_B.xml")
    )

    jsonlite::write_json(
      meta,
      fs::path(batch_dir, "_batch_metadata.json"),
      auto_unbox = TRUE,
      pretty = TRUE
    )

    df <- data.frame(
      identificativoPaziente = c("A", "B", "C"),
      sesso = c("M", "F", "M"),
      stringsAsFactors = FALSE
    )

    arrow::write_parquet(
      df,
      fs::path(batch_dir, "tracciato_a_anagrafica.parquet")
    )

    bronze_root <- fs::path("bronze")
    fs::dir_create(bronze_root)

    cfg$local$paths$bronze <- bronze_root

    # First promotion must succeed (writer connection is opened inside the function)
    expect_true(
      .promote_one_table_to_bronze(
        batch_dir = batch_dir,
        source_table = "tracciato_a_anagrafica",
        config = cfg
      )
    )

    # Reader connection for inspection
    con_ro <- .open_bronze_conn(cfg$local$paths$bronze, "sdo", read_only = TRUE)

    log <- DBI::dbGetQuery(con_ro, "SELECT * FROM __promotion_log")
    expect_equal(nrow(log), 1)

    expect_true(
      "sdo__xml_campania_2026__tracciato_a_anagrafica" %in% DBI::dbListTables(con_ro)
    )

    DBI::dbDisconnect(con_ro, shutdown = TRUE)

    # Second promotion with same batch_id must fail (append-only)
    expect_error(
      .promote_one_table_to_bronze(
        batch_dir = batch_dir,
        source_table = "tracciato_a_anagrafica",
        config = cfg
      ),
      class = "xpipe_bronze_append_only"
    )

    # Re-open reader to verify state is unchanged after failed promotion
    con_ro2 <- .open_bronze_conn(cfg$local$paths$bronze, "sdo", read_only = TRUE)

    log_after <- DBI::dbGetQuery(con_ro2, "SELECT * FROM __promotion_log")
    expect_equal(nrow(log_after), 1)

    DBI::dbDisconnect(con_ro2, shutdown = TRUE)
  })
})

