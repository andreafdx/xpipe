
#library(arrow) # Scrittura Parquet
library(cli)

source("src/fnc/access.R")
source("src/fnc/meta_file.R")
source("src/fnc/crypto.R")
source("src/fnc/setup.R")


# Setup -------------------------------------------------------------------


cli::cli_h1 ("Script di estrazione da Access MDB")

cli_inform("Input: {mdb_path}
               Output: {out_dir}/{output_name}.parquet")



# Inizializza db ----------------------------------------------------------

# Inizializza connessione al database Access


cli::cli_h2 ("Connessione al database Access")

.db<-.connect_access_db(mdb_path)

.found_tables <- dbListTables(.db)

cli_inform("Connessione al database riuscita. Trovate {length(.found_tables)} tabelle.")



# Estrai le tabelle -------------------------------------------------------


cli::cli_h2 ("Estrazione delle tabelle richieste")
.check_required_tables(.db, .target_tables)

dfs <- .extract_tables(.db, .target_tables)



# Privacy -----------------------------------------------------------------


dfs <- .apply_privacy(dfs, .cfg$runtime$pepper)



# Salvataggio -------------------------------------------------------------


cli::cli_h2("Salvataggio dei data frame e generazione metadati")
saveRDS(dfs, file.path(out_dir, paste0(output_name, ".rds")))
cli::cli_alert_success("Data frame salvati in: {.file {file.path(out_dir, paste0(output_name, '.rds'))}}")
.generate_meta_file(out_dir, .target_tables, dfs)



