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
