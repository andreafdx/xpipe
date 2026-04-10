library(DBI) # Interfaccia database
library(odbc) # Connessione ODBC a Access


# Check available ODBC drivers for Access
.check_drivers <- function () {
  .drivers <- odbcListDrivers()
  subset(.drivers, grepl("Access", name, ignore.case = TRUE))
}


connect_access_db <- function(path_to_mdb) {
  .mdb_path_abs <- normalizePath(path_to_mdb, winslash = "/", mustWork = TRUE)
  con <- dbConnect(
    odbc(),
    .connection_string = paste0(
      "Driver={Microsoft Access Driver (*.mdb, *.accdb)};",
      "DBQ=", .mdb_path_abs, ";"
    )
  )
  return(con)
}
