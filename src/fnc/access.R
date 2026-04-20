
box::use(
  DBI[dbReadTable, dbConnect, dbListTables, dbDisconnect],
  odbc[odbc, odbcListDrivers],
  tibble[as_tibble],
  cli[cli_alert_info, cli_alert_success, cli_inform, cli_abort],
  fs
)

# Connect to Access database using ODBC (Auto-detect Win/Linux)
.connect_access_db <- function(path_to_mdb) {
  .mdb_path_abs <- normalizePath(path_to_mdb, winslash = "/", mustWork = TRUE)
  
  is_windows <- .Platform$OS.type == "windows"
  
  if (is_windows) {
    driver_name <- "Microsoft Access Driver (*.mdb, *.accdb)"
  } else {
    drivers <- odbcListDrivers()
    has_mdb <- any(grepl("MDBTools", drivers$name, ignore.case = TRUE))
    if (has_mdb) {
      driver_name <- drivers$name[grep("MDBTools", drivers$name, ignore.case = TRUE)][1]
    } else {
      driver_name <- "/usr/lib/x86_64-linux-gnu/odbc/libmdbodbc.so"
    }
  }

  cli_alert_info("Connecting using driver: {.val {driver_name}}")

  con <- if (is_windows) {
    dbConnect(
      odbc(),
      .connection_string = paste0(
        "Driver={", driver_name, "};",
        "DBQ=", .mdb_path_abs, ";"
      )
    )
  } else {
    # On Linux, MDBTools often requires 'DBQ' as the key even via arguments
    dbConnect(
      odbc(),
      Driver = driver_name,
      DBQ = .mdb_path_abs
    )
  }
  return(con)
}

#' Extract Access Database
#'
#' @param job Batch job object.
#' @param path Path to .mdb file.
#' @return A named list of data frames.
#' @export
extract_access_db <- function(job, path) {
  con <- .connect_access_db(path)
  on.exit(dbDisconnect(con))

  # Tables to extract (A, B, C, D equivalent in Access)
  target_tables <- c("TblScheda", "TblSchedaDiagnosi", "TblSchedaProcedure")
  
  cli_alert_info("Reading {length(target_tables)} tables from Access...")

  dfs <- list()
  for (t in target_tables) {
    if (t %in% dbListTables(con)) {
      cli_inform("Reading: {.val {t}}")
      dfs[[t]] <- dbReadTable(con, t) |> as_tibble()
      cli_alert_success("Read {.val {t}} : {nrow(dfs[[t]])} rows")
    }
  }

  return(dfs)
}




