yaml_file <- "inst/_xne/xacc.yml"

.cfg <- .load_config(yaml_file)
.cfg$runtime <- list()
.cfg$runtime$pepper <- Sys.getenv("XNE_PEPPER_KEY")
if (.cfg$runtime$pepper == "") {
  cli::cli_abort(
    "{.envvar XNE_PEPPER_KEY} non trovata in {.file .Renviron}. Impossibile avviare il sistema senza la chiave di crittografia.",
    class = "sdo_crypto_error"
  )
}



# Basic loads -------------------------------------------------------------



# Il file di origine
mdb_path <- "inbox/2025_full.mdb"

# La cartella di destinazione
out_dir <- "output"

# Il nome del file di destinazione (senza estensione)
output_name <- "2025_full"
