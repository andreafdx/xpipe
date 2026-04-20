
box::use(
  DBI[dbReadTable],
  odbc[odbc, odbcListDrivers, dbConnect, dbListTables, dbDisconnect],
  tibble[as_tibble],
  cli[cli_alert, cli_alert_success]
)


# Tables
.target_tables <- c("TblScheda", "TblSchedaDiagnosi", "TblSchedaProcedure", "TblSchedaTrasferimenti")


# Check available ODBC drivers for Access
.check_drivers <- function () {
  drivers <- odbcListDrivers()
  subset(drivers, grepl("Access", name, ignore.case = TRUE))
}


# Connect to Access database using ODBC
.connect_access_db <- function(path_to_mdb) {
  .mdb_path_abs <- normalizePath(path_to_mdb, winslash = "/", mustWork = TRUE)
  
  # 1. Resolve Driver based on OS
  is_windows <- .Platform$OS.type == "windows"
  
  if (is_windows) {
    driver_name <- "Microsoft Access Driver (*.mdb, *.accdb)"
  } else {
    # Linux/mdbtools: Usually "MDBTools" or a path to the .so
    # We first check if 'MDBTools' is registered
    drivers <- odbcListDrivers()
    has_mdb <- any(grepl("MDBTools", drivers$name, ignore.case = TRUE))
    
    if (has_mdb) {
      driver_name <- drivers$name[grep("MDBTools", drivers$name, ignore.case = TRUE)][1]
    } else {
      # Fallback to common library path if not registered in odbcinst.ini
      driver_name <- "/usr/lib/x86_64-linux-gnu/odbc/libmdbodbc.so"
      if (!fs::file_exists(driver_name)) {
        cli::cli_abort(
          c(
            "Access driver not found",
            "x" = "MDBTools is not registered and {.file {driver_name}} does not exist.",
            "i" = "Please install {.pkg mdbtools} and {.pkg odbc-mdbtools}."
          )
        )
      }
    }
  }

  cli::cli_alert_info("Connecting using driver: {.val {driver_name}}")

  con <- dbConnect(
    odbc(),
    .connection_string = paste0(
      "Driver={", driver_name, "};",
      "DBQ=", .mdb_path_abs, ";"
    )
  )
  return(con)
}


# Check available tables in the database
.check_required_tables <- function(con, required_tables) {
  available <- dbListTables(con)
  missing_tbls <- setdiff(required_tables, available)
  if (length(missing_tbls) > 0) {
    stop("Tabelle mancanti nel database: ", paste(missing_tbls, collapse = ", "))
  }
}


# Extract specified tables and return as a named list of data frames
.extract_tables <- function(con, tables) {

  dfs <- setNames(vector("list", length(tables)), tables)

  #row_counts <- setNames(integer(length(tables)), tables)

  for (t in tables) {
    cli_inform("Lettura di {.val {t}}")

    dfs[[t]] <- dbReadTable(con, t) |> as_tibble()
    #row_counts[[t]] <- nrow(dfs[[t]])

    cli_alert_success("Fatto: {.val {t}} ({nrow(dfs[[t]])} rows)")
  }
  return(dfs)
}




