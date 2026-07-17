# inspect silver ----------------------------------------------------------

source("dev/zload all.R")
cfg <- load_xpipe_config()

silver_db <- fs::path(cfg$xne$paths$silver, "sdo.duckdb")

con <- DBI::dbConnect(
  duckdb::duckdb(),
  dbdir = as.character(silver_db),
  read_only = FALSE
)

# optional: consolidate WAL
DBI::dbExecute(con, "CHECKPOINT")

# tables
tabs <- DBI::dbListTables(con)
print(tabs)

# row counts
for (tab in tabs) {
  sql <- paste0(
    "SELECT ",
    DBI::dbQuoteLiteral(con, tab),
    " AS table_name, COUNT(*) AS n FROM ",
    DBI::dbQuoteIdentifier(con, tab)
  )
  print(DBI::dbGetQuery(con, sql))
}

# inspect anchor current
DBI::dbGetQuery(
  con,
  "SELECT
     codiceIstitutoDiCura,
     progressivoSDO,
     __batch_id,
     __batch_created_at
   FROM current__ricovero
   LIMIT 20"
)

# anchor uniqueness check: should return 0 rows
DBI::dbGetQuery(
  con,
  "SELECT
     codiceIstitutoDiCura,
     progressivoSDO,
     COUNT(*) AS n
   FROM current__ricovero
   GROUP BY codiceIstitutoDiCura, progressivoSDO
   HAVING COUNT(*) > 1
   LIMIT 20"
)

# orphan check for diagnosi: should return 0
if ("current__diagnosi" %in% tabs) {
  print(DBI::dbGetQuery(
    con,
    "SELECT COUNT(*) AS orphan_diagnosi
     FROM current__diagnosi d
     LEFT JOIN current__ricovero r
       ON d.codiceIstitutoDiCura = r.codiceIstitutoDiCura
      AND d.progressivoSDO = r.progressivoSDO
      AND d.__batch_id = r.__batch_id
     WHERE r.__batch_id IS NULL"
  ))
}

# orphan check for procedure: should return 0
if ("current__procedure" %in% tabs) {
  print(DBI::dbGetQuery(
    con,
    "SELECT COUNT(*) AS orphan_procedure
     FROM current__procedure p
     LEFT JOIN current__ricovero r
       ON p.codiceIstitutoDiCura = r.codiceIstitutoDiCura
      AND p.progressivoSDO = r.progressivoSDO
      AND p.__batch_id = r.__batch_id
     WHERE r.__batch_id IS NULL"
  ))
}

# check latest batches represented in current anchor
DBI::dbGetQuery(
  con,
  "SELECT
     __batch_id,
     __batch_created_at,
     COUNT(*) AS n
   FROM current__ricovero
   GROUP BY __batch_id, __batch_created_at
   ORDER BY __batch_created_at DESC, __batch_id DESC"
)

DBI::dbDisconnect(con, shutdown = TRUE)
