# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# tools_access.R
#
# Access Database Extractor for Batch Ingestion.
#
# Approach: Extracts data frames from .mdb or .accdb files using ODBC
# (Windows) or mdb-export (Linux). Fully integrated with the batch
# materialization pipeline.
#
# Public API:  extract_access_db()
# Internals:   .connect_access_db()
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

#' Connect to Access database using ODBC (Auto-detect Win/Linux)
#'
#' @param path_to_mdb Path to .mdb file.
#' @return DBI connection object.
#' @keywords internal
#' @noRd
.connect_access_db <- function(path_to_mdb) {
  .mdb_path_abs <- normalizePath(path_to_mdb, winslash = "/", mustWork = TRUE)

  is_windows <- .Platform$OS.type == "windows"

  if (is_windows) {
    driver_name <- "Microsoft Access Driver (*.mdb, *.accdb)"
  } else {
    drivers <- odbc::odbcListDrivers()
    has_mdb <- any(grepl("MDBTools", drivers$name, ignore.case = TRUE))
    if (has_mdb) {
      driver_name <- drivers$name[grep("MDBTools", drivers$name, ignore.case = TRUE)][1]
    } else {
      driver_name <- "/usr/lib/x86_64-linux-gnu/odbc/libmdbodbc.so"
    }
  }

  cli::cli_alert_info("Connecting using driver: {.val {driver_name}}")

  con <- if (is_windows) {
    DBI::dbConnect(
      odbc::odbc(),
      .connection_string = paste0(
        "Driver={", driver_name, "};",
        "DBQ=", .mdb_path_abs, ";"
      )
    )
  } else {
    DBI::dbConnect(
      odbc::odbc(),
      .connection_string = paste0("Driver=MDBTools;DBQ=", .mdb_path_abs, ";"),
      timeout = 0
    )
  }
  return(con)
}

#' Extract Access Database
#'
#' Extracts tables configured in the method component list from an Access Database.
#'
#' @param job Batch job object.
#' @param path Path to .mdb file.
#' @return A named list of data frames.
#' @export
extract_access_db <- function(ctx) {
  is_windows <- .Platform$OS.type == "windows"

  target_tables <- ctx$method_config$components
  path <- ctx$filepath

  if (is.null(target_tables) || length(target_tables) == 0) {
    cli::cli_abort(
      c(
        "No tables defined for extraction",
        "x" = "Method {.val {ctx$method_id}} is missing the {.field components} list."
      ),
      class = c("batch_job", "config")
    )
  }

  if (is_windows) {
    con <- .connect_access_db(path)
    on.exit(DBI::dbDisconnect(con))

    cli::cli_alert_info("Reading {length(target_tables)} tables via ODBC (Windows)...")
    dfs <- list()
    for (t in target_tables) {
      if (t %in% DBI::dbListTables(con)) {
        cli::cli_inform("Reading: {.val {t}}")
        dfs[[t]] <- tibble::as_tibble(DBI::dbReadTable(con, t))
        cli::cli_alert_success("Read {.val {t}} : {nrow(dfs[[t]])} rows")
      }
    }
    return(dfs)

  } else {
    cli::cli_alert_info("Reading {length(target_tables)} tables via mdb-export (Linux)...")

    available_tables <- system2("mdb-tables", args = c("-1", shQuote(path)), stdout = TRUE)

    dfs <- list()
    for (t in target_tables) {
      if (t %in% available_tables) {
        cli::cli_inform("Exporting: {.val {t}}")

        csv_data <- utils::read.csv(pipe(paste("mdb-export", shQuote(path), shQuote(t))), stringsAsFactors = FALSE)
        dfs[[t]] <- tibble::as_tibble(csv_data)

        date_cols <- grep("^d_", names(dfs[[t]]), value = TRUE)
        if (length(date_cols) > 0) {
          cli::cli_inform("Casting {length(date_cols)} date columns...")
          dfs[[t]] <- dplyr::mutate(dfs[[t]], dplyr::across(
            dplyr::all_of(date_cols),
            ~ as.Date(., format = "%m/%d/%y %H:%M:%S")
          ))
        }

        cli::cli_alert_success("Extracted {.val {t}} : {nrow(dfs[[t]])} rows")
      } else {
        cli::cli_alert_warning("Table {.val {t}} not found in .mdb file.")
      }
    }
    return(dfs)
  }
}
