# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# 2. silver_promotion.R
#
# Promotes Bronze data to the Silver layer.
#
# Approach:
# Builds Silver-current tables from Bronze DuckDB tables. Currentness is defined
# by the latest batch containing each entity, ordered by __batch_created_at and
# __batch_id. Secondary tables are filtered by joining to the current anchor
# table using identity keys plus __batch_id.
#
# Public API: promote_to_silver()
# Internals: .promote_to_silver_current(), .promote_to_silver_harmonized()
#            .normalize_silver_as_of(), .assert_current_as_of_compatible(),
#            .resolve_silver_canonical_method(),
#            .is_silver_up_to_date(),
#            .promote_single_harmonized_table(),
#            .promote_all_harmonized_tables(), .ensure_silver_log(), .write_silver_log(),
#            .confirm_silver_promotion(), .select_silver_promotion_targets(),
#            .silver_profile_sdo_harmonized_v1(), .silver_profile_emur_harmonized_v1()
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# Error Class Taxonomy ----------------------------------------------------
#
#   xpipe_error
#   └── xpipe_silver_error
#       ├── xpipe_silver_config   # silver.json missing, disabled, or invalid configuration
#       ├── xpipe_silver_state    # Silver DB path or log validation failure
#       ├── xpipe_silver_anchor   # Silver anchor table missing from Bronze
#       └── xpipe_silver_abort    # user declined Silver promotion confirmation prompt

# Public API --------------------------------------------------------------

#' Promote data to Silver
#'
#' Uses silver.json to resolve canonical methods and build Silver tables.
#' Supports Silver-current and Silver-harmonized phases.
#'
#' @param config xpipe_config.
#' @param stream Optional stream id. If NULL, promotes enabled streams from silver.json.
#' @param phase Character. One of "all", "current", "harmonized".
#'   - "all": rebuild current first, then harmonized (if enabled)
#'   - "current": rebuild current only
#'   - "harmonized": rebuild harmonized only from existing current tables
#' @param as_of Optional ingestion snapshot timestamp. If provided, current is rebuilt using
#'   only Bronze rows with `__batch_created_at <= as_of`. This is ingestion time, not domain time.
#' @param dry_run Logical. If TRUE, prints what would be done.
#' @param confirm Logical. Ask for confirmation before writing.
#'
#' @return Invisibly TRUE.
#' @export
promote_to_silver <- function(
  config = get_xpipe_config(),
  stream = NULL,
  phase = "all",
  as_of = NULL,
  dry_run = FALSE,
  confirm = interactive()
) {
  checkmate::assert_class(config, "xpipe_config")
  checkmate::assert_string(stream, null.ok = TRUE)
  checkmate::assert_string(phase)
  checkmate::assert_flag(dry_run)
  checkmate::assert_flag(confirm)
  as_of <- .normalize_silver_as_of(as_of)

  if (is.null(config$silver) || length(config$silver) == 0) {
    cli::cli_abort(
      c(
        "Silver contract not loaded",
        "x" = "No silver streams found in config. Ensure data/shared/silver.json is present and valid."
      ),
      class = c("xpipe_config_error", "xpipe_error")
    )
  }

  if (!phase %in% c("current", "harmonized", "all")) {
    cli::cli_abort(
      c(
        "Unsupported Silver phase",
        "x" = "Phase must be one of {.val {'current'}}, {.val {'harmonized'}}, {.val {'all'}}."
      ),
      class = c("xpipe_silver_error", "xpipe_error")
    )
  }

  targets <- .select_silver_promotion_targets(
    config = config,
    stream = stream,
    phase = phase
  )

  if (length(targets) == 0) {
    cli::cli_inform("No Silver streams enabled for phase {.val {phase}}.")
    return(invisible(TRUE))
  }

  # Dry Run block

  if (isTRUE(dry_run)) {
    for (sid in targets) {
      mid <- .resolve_silver_canonical_method(sid, config)

      h_on <- isTRUE(config$silver[[sid]]$harmonized$enabled %||% FALSE)

      msg_phase <- switch(
        phase,
        "current" = "current only",
        "harmonized" = "harmonized only",
        "all" = if (h_on) {
          "current + harmonized"
        } else {
          "current (harmonized disabled)"
        },
        phase
      )

      if (is.null(as_of)) {
        cli::cli_inform(
          "Would promote Silver for stream {.val {sid}} using method {.val {mid}} ({.val {msg_phase}})."
        )
      } else {
        cli::cli_inform(
          "Would promote Silver for stream {.val {sid}} using method {.val {mid}} ({.val {msg_phase}}) as of ingestion snapshot {.val {as_of}}."
        )
      }
    }
    return(invisible(TRUE))
  }

  .confirm_silver_promotion(confirm)

  for (sid in targets) {
    if (phase %in% c("current", "all")) {
      .promote_to_silver_current(
        stream_id = sid,
        config = config,
        as_of = as_of
      )
    }

    if (phase %in% c("harmonized", "all")) {
      .promote_to_silver_harmonized(
        stream_id = sid,
        config = config,
        as_of = as_of
      )
    }
  }

  invisible(TRUE)
}

# Harmonization profile registry -------------------------------------------

#' SDO Silver-harmonized profile
#'
#' Code-driven harmonization profile for the SDO stream.
#' Consolidates diagnoses, procedures, and patient demographics into the
#' primary hospitalization table using single-pass aggregations.
#'
#' @param con DuckDB connection to the Silver database.
#' @param stream_id Stream identifier.
#' @param method_id Canonical method identifier.
#' @param config xpipe_config object.
#'
#' @return Invisibly TRUE.
#' @keywords internal
#' @noRd
.silver_profile_sdo_harmonized_v1 <- function(
  con,
  stream_id,
  method_id,
  config
) {
  # 1. Aggregate all diagnosis classifications in a single pass
  diag_aggregated_sql <- "
    SELECT
      codice_istituto_di_cura,
      progressivo_sdo,

      -- Extract the first element of the sorted list where type is principal
      (LIST(diagnosi_dimissione ORDER BY num_diagnosi) FILTER (WHERE tipo_diagnosi = 'principale'))[1] AS diagnosi_principale,
      -- Collect all secondary diagnoses into a list column: may be empty
      LIST(diagnosi_dimissione ORDER BY num_diagnosi) FILTER (WHERE tipo_diagnosi <> 'principale') AS diagnosi_secondarie,
      -- Collect all diagnoses into a comprehensive list column
      LIST(diagnosi_dimissione ORDER BY num_diagnosi) AS tutte_le_diagnosi

    FROM harmonized.diagnosi
    GROUP BY codice_istituto_di_cura, progressivo_sdo
  "

  # 2. Aggregate all surgical/diagnostic procedures in a single pass

  proc_aggregated_sql <- "
    SELECT
      codice_istituto_di_cura,
      progressivo_sdo,

      -- principal procedure: may not exist, return NULL if absent
      CASE
        WHEN COUNT(*) FILTER (WHERE tipo_intervento = 'principale') > 0
        THEN (
          LIST(intervento ORDER BY num_intervento)
            FILTER (WHERE tipo_intervento = 'principale')
        )[1]
        ELSE NULL
      END AS procedura_principale,

      -- all procedures: may be empty
      LIST(intervento ORDER BY num_intervento) AS tutte_le_procedure

    FROM harmonized.procedure
    GROUP BY codice_istituto_di_cura, progressivo_sdo
  "

  # 3. Clean pass to fetch patient demographics from anagrafica
  id_paziente_sql <- "
    SELECT
      codice_istituto_di_cura,
      progressivo_sdo,
      identificativo_paziente
    FROM harmonized.anagrafica
  "

  # 4. DRG normalization expression
  drg_normalized_expr <- "
    CASE
      WHEN r.drg IS NULL OR trim(r.drg) = '' THEN NULL
      WHEN length(trim(r.drg)) > 3 THEN trim(r.drg)
      ELSE lpad(trim(r.drg), 3, '0')
    END
  "

  # Rebuild the master ricovero table via streamlined left joins

  sql <- paste0(
    "CREATE OR REPLACE TABLE harmonized.ricovero AS
     SELECT
       r.* REPLACE (",
    drg_normalized_expr,
    " AS drg),
       d.diagnosi_principale,
       d.diagnosi_secondarie,
       d.tutte_le_diagnosi,
       p.procedura_principale,
       p.tutte_le_procedure,
       a.identificativo_paziente
     FROM harmonized.ricovero r
     LEFT JOIN (",
    diag_aggregated_sql,
    ") d
       ON r.codice_istituto_di_cura = d.codice_istituto_di_cura
      AND r.progressivo_sdo = d.progressivo_sdo
     LEFT JOIN (",
    proc_aggregated_sql,
    ") p
       ON r.codice_istituto_di_cura = p.codice_istituto_di_cura
      AND r.progressivo_sdo = p.progressivo_sdo
     LEFT JOIN (",
    id_paziente_sql,
    ") a
       ON r.codice_istituto_di_cura = a.codice_istituto_di_cura
      AND r.progressivo_sdo = a.progressivo_sdo"
  )

  DBI::dbExecute(con, sql)

  invisible(TRUE)
}

#' EMUR Silver-harmonized profile
#'
#' Code-driven harmonization profile for the EMUR stream.
#' Aggregates procedures and OBI details, and joins patient demographics.
#'
#' @param con DuckDB connection to the Silver database.
#' @param stream_id Stream identifier.
#' @param method_id Canonical method identifier.
#' @param config xpipe_config object.
#'
#' @return Invisibly TRUE.
#' @keywords internal
#' @noRd
.silver_profile_emur_harmonized_v1 <- function(
  con,
  stream_id,
  method_id,
  config
) {
  # Helper to build timestamp SQL expression safely
  sql_timestamp <- function(date_col, time_col) {
    paste0(
      "CASE WHEN ",
      date_col,
      " IS NULL OR trim(",
      date_col,
      ") = '' ",
      "OR ",
      time_col,
      " IS NULL OR trim(",
      time_col,
      ") = '' THEN NULL ",
      "ELSE TRY_CAST(",
      date_col,
      " || ' ' || ",
      time_col,
      " AS TIMESTAMP) END"
    )
  }

  sql_select <- paste0(
    "ps.*, ",
    sql_timestamp("ps.data_entrata", "ps.ora_entrata"),
    " AS t0, ",
    sql_timestamp("ps.data_presa_in_carico", "ps.ora_presa_in_carico"),
    " AS t1, ",
    "NULL::TIMESTAMP AS t2, ",
    sql_timestamp("ps.data_uscita", "ps.ora_uscita"),
    " AS t3"
  )
  sql_joins <- ""

  # 1. Aggregate and join procedures if present
  if (NROW(DBI::dbGetQuery(con, "SELECT 1 FROM duckdb_tables() WHERE schema_name = 'harmonized' AND table_name = 'procedure'")) > 0) {
    proc_aggregated_sql <- "
      SELECT
        codice_struttura_erogatore,
        progressivo,
        (LIST(prestazione ORDER BY num_procedura) FILTER (WHERE tipo_prestazione = 'principale'))[1] AS procedura_principale,
        LIST(prestazione ORDER BY num_procedura) AS tutte_le_procedure
      FROM harmonized.procedure
      GROUP BY codice_struttura_erogatore, progressivo
    "
    sql_select <- paste0(
      sql_select,
      ", p.procedura_principale, p.tutte_le_procedure"
    )
    sql_joins <- paste0(
      sql_joins,
      " LEFT JOIN (",
      proc_aggregated_sql,
      ") p
         ON ps.codice_struttura_erogatore = p.codice_struttura_erogatore
        AND ps.progressivo = p.progressivo"
    )
  }

  # 2. Join patient demographics from anagrafica if present
  if (NROW(DBI::dbGetQuery(con, "SELECT 1 FROM duckdb_tables() WHERE schema_name = 'harmonized' AND table_name = 'anagrafica'")) > 0) {
    id_paziente_sql <- "
      SELECT
        codice_struttura_erogatore,
        progressivo,
        codice_fiscale,
        sesso,
        data_nascita,
        luogo_residenza,
        asl_residenza,
        regione_residenza
      FROM harmonized.anagrafica
    "
    sql_select <- paste0(
      sql_select,
      ", a.codice_fiscale",
      ", a.sesso",
      ", a.data_nascita",
      ", a.luogo_residenza",
      ", a.asl_residenza",
      ", a.regione_residenza"
    )
    sql_joins <- paste0(
      sql_joins,
      " LEFT JOIN (",
      id_paziente_sql,
      ") a
         ON ps.codice_struttura_erogatore = a.codice_struttura_erogatore
        AND ps.progressivo = a.progressivo"
    )
  }

  # 3. Join OBI details if present
  if (NROW(DBI::dbGetQuery(con, "SELECT 1 FROM duckdb_tables() WHERE schema_name = 'harmonized' AND table_name = 'obi'")) > 0) {
    obi_sql <- "
      SELECT
        codice_struttura_erogatore,
        progressivo,
        problema_principale_obi,
        diagnosi_principale_uscita_obi,
        prestazione_principale_obi,
        data_ingresso_obi,
        ora_ingresso_obi,
        data_uscita_obi,
        ora_uscita_obi,
        esito_obi
      FROM harmonized.obi
    "
    sql_select <- paste0(
      sql_select,
      ", o.problema_principale_obi",
      ", o.diagnosi_principale_uscita_obi",
      ", o.prestazione_principale_obi",
      ", o.data_ingresso_obi",
      ", o.ora_ingresso_obi",
      ", o.data_uscita_obi",
      ", o.ora_uscita_obi",
      ", o.esito_obi, ",
      sql_timestamp("o.data_ingresso_obi", "o.ora_ingresso_obi"),
      " AS t4, ",
      sql_timestamp("o.data_uscita_obi", "o.ora_uscita_obi"),
      " AS t5"
    )
    sql_joins <- paste0(
      sql_joins,
      " LEFT JOIN (",
      obi_sql,
      ") o
         ON ps.codice_struttura_erogatore = o.codice_struttura_erogatore
        AND ps.progressivo = o.progressivo"
    )
  } else {
    sql_select <- paste0(
      sql_select,
      ", NULL::TIMESTAMP AS t4, NULL::TIMESTAMP AS t5"
    )
  }

  sql <- paste0(
    "CREATE OR REPLACE TABLE harmonized.ps AS ",
    "SELECT ",
    sql_select,
    " ",
    "FROM harmonized.ps ps",
    sql_joins
  )

  DBI::dbExecute(con, sql)

  invisible(TRUE)
}

#' Silver-harmonized profile registry
#'
#' Internal registry mapping harmonization profile identifiers
#' (as declared in silver.json) to code-driven profile functions.
.silver_harmonized_profile_registry <- list(
  sdo_harmonized_v1 = .silver_profile_sdo_harmonized_v1,
  emur_harmonized_v1 = .silver_profile_emur_harmonized_v1
)

# Helpers -----------------------------------------------------------------

#' @keywords internal
#' @noRd
.normalize_silver_as_of <- function(as_of = NULL) {
  if (is.null(as_of)) {
    return(NULL)
  }

  if (inherits(as_of, "POSIXt")) {
    return(format(as_of, "%Y-%m-%d %H:%M:%S"))
  }

  if (inherits(as_of, "Date")) {
    return(format(as.POSIXct(as_of), "%Y-%m-%d %H:%M:%S"))
  }

  if (is.character(as_of) && length(as_of) == 1 && nzchar(as_of)) {
    parsed <- as.POSIXct(
      as_of,
      tz = "UTC",
      tryFormats = c(
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%dT%H:%M:%S",
        "%Y-%m-%d"
      )
    )

    if (!is.na(parsed)) {
      return(format(parsed, "%Y-%m-%d %H:%M:%S"))
    }
  }

  cli::cli_abort(
    c(
      "Invalid Silver snapshot timestamp",
      "x" = "{.arg as_of} must be NULL, Date, POSIXct, or a parseable datetime string",
      "i" = "Examples: '2026-05-21', '2026-05-21 23:59:59'"
    ),
    class = c("xpipe_silver_config", "xpipe_silver_error", "xpipe_error")
  )
}

#' Assert that Silver-current build is compatible with requested as_of
#'
#' Ensures that phase="harmonized" is rebuilt from a Silver-current state
#' consistent with the requested ingestion snapshot as_of.
#'
#' Uses __silver_log as the authoritative source of build metadata.
#'
#' @param con DuckDB connection to the Silver DB.
#' @param stream_id Stream identifier.
#' @param as_of Optional ingestion snapshot timestamp (normalized string or NULL).
#'
#' @return Invisibly TRUE or aborts.
#' @keywords internal
#' @noRd
.assert_current_as_of_compatible <- function(con, stream_id, method_id, as_of) {
  # If no snapshot requested, any current state is acceptable.
  if (is.null(as_of)) {
    return(invisible(TRUE))
  }

  tabs <- DBI::dbGetQuery(con, "SHOW TABLES")$name
  if (!("__silver_log" %in% tabs)) {
    cli::cli_abort(
      c(
        "Cannot verify Silver-current snapshot compatibility",
        "x" = "__silver_log is missing",
        "i" = "Run {.code promote_to_silver(stream = stream_id, phase = 'current', as_of = as_of)} first"
      ),
      class = c("xpipe_silver_error", "xpipe_error")
    )
  }

  cur <- DBI::dbGetQuery(
    con,
    "
    SELECT as_of, built_at
    FROM __silver_log
    WHERE stream_id = ?
      AND method_id = ?
      AND phase = 'current'
    ORDER BY built_at DESC
    LIMIT 1
    ",
    params = list(stream_id, method_id)
  )

  if (nrow(cur) == 0) {
    cli::cli_abort(
      c(
        "Cannot verify Silver-current snapshot compatibility",
        "x" = "No Silver-current build found in __silver_log for the canonical method",
        "i" = "Run {.code promote_to_silver(stream = stream_id, phase = 'current', as_of = as_of)} first"
      ),
      class = c("xpipe_silver_error", "xpipe_error")
    )
  }

  current_as_of <- cur$as_of[[1]]
  if (is.na(current_as_of)) {
    current_as_of <- NULL
  }

  if (!identical(current_as_of, as_of)) {
    cli::cli_abort(
      c(
        "Silver-current snapshot mismatch",
        "x" = "Requested as_of = {.val {as_of}} but latest Silver-current build is as_of = {.val {current_as_of %||% 'latest'}}",
        "i" = "Rebuild Silver-current with the same snapshot, or run {.code phase = 'all'}"
      ),
      class = c("xpipe_silver_error", "xpipe_error")
    )
  }

  invisible(TRUE)
}


#' Resolve canonical method for Silver-current
#' This is called by dry run and promotion functions
#' to determine which canonical method to use for Silver-current.
#'
#' @keywords internal
#' @noRd
.resolve_silver_canonical_method <- function(stream_id, config) {
  if (is.null(config$silver[[stream_id]])) {
    cli::cli_abort(
      c(
        "Silver not configured for stream",
        "x" = "Stream {.val {stream_id}} not found in silver.json"
      ),
      class = c("xpipe_config_error", "xpipe_error")
    )
  }

  s <- config$silver[[stream_id]]

  if (!isTRUE(s$current$enabled)) {
    cli::cli_abort(
      c(
        "Silver-current disabled",
        "x" = "Silver-current is disabled for stream {.val {stream_id}}"
      ),
      class = c("xpipe_config_error", "xpipe_error")
    )
  }

  s$canonical_method
}

#' Check if Silver-current is up to date with Bronze for a given stream and method
#' This is called by .promote_silver_current only,
#' to determine if a rebuild is necessary.
#'
#' @keywords internal
#' @noRd
.is_silver_up_to_date <- function(
  con,
  stream_id,
  method_id,
  anchor_tbl,
  as_of = NULL
) {
  anchor_full <- paste0(stream_id, "__", method_id, "__", anchor_tbl)

  bronze_anchor <- paste0(
    "bronze.main.",
    DBI::dbQuoteIdentifier(con, anchor_full)
  )

  where_sql <- if (is.null(as_of)) {
    ""
  } else {
    paste0(
      " WHERE __batch_created_at <= ",
      DBI::dbQuoteLiteral(con, as_of)
    )
  }

  latest_bronze <- DBI::dbGetQuery(
    con,
    paste0(
      "SELECT __batch_id AS batch_id
       FROM ",
      bronze_anchor,
      where_sql,
      "
       ORDER BY __batch_created_at DESC, __batch_id DESC
       LIMIT 1"
    )
  )

  latest_bronze <- if (nrow(latest_bronze) == 0) {
    NA_character_
  } else {
    latest_bronze$batch_id[[1]]
  }

  silver_latest <- if (NROW(DBI::dbGetQuery(con, "SELECT 1 FROM duckdb_tables() WHERE schema_name = 'current' AND table_name = ?", params = list(anchor_tbl))) > 0) {
    out <- DBI::dbGetQuery(
      con,
      paste0(
        "SELECT __batch_id AS batch_id
         FROM ",
        DBI::dbQuoteIdentifier(con, DBI::Id(schema = "current", table = anchor_tbl)),
        "
         ORDER BY __batch_created_at DESC, __batch_id DESC
         LIMIT 1"
      )
    )

    if (nrow(out) == 0) NA_character_ else out$batch_id[[1]]
  } else {
    NA_character_
  }

  if (is.na(latest_bronze) || is.na(silver_latest)) {
    return(FALSE)
  }

  identical(latest_bronze, silver_latest)
}


#' Promote a single Silver-current table to Silver-harmonized
#'
#' Creates or replaces a harmonized__* table from the corresponding
#' current__* table by:
#' - renaming explicitly mapped columns
#' - passing through all other columns unchanged
#' - always preserving lineage columns (__*)
#'
#' @param con DuckDB connection.
#' @param source_table Name of the current__* source table.
#' @param target_table Name of the harmonized__* target table.
#' @param column_map Named list mapping new_name -> old_name.
#'
#' @return Invisibly TRUE.
#' @keywords internal
#' @noRd
.promote_single_harmonized_table <- function(
  con,
  source_table,
  target_table,
  column_map
) {
  actual_cols <- names(DBI::dbGetQuery(
    con,
    paste0("SELECT * FROM ", DBI::dbQuoteIdentifier(con, source_table), " LIMIT 0")
  ))

  if (length(column_map) > 0) {
    keep_mask <- vapply(
      column_map,
      function(old_name) old_name %in% actual_cols,
      logical(1)
    )
    column_map <- column_map[keep_mask]
  }

  if (length(column_map) == 0) {
    sql <- paste0(
      "CREATE OR REPLACE TABLE ",
      DBI::dbQuoteIdentifier(con, target_table),
      " AS SELECT * FROM ",
      DBI::dbQuoteIdentifier(con, source_table)
    )
    DBI::dbExecute(con, sql)
    return(invisible(TRUE))
  }

  old_cols <- unname(unlist(column_map))
  exclude_sql <- paste(DBI::dbQuoteIdentifier(con, old_cols), collapse = ", ")

  rename_sql <- vapply(
    names(column_map),
    function(new_name) {
      old_name <- column_map[[new_name]]
      paste0(
        DBI::dbQuoteIdentifier(con, old_name),
        " AS ",
        DBI::dbQuoteIdentifier(con, new_name)
      )
    },
    character(1)
  )

  sql <- paste0(
    "CREATE OR REPLACE TABLE ",
    DBI::dbQuoteIdentifier(con, target_table),
    " AS SELECT ",
    paste(rename_sql, collapse = ", "),
    ", * EXCLUDE (",
    exclude_sql,
    ") FROM ",
    DBI::dbQuoteIdentifier(con, source_table)
  )

  DBI::dbExecute(con, sql)
  invisible(TRUE)
}

#' Promote all Silver-harmonized tables for a stream
#'
#' Iterates over the harmonized table definitions declared in silver.json
#' and promotes each corresponding current__* table to harmonized__*.
#'
#' @param con DuckDB connection.
#' @param stream_id Stream identifier.
#' @param config xpipe_config object.
#'
#' @return Invisibly TRUE.
#' @keywords internal
#' @noRd
.promote_all_harmonized_tables <- function(con, stream_id, config) {
  hcfg <- config$silver[[stream_id]]$harmonized
  tables <- hcfg$tables

  for (tbl_name in names(tables)) {
    src <- tables[[tbl_name]]$source
    colmap <- unlist(tables[[tbl_name]]$columns) %||% character(0)

    source_table <- DBI::Id(schema = "current", table = src)
    target_table <- DBI::Id(schema = "harmonized", table = tbl_name)

    src_exists <- NROW(DBI::dbGetQuery(
      con,
      "SELECT 1 FROM duckdb_tables() WHERE schema_name = 'current' AND table_name = ?",
      params = list(src)
    )) > 0

    if (!src_exists) {
      .log_debug(paste0(
        "Source table current.",
        src,
        " not found in Silver database. Skipping harmonization for this table."
      ))
      next
    }

    .promote_single_harmonized_table(
      con = con,
      source_table = source_table,
      target_table = target_table,
      column_map = colmap
    )
  }

  invisible(TRUE)
}


#' Ensure Silver build log exists
#'
#' Creates the __silver_log table if it does not already exist.
#'
#' @param con DuckDB connection.
#'
#' @return Invisibly TRUE.
#' @keywords internal
#' @noRd
.ensure_silver_log <- function(con) {
  DBI::dbExecute(
    con,
    "
    CREATE TABLE IF NOT EXISTS __silver_log (
      phase TEXT,
      stream_id TEXT,
      method_id TEXT,
      as_of TEXT,
      built_at TIMESTAMP,
      source_tables TEXT,
      output_tables TEXT
    )
    "
  )
}


#' Write a Silver build log entry
#'
#' Records metadata about a Silver build (current or harmonized),
#' including phase, stream, method, snapshot, and produced tables.
#'
#' @param con DuckDB connection.
#' @param phase Build phase ("current" or "harmonized").
#' @param stream_id Stream identifier.
#' @param method_id Canonical method identifier.
#' @param as_of Optional ingestion snapshot timestamp.
#' @param source_tables Character vector of source table names.
#' @param output_tables Character vector of output table names.
#'
#' @return Invisibly TRUE.
#' @keywords internal
#' @noRd
.write_silver_log <- function(
  con,
  phase,
  stream_id,
  method_id,
  as_of,
  source_tables,
  output_tables
) {
  .ensure_silver_log(con)

  DBI::dbExecute(
    con,
    "
    INSERT INTO __silver_log
    (phase, stream_id, method_id, as_of, built_at, source_tables, output_tables)
    VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP, ?, ?)
    ",
    params = list(
      phase,
      stream_id,
      method_id,
      as_of %||% NA_character_,
      jsonlite::toJSON(source_tables, auto_unbox = TRUE),
      jsonlite::toJSON(output_tables, auto_unbox = TRUE)
    )
  )
}


## Pipeline ----------------------------------------------------------------

#' Promote Bronze data to Silver-current (DuckDB)
#'
#' Builds Silver-current tables for a given stream and method by selecting the
#' latest batch per entity from the anchor table and collecting secondary tables
#' via `(identity_keys + __batch_id)`.
#'
#' Currentness is defined by ingestion order:
#' `__batch_created_at DESC, __batch_id DESC`.
#'
#' @param stream_id Character scalar. Stream identifier.
#' @param config xpipe_config.
#' @param as_of Optional POSIXct. Only include Bronze batches created at or before this time.
#'
#' @return Invisibly TRUE on success.
#' @keywords internal
.promote_to_silver_current <- function(stream_id, config, as_of = NULL) {
  # 1. Preconditions

  checkmate::assert_string(stream_id)
  checkmate::assert_class(config, "xpipe_config")
  # Internal. Always called via promote_to_silver(), which normalizes as_of.
  # Do not call directly.

  method_id <- .resolve_silver_canonical_method(stream_id, config)

  bronze_root <- config$local$paths$bronze
  silver_root <- config$local$paths$silver

  if (
    !checkmate::test_string(bronze_root, min.chars = 1) ||
      !checkmate::test_string(silver_root, min.chars = 1)
  ) {
    cli::cli_abort(
      c(
        "Silver promotion failed",
        "x" = "Both paths$bronze and paths$silver must be configured"
      ),
      class = c("xpipe_silver_state", "xpipe_error")
    )
  }

  method_cfg <- config$methods[[method_id]]
  if (is.null(method_cfg)) {
    cli::cli_abort(
      c(
        "Invalid Silver configuration",
        "x" = "Canonical method {.val {method_id}} not found in methods contract"
      ),
      class = c("xpipe_methods_error", "xpipe_error")
    )
  }

  anchor_tbl <- method_cfg$anchor_table %||% NA_character_
  keys <- method_cfg$identity_keys %||% character(0)

  if (
    !checkmate::test_string(anchor_tbl, min.chars = 1) ||
      !checkmate::test_character(keys, min.len = 1)
  ) {
    cli::cli_abort(
      c(
        "Invalid Silver configuration",
        "x" = "Method must define anchor_table and identity_keys"
      ),
      class = c("xpipe_silver_config", "xpipe_error")
    )
  }

  bronze_db <- fs::path(bronze_root, paste0(stream_id, ".duckdb"))
  silver_db <- fs::path(silver_root, paste0(stream_id, ".duckdb"))

  if (!fs::file_exists(bronze_db)) {
    cli::cli_abort(
      c(
        "Bronze database not found",
        "x" = "Expected {.file {bronze_db}} to exist"
      ),
      class = c("xpipe_bronze_state", "xpipe_error")
    )
  }

  fs::dir_create(silver_root, recurse = TRUE)

  # 2. Open Silver and attach Bronze

  con_s <- DBI::dbConnect(
    duckdb::duckdb(),
    dbdir = as.character(silver_db),
    read_only = FALSE
  )
  DBI::dbExecute(con_s, "CREATE SCHEMA IF NOT EXISTS current;")

  on.exit(
    {
      try(DBI::dbExecute(con_s, "DETACH bronze"), silent = TRUE)
      DBI::dbDisconnect(con_s, shutdown = TRUE)
    },
    add = TRUE
  )

  DBI::dbExecute(
    con_s,
    paste0(
      "ATTACH ",
      DBI::dbQuoteLiteral(con_s, as.character(bronze_db)),
      " AS bronze (READ_ONLY)"
    )
  )

  # 3. Discover Bronze tables

  prefix <- paste0(stream_id, "__", method_id, "__")
  anchor_full <- paste0(prefix, anchor_tbl)

  bronze_tables <- DBI::dbGetQuery(
    con_s,
    "SELECT table_name
     FROM duckdb_tables()
     WHERE database_name = 'bronze'
       AND schema_name = 'main'"
  )$table_name

  method_tables <- bronze_tables[startsWith(bronze_tables, prefix)]

  if (!(anchor_full %in% method_tables)) {
    cli::cli_abort(
      c(
        "Anchor table not found in Bronze",
        "x" = "Expected {.val {anchor_full}} to exist"
      ),
      class = c("xpipe_silver_anchor", "xpipe_silver_error", "xpipe_error")
    )
  }

  current_anchor <- DBI::Id(schema = "current", table = anchor_tbl)

  key_cols <- DBI::dbQuoteIdentifier(con_s, keys)
  keys_sql <- paste(key_cols, collapse = ", ")

  bronze_anchor <- paste0(
    "bronze.main.",
    DBI::dbQuoteIdentifier(con_s, anchor_full)
  )

  # 4. Up-to-date check

  if (
    .is_silver_up_to_date(
      con_s,
      stream_id,
      method_id,
      anchor_tbl,
      as_of = as_of
    )
  ) {
    if (!interactive()) {
      if (is.null(as_of)) {
        cli::cli_inform(
          "Silver-current for stream {.val {stream_id}} left unchanged (already up to date)."
        )
      } else {
        cli::cli_inform(
          "Silver-current for stream {.val {stream_id}} left unchanged (already up to date for snapshot {.val {as_of}})."
        )
      }
      return(invisible(TRUE))
    }

    answer <- readline(
      if (is.null(as_of)) {
        paste0(
          "Silver-current is already up to date for stream ",
          stream_id,
          ". Rebuild anyway? [y/N]: "
        )
      } else {
        paste0(
          "Silver-current is already up to date for stream ",
          stream_id,
          " as of ",
          as_of,
          ". Rebuild anyway? [y/N]: "
        )
      }
    )

    if (!nzchar(answer) || tolower(substr(answer, 1, 1)) != "y") {
      cli::cli_inform(
        "Silver-current for stream {.val {stream_id}} left unchanged."
      )
      return(invisible(TRUE))
    }

    cli::cli_inform(
      "Rebuilding Silver-current for stream {.val {stream_id}} despite being up to date."
    )
  }

  # 5. Transactional rebuild

  anchor_where_sql <- if (is.null(as_of)) {
    ""
  } else {
    paste0(
      "WHERE a.__batch_created_at <= ",
      DBI::dbQuoteLiteral(con_s, as_of)
    )
  }

  DBI::dbBegin(con_s)

  rlang::try_fetch(
    {
      DBI::dbExecute(
        con_s,
        paste0(
          "CREATE OR REPLACE TABLE ",
          DBI::dbQuoteIdentifier(con_s, current_anchor),
          " AS
           SELECT * EXCLUDE (rn)
           FROM (
             SELECT
               a.*,
               ROW_NUMBER() OVER (
                 PARTITION BY ",
          keys_sql,
          "
                 ORDER BY __batch_created_at DESC, __batch_id DESC
               ) AS rn
             FROM ",
          bronze_anchor,
          " a
             ",
          anchor_where_sql,
          "
           ) t
           WHERE rn = 1"
        )
      )

      for (bt in method_tables) {
        short <- sub(prefix, "", bt, fixed = TRUE)
        if (identical(short, anchor_tbl)) {
          next
        }

        bronze_sec <- paste0(
          "bronze.main.",
          DBI::dbQuoteIdentifier(con_s, bt)
        )

        current_sec <- DBI::Id(schema = "current", table = short)

        join_keys <- paste(
          paste0(
            "s.",
            DBI::dbQuoteIdentifier(con_s, keys),
            " = a.",
            DBI::dbQuoteIdentifier(con_s, keys)
          ),
          collapse = " AND "
        )

        DBI::dbExecute(
          con_s,
          paste0(
            "CREATE OR REPLACE TABLE ",
            DBI::dbQuoteIdentifier(con_s, current_sec),
            " AS
             SELECT s.*
             FROM ",
            bronze_sec,
            " s
             INNER JOIN ",
            DBI::dbQuoteIdentifier(con_s, current_anchor),
            " a
               ON ",
            join_keys,
            "
              AND s.__batch_id = a.__batch_id"
          )
        )
      }

      # Define the actual short names created by stripping the prefix
      short_names <- sub(prefix, "", method_tables, fixed = TRUE)

      .write_silver_log(
        con = con_s,
        phase = "current",
        stream_id = stream_id,
        method_id = method_id,
        as_of = as_of,
        source_tables = paste0("bronze__", method_tables),
        output_tables = paste0("current.", short_names)
      )

      DBI::dbCommit(con_s)

      if (is.null(as_of)) {
        cli::cli_alert_success(
          "Silver-current rebuilt for stream {.val {stream_id}} using method {.val {method_id}}."
        )
      } else {
        cli::cli_alert_success(
          "Silver-current rebuilt for stream {.val {stream_id}} using method {.val {method_id}} as of ingestion snapshot {.val {as_of}}."
        )
      }

      invisible(TRUE)
    },
    error = function(e) {
      try(DBI::dbRollback(con_s), silent = TRUE)
      cli::cli_abort(
        c(
          "Silver-current promotion failed",
          "x" = "Silver tables were not rebuilt successfully."
        ),
        parent = e,
        class = c("xpipe_silver_error", "xpipe_error")
      )
    }
  )
}


#' Promote Silver-current data to Silver-harmonized
#'
#' Orchestrates the Silver-harmonized phase for a stream by:
#' - promoting all declared harmonized tables
#' - applying profile-specific enrichments (if any)
#' - recording build metadata in __silver_log
#'
#' @param stream_id Stream identifier.
#' @param config xpipe_config object.
#' @param as_of Optional ingestion snapshot timestamp.
#'
#' @return Invisibly TRUE.
#' @keywords internal
.promote_to_silver_harmonized <- function(stream_id, config, as_of = NULL) {
  checkmate::assert_string(stream_id)
  checkmate::assert_class(config, "xpipe_config")
  # Internal. Always called via promote_to_silver(), which normalizes as_of.
  # Do not call directly.

  s <- config$silver[[stream_id]]
  if (is.null(s) || !isTRUE(s$harmonized$enabled)) {
    cli::cli_inform("Silver-harmonized disabled for stream {.val {stream_id}}.")
    return(invisible(TRUE))
  }

  profile_id <- s$harmonized$profile
  profile_fn <- .silver_harmonized_profile_registry[[profile_id]]

  if (is.null(profile_fn)) {
    cli::cli_abort(
      c(
        "Unknown Silver harmonization profile",
        "x" = "Profile {.val {profile_id}} is not registered"
      ),
      class = c("xpipe_silver_error", "xpipe_error")
    )
  }

  silver_db <- fs::path(config$local$paths$silver, paste0(stream_id, ".duckdb"))

  if (!fs::file_exists(silver_db)) {
    cli::cli_abort(
      c(
        "Silver database not found",
        "x" = "Expected {.file {silver_db}} to exist",
        "i" = "Run {.code promote_to_silver(stream = '{stream_id}', phase = 'current')} first"
      ),
      class = c("xpipe_silver_state", "xpipe_silver_error", "xpipe_error")
    )
  }

  con <- DBI::dbConnect(
    duckdb::duckdb(),
    dbdir = as.character(silver_db),
    read_only = FALSE
  )
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbExecute(con, "CREATE SCHEMA IF NOT EXISTS harmonized;")

  .assert_current_as_of_compatible(con, stream_id, s$canonical_method, as_of)

  DBI::dbBegin(con)

  rlang::try_fetch(
    {
      .promote_all_harmonized_tables(
        con = con,
        stream_id = stream_id,
        config = config
      )

      profile_fn(
        con,
        stream_id,
        s$canonical_method,
        config
      )

      .write_silver_log(
        con = con,
        phase = "harmonized",
        stream_id = stream_id,
        method_id = s$canonical_method,
        as_of = as_of,
        source_tables = paste0("current.", names(s$harmonized$tables)),
        output_tables = paste0("harmonized.", names(s$harmonized$tables))
      )

      DBI::dbCommit(con)

      cli::cli_alert_success(
        "Silver-harmonized rebuilt for stream {.val {stream_id}} using method {.val {s$canonical_method}}."
      )

      invisible(TRUE)
    },
    error = function(e) {
      try(DBI::dbRollback(con), silent = TRUE)
      cli::cli_abort(
        c(
          "Silver-harmonized promotion failed",
          "x" = "Harmonized tables were not rebuilt successfully."
        ),
        parent = e,
        class = c("xpipe_silver_error", "xpipe_error")
      )
    }
  )
}

## CLI ---------------------------------------------------------------------

#' This function encapsulates the logic for selecting which Silver streams to promote
#' based on the config, requested phase, and optional explicit stream argument.
#'
#' @param config xpipe_config object containing silver contract.
#' @param stream Optional character scalar specifying a single stream to promote.
#' @param phase Character scalar specifying the promotion phase ("current", "harmonized", or "all").
#'
#' @return Character vector of stream identifiers to promote.
#'
#' @keywords internal
#' @noRd
.select_silver_promotion_targets <- function(
  config,
  stream = NULL,
  phase = "all"
) {
  checkmate::assert_class(config, "xpipe_config")
  checkmate::assert_string(stream, null.ok = TRUE)
  checkmate::assert_string(phase)

  silver_streams <- names(config$silver)

  if (length(silver_streams) == 0) {
    cli::cli_abort(
      c(
        "Silver contract not loaded",
        "x" = "No streams found in silver.json."
      ),
      class = c("xpipe_config_error", "xpipe_error")
    )
  }

  is_harmonized_needed <- phase %in% c("harmonized", "all")

  # We use 'is_enabled' as a helper to pre-filter streams for interactive selection,
  # and also to validate an explicit stream argument.
  # 'enabled' is the subset of silver_streams that meet the phase requirements.
  is_enabled <- function(stream_id) {
    s <- config$silver[[stream_id]]
    isTRUE(s$current$enabled) &&
      (!is_harmonized_needed || isTRUE(s$harmonized$enabled))
  }

  enabled <- silver_streams[vapply(silver_streams, is_enabled, logical(1))]

  # Case 1: Explicit stream provided: validate and return if compliant with phase requirements
  #
  # The stream is checked against silver.json settings for the stream itself,
  # but also for the requested phase requirements.
  # For example, if phase="harmonized" is requested, we check that the stream
  # has harmonized enabled, but also that current is enabled
  # (because harmonized depends on current).
  if (!is.null(stream)) {
    if (!(stream %in% silver_streams)) {
      cli::cli_abort(
        c(
          "Invalid Silver stream",
          "x" = "Stream {.val {stream}} not found in silver.json"
        ),
        class = c("xpipe_config_error", "xpipe_error")
      )
    }

    s <- config$silver[[stream]]

    if (!isTRUE(s$current$enabled)) {
      cli::cli_abort(
        c(
          "Silver-current disabled",
          "x" = "Silver-current is disabled for stream {.val {stream}}"
        ),
        class = c("xpipe_config_error", "xpipe_error")
      )
    }

    if (is_harmonized_needed && !isTRUE(s$harmonized$enabled)) {
      cli::cli_abort(
        c(
          "Silver-harmonized disabled",
          "x" = "Silver-harmonized is disabled for stream {.val {stream}}"
        ),
        class = c("xpipe_config_error", "xpipe_error")
      )
    }

    return(stream)
  }

  # Case 2: No explicit stream: select from enabled set (if any)
  #
  # At this point, we know stream is NULL (not provided), so we want to select from the enabled set.
  # 'enabled' is the set of streams that meet the phase requirements.
  # They are "pre-checked" as they are generated.
  if (length(enabled) == 0) {
    return(character(0))
  }

  # Non-interactive: return enabled set
  if (!interactive()) {
    return(enabled)
  }

  choices <- c("All enabled streams", enabled, "Abort")

  choice <- NULL

  cat("\nSelect Silver stream to promote\n\n")
  for (i in seq_along(choices)) {
    cat(sprintf(" %d. %s\n", i, choices[[i]]))
  }
  cat("\n")

  k <- suppressWarnings(as.integer(readline("Enter number: ")))

  if (is.na(k) || k < 1 || k > length(choices)) {
    cli::cli_abort(
      "Invalid selection.",
      class = c("xpipe_silver_abort", "xpipe_silver_error", "xpipe_error")
    )
  }

  choice <- choices[[k]]

  if (identical(choice, "Abort")) {
    cli::cli_abort(
      "Silver promotion aborted by user.",
      class = c("xpipe_silver_abort", "xpipe_silver_error", "xpipe_error")
    )
  }

  if (identical(choice, "All enabled streams")) {
    return(enabled)
  }

  choice
}

#' Confirm Silver promotion
#'
#' @param confirm Logical.
#' @keywords internal
#' @noRd
.confirm_silver_promotion <- function(confirm = interactive()) {
  checkmate::assert_flag(confirm)

  if (!isTRUE(confirm)) {
    return(invisible(TRUE))
  }

  answer <- readline("Proceed with Silver promotion? [Y/N]: ")
  if (!nzchar(answer) || tolower(substr(answer, 1, 1)) != "y") {
    cli::cli_abort(
      "Silver promotion aborted by user.",
      class = c("xpipe_silver_abort", "xpipe_silver_error", "xpipe_error")
    )
  }

  invisible(TRUE)
}
