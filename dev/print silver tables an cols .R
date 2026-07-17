print_silver_current_inventory <- function(stream_id = "sdo") {
  library(DBI)
  library(duckdb)
  library(fs)
  library(jsonlite)

  cfg <- load_xpipe_config()
  silver_db <- fs::path(cfg$xne$paths$silver, paste0(stream_id, ".duckdb"))
  cat("Silver DB path:", silver_db, "\n")
  stopifnot(fs::file_exists(silver_db))

  con <- DBI::dbConnect(
    duckdb::duckdb(),
    dbdir = as.character(silver_db),
    read_only = TRUE
  )
  on.exit(DBI::dbDisconnect(con, shutdown = FALSE), add = TRUE)

  # DuckDB-native listing (avoids dbListTables/sqlite_master path)
  tables <- DBI::dbGetQuery(con, "SHOW TABLES")$name
  cat("Total tables:", length(tables), "\n")

  current_tables <- sort(tables[startsWith(tables, "current__")])
  cat("current__ tables:", length(current_tables), "\n")
  if (length(current_tables) == 0) {
    cat("No current__* tables found.\n")
    return(invisible(NULL))
  }

  cat(paste0(" - ", current_tables), sep = "\n")
  cat("\n\n--- Columns by table (DuckDB DESCRIBE) ---\n")

  for (tbl in current_tables) {
    cat("\n#", tbl, "\n")
    d <- DBI::dbGetQuery(
      con,
      paste0("DESCRIBE ", DBI::dbQuoteIdentifier(con, tbl))
    )
    print(d[, c("column_name", "column_type")], row.names = FALSE)
  }
}

print_silver_harmonized_json_snippet <- function(
  stream_id = "sdo",
  include_tables = NULL
) {
  library(DBI)
  library(duckdb)
  library(fs)
  library(jsonlite)
  library(janitor)

  cfg <- load_xpipe_config()
  silver_db <- fs::path(cfg$xne$paths$silver, paste0(stream_id, ".duckdb"))
  cat("Silver DB path:", silver_db, "\n")
  stopifnot(fs::file_exists(silver_db))

  con <- DBI::dbConnect(
    duckdb::duckdb(),
    dbdir = as.character(silver_db),
    read_only = TRUE
  )
  on.exit(DBI::dbDisconnect(con, shutdown = FALSE), add = TRUE)

  tables <- DBI::dbGetQuery(con, "SHOW TABLES")$name
  current_tables <- sort(tables[startsWith(tables, "current__")])

  if (!is.null(include_tables)) {
    want <- paste0("current__", include_tables)
    current_tables <- intersect(current_tables, want)
  }

  cat("current__ tables:", length(current_tables), "\n")
  if (length(current_tables) == 0) {
    cat("No current__* tables found.\n")
    return(invisible(NULL))
  }

  # helper: mapping for a single table
  build_table_mapping <- function(tbl) {
    d <- DBI::dbGetQuery(
      con,
      paste0("DESCRIBE ", DBI::dbQuoteIdentifier(con, tbl))
    )
    cols <- as.character(d$column_name)

    # split lineage vs business
    lineage <- cols[startsWith(cols, "__")]
    business <- setdiff(cols, lineage)

    # janitor clean names for business only
    clean <- janitor::make_clean_names(business)

    # build mapping: clean_name -> original_name
    mapping <- as.list(setNames(business, clean))

    mapping
  }

  out <- list()

  for (tbl in current_tables) {
    src <- sub("^current__", "", tbl)

    out[[src]] <- list(
      source = src,
      columns = build_table_mapping(tbl)
    )
  }

  cat("\n--- Suggested silver.json snippet (harmonized.tables) ---\n")
  cat(jsonlite::toJSON(out, auto_unbox = TRUE, pretty = TRUE), "\n")

  invisible(out)
}

# Run:
print_silver_current_inventory("sdo")
print_silver_harmonized_json_snippet("sdo")
