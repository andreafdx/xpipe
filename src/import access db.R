
library(arrow) # Scrittura Parquet


source("fnc/access.R")

mdb_path <- "inbox/sdo/2025_full.mdb"

connect_access_db(mdb_path)

dbListTables(con)


# Questo qua sotto va pulito

# --- INPUT: anno e tipo (current/archive) ---
year <- NA_character_
repeat {
  year <- trimws(readline("Inserisci anno (YYYY): "))
  if (grepl("^[0-9]{4}$", year)) break
  message("Valore non valido. Inserisci un anno a 4 cifre, es. 2025.")
}

type <- NA_character_
repeat {
  type <- tolower(trimws(readline("Inserisci tipo (current/archive): ")))
  if (type %in% c("current", "archive")) break
  message("Valore non valido. Digita 'current' oppure 'archive'.")
}

# --- PATHS ---
out_dir <- file.path(getwd(), paste0(year, "_", type))
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)


# --- Tabelle target ---
tbls <- c("TblScheda", "TblSchedaDiagnosi", "TblSchedaProcedure", "TblSchedaTrasferimenti")

#Controllo che esistano nel DB
available <- dbListTables(con)
missing_tbls <- setdiff(tbls, available)
if (length(missing_tbls) > 0) {
  stop("Tabelle mancanti nel database: ", paste(missing_tbls, collapse = ", "))
}

# --- Estrazione + export parquet ---
row_counts <- setNames(integer(length(tbls)), tbls)

for (t in tbls) {
  message("Esporto: ", t)

  df <- dbReadTable(con, t) |> as_tibble()
  row_counts[[t]] <- nrow(df)

  out_file <- file.path(out_dir, paste0(t, ".parquet"))
  write_parquet(df, out_file)
}

# --- Meta file ---
extract_time <- format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z")

meta_lines <- c(
  paste0("Extraction datetime: ", extract_time),
  paste0("Source MDB: ", mdb_path_abs),
  paste0("Output folder: ", normalizePath(out_dir, winslash = "/", mustWork = FALSE)),
  paste0("Extracted tables (", length(tbls), "): ", paste(tbls, collapse = ", ")),
  paste0("Rows in TblScheda: ", row_counts[["TblScheda"]]),
  "",
  "Row counts (all extracted tables):",
  paste0(names(row_counts), ": ", unname(row_counts))
)

writeLines(meta_lines, con = file.path(out_dir, "_meta.txt"))
dbDisconnect(con)

message("Fatto ✅  Parquet + _meta.txt creati in: ", out_dir)




