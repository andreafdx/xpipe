
box::use(
  DBI[dbReadTable, dbConnect, dbListTables, dbDisconnect],
  odbc[odbc, odbcListDrivers],
  tibble[as_tibble],
  cli[cli_alert_info, cli_alert_success, cli_inform, cli_abort, cli_alert_warning],
  dplyr,
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
    # Disable attributes that often fail in MDBTools on Linux
    dbConnect(
      odbc(),
      .connection_string = paste0("Driver=MDBTools;DBQ=", .mdb_path_abs, ";"),
      timeout = 0 # Disables SQL_ATTR_CONNECTION_TIMEOUT which often fails
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
  is_windows <- .Platform$OS.type == "windows"
  target_tables <- c("TblScheda", "TblSchedaDiagnosi", "TblSchedaProcedure")
  
  if (is_windows) {
    # --- ENGINE 1: ODBC (Windows) ---
    con <- .connect_access_db(path)
    on.exit(dbDisconnect(con))
    
    cli_alert_info("Reading {length(target_tables)} tables via ODBC (Windows)...")
    dfs <- list()
    for (t in target_tables) {
      if (t %in% dbListTables(con)) {
        cli_inform("Reading: {.val {t}}")
        dfs[[t]] <- dbReadTable(con, t) |> as_tibble()
        cli_alert_success("Read {.val {t}} : {nrow(dfs[[t]])} rows")
      }
    }
    return(dfs)
    
  } else {
    # --- ENGINE 2: MDB-EXPORT (Linux) ---
    cli_alert_info("Reading {length(target_tables)} tables via mdb-export (Linux)...")
    
    # 1. Get list of available tables
    available_tables <- system2("mdb-tables", args = c("-1", shQuote(path)), stdout = TRUE)
    
    dfs <- list()
    for (t in target_tables) {
      if (t %in% available_tables) {
        cli_inform("Exporting: {.val {t}}")
        
        # Read CSV directly from mdb-export pipe
        # We use read.csv because it's standard, then convert to tibble
        csv_data <- read.csv(pipe(paste("mdb-export", shQuote(path), shQuote(t))), stringsAsFactors = FALSE)
        
        dfs[[t]] <- as_tibble(csv_data)
        
        # --- Smart Date Casting (Linux) ---
        # mdb-export returns dates as strings like "01/14/25 00:00:00"
        # We find columns starting with "d_" and cast them to Date
        date_cols <- grep("^d_", names(dfs[[t]]), value = TRUE)
        if (length(date_cols) > 0) {
          cli_inform("Casting {length(date_cols)} date columns...")
          dfs[[t]] <- dfs[[t]] |>
            dplyr::mutate(dplyr::across(
              dplyr::all_of(date_cols),
              ~ as.Date(., format = "%m/%d/%y %H:%M:%S")
            ))
        }
        
        cli_alert_success("Extracted {.val {t}} : {nrow(dfs[[t]])} rows")
      } else {
        cli_alert_warning("Table {.val {t}} not found in .mdb file.")
      }
    }
    return(dfs)
  }
}




