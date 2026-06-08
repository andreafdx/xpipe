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
# Internals: .promote_to_silver_current(), .silver_exec(), .silver_query(),
#            .resolve_silver_canonical_method(), .normalize_silver_as_of(),
#            .is_silver_up_to_date(), .confirm_silver_promotion(),
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~


# Error Class Taxonomy ----------------------------------------------------



# Public API --------------------------------------------------------------

#' Promote data to Silver
#'
#' Uses silver.json to resolve canonical methods and build Silver-current tables.
#' Harmonized phase is intentionally not implemented in this branch.
#'
#' @param config xpipe_config.
#' @param stream Optional stream id. If NULL, promotes all enabled streams in silver.json.
#' @param phase Character. Only "current" is supported.
#' @param dry_run Logical. If TRUE, prints what would be done.
#' @param confirm Logical. Ask for confirmation before writing.
#' @param as_of Optional ingestion snapshot timestamp. If provided, Silver-current
#'   is rebuilt using only Bronze rows with `__batch_created_at <= as_of`.
#'   This is an ingestion-time snapshot, it does not have domain temporal meaning.
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
    stream = stream
  )

  if (length(targets) == 0) {
    cli::cli_inform("No Silver-current streams enabled.")
    return(invisible(TRUE))
  }

  # Dry Run block

  if (isTRUE(dry_run)) {
    for (sid in targets) {
      mid <- .resolve_silver_canonical_method(sid, config)

      if (is.null(as_of)) {
        cli::cli_inform(
          "Would promote Silver-current for stream {.val {sid}} using method {.val {mid}}."
        )
      } else {
        cli::cli_inform(
          "Would promote Silver-current for stream {.val {sid}} using method {.val {mid}} as of ingestion snapshot {.val {as_of}}."
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


#' SDO Silver-harmonized profile (stub)
#'
#' Code-driven harmonization profile for the SDO stream.
#' In WP3 this is a no-op stub: no enrichment or transformation is applied.
#' Future versions will add SDO-specific enrichments (e.g. diagnoses, procedures).
#'
#' @param con DuckDB connection to the Silver database.
#' @param stream_id Stream identifier.
#' @param method_id Canonical method identifier.
#' @param config xpipe_config object.
#'
#' @return Invisibly TRUE.
#' @keywords internal
.silver_profile_sdo_harmonized_v1 <- function(con, stream_id, method_id, config) {

  ricovero <- "harmonized__ricovero"
  diagnosi <- "harmonized__diagnosi"

  # Add Diagnosi principale as a column to ricovero
  diag_principale_sql <- "
    SELECT
      codice_istituto_di_cura,
      progressivo_sdo,
      diagnosi_dimissione AS diagnosi_principale
    FROM harmonized__diagnosi
    WHERE tipo_diagnosi = 'principale'
  "

  # Add Diagnosi secondarie as a list column to ricovero, ordered by num_diagnosi
  diag_secondarie_sql <- "
    SELECT
      codice_istituto_di_cura,
      progressivo_sdo,
      LIST(diagnosi_dimissione ORDER BY num_diagnosi) AS diagnosi_secondarie
    FROM harmonized__diagnosi
    WHERE tipo_diagnosi <> 'principale'
    GROUP BY codice_istituto_di_cura, progressivo_sdo
  "


  # Add all diagnosis in Tutte le diagnosi (principale + secondarie) to ricovero as a list column, ordered by num_diagnosi
  tutte_diagnosi_sql <- "
    SELECT
      codice_istituto_di_cura,
      progressivo_sdo,
      LIST(diagnosi_dimissione ORDER BY num_diagnosi) AS tutte_le_diagnosi
    FROM harmonized__diagnosi
    GROUP BY codice_istituto_di_cura, progressivo_sdo
  "

  # Add Procedura principale as a column to ricovero
  proc_principale_sql <- "
    SELECT
      codice_istituto_di_cura,
      progressivo_sdo,
      intervento AS procedura_principale
    FROM harmonized__procedure
    WHERE tipo_intervento = 'principale'
  "

  # Add all procedure in Tutte le procedure to ricovero as a list column, ordered by num_intervento
  tutte_procedure_sql <- "
    SELECT
      codice_istituto_di_cura,
      progressivo_sdo,
      LIST(intervento ORDER BY num_intervento) AS tutte_le_procedure
    FROM harmonized__procedure
    GROUP BY codice_istituto_di_cura, progressivo_sdo
  "

  # Add identificativo_paziente from anagrafica to ricovero
  id_paziente_sql <- "
    SELECT
      codice_istituto_di_cura,
      progressivo_sdo,
      identificativo_paziente AS identificativo_paziente
    FROM harmonized__anagrafica
  "

  # Final rebuild ricovero
  sql <- paste0(
    "CREATE OR REPLACE TABLE harmonized__ricovero AS
     SELECT
       r.*,
       dp.diagnosi_principale,
       ds.diagnosi_secondarie,
       td.tutte_le_diagnosi,
       pp.procedura_principale,
       tp.tutte_le_procedure,
       a.identificativo_paziente
     FROM ", ricovero, " r
     LEFT JOIN (", diag_principale_sql, ") dp
       ON r.codice_istituto_di_cura = dp.codice_istituto_di_cura
      AND r.progressivo_sdo = dp.progressivo_sdo
     LEFT JOIN (", diag_secondarie_sql, ") ds
       ON r.codice_istituto_di_cura = ds.codice_istituto_di_cura
      AND r.progressivo_sdo = ds.progressivo_sdo
     LEFT JOIN (", tutte_diagnosi_sql, ") td
       ON r.codice_istituto_di_cura = td.codice_istituto_di_cura
      AND r.progressivo_sdo = td.progressivo_sdo
     LEFT JOIN (", proc_principale_sql, ") pp
       ON r.codice_istituto_di_cura = pp.codice_istituto_di_cura
      AND r.progressivo_sdo = pp.progressivo_sdo
     LEFT JOIN (", tutte_procedure_sql, ") tp
       ON r.codice_istituto_di_cura = tp.codice_istituto_di_cura
      AND r.progressivo_sdo = tp.progressivo_sdo
     LEFT JOIN (", id_paziente_sql, ") a
       ON r.codice_istituto_di_cura = a.codice_istituto_di_cura
      AND r.progressivo_sdo = a.progressivo_sdo"
  )



  DBI::dbExecute(con, sql)


  invisible(TRUE)
}


#' Silver-harmonized profile registry
#'
#' Internal registry mapping harmonization profile identifiers
#' (as declared in silver.json) to code-driven profile functions.
.silver_harmonized_profile_registry <- list(
  sdo_harmonized_v1 = .silver_profile_sdo_harmonized_v1
)

# Helpers -----------------------------------------------------------------


#' Execute a Silver SQL statement and always clear the result
#'
#' @param con DBI connection.
#' @param sql SQL statement.
#' @param params Optional query parameters.
#'
#' @return Invisibly returns rows affected.
#' @keywords internal
.silver_exec <- function(con, sql, params = NULL) {
  res <- NULL
  on.exit({
    if (!is.null(res)) try(DBI::dbClearResult(res), silent = TRUE)
  }, add = TRUE)

  res <- DBI::dbSendStatement(con, sql, params = params)
  invisible(DBI::dbGetRowsAffected(res))
}

#' Run a Silver SQL query and always clear the result
#'
#' @param con DBI connection.
#' @param sql SQL query.
#' @param params Optional query parameters.
#'
#' @return A data.frame.
#' @keywords internal
.silver_query <- function(con, sql, params = NULL) {
  res <- NULL
  on.exit({
    if (!is.null(res)) try(DBI::dbClearResult(res), silent = TRUE)
  }, add = TRUE)

  res <- DBI::dbSendQuery(con, sql, params = params)
  DBI::dbFetch(res)
}


.select_silver_promotion_targets <- function(config, stream = NULL) {
  checkmate::assert_class(config, "xpipe_config")
  checkmate::assert_string(stream, null.ok = TRUE)

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

  enabled <- silver_streams[vapply(
    silver_streams,
    function(sid) isTRUE(config$silver[[sid]]$current$enabled),
    logical(1)
  )]

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

    if (!isTRUE(config$silver[[stream]]$current$enabled)) {
      cli::cli_abort(
        c(
          "Silver-current disabled",
          "x" = "Silver-current is disabled for stream {.val {stream}}"
        ),
        class = c("xpipe_config_error", "xpipe_error")
      )
    }

    return(stream)
  }

  if (length(enabled) == 0) {
    return(character(0))
  }

  # Non-interactive: preserve pipeline behavior.
  # stream = NULL means all enabled streams.
  if (!interactive()) {
    return(enabled)
  }

  choices <- c("All enabled streams", enabled, "Abort")

  choice <- NULL
  if (requireNamespace("climenu", quietly = TRUE)) {
    choice <- tryCatch(
      climenu::select(
        choices,
        prompt = "Select Silver stream to promote"
      ),
      error = function(e) NULL
    )
  }

  if (is.null(choice)) {
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
  }

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


.normalize_silver_as_of <- function(as_of = NULL) {
  if (is.null(as_of)) return(NULL)

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
    class = c("xpipe_silver_config", "xpipe_error")
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
.assert_current_as_of_compatible <- function(con, stream_id, as_of) {
  # If no snapshot requested, any current state is acceptable.
  if (is.null(as_of)) return(invisible(TRUE))

  # If __silver_log doesn't exist, we cannot prove compatibility.
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
      AND phase = 'current'
    ORDER BY built_at DESC
    LIMIT 1
    ",
    params = list(stream_id)
  )

  if (nrow(cur) == 0) {
    cli::cli_abort(
      c(
        "Cannot verify Silver-current snapshot compatibility",
        "x" = "No Silver-current build found in __silver_log",
        "i" = "Run {.code promote_to_silver(stream = stream_id, phase = 'current', as_of = as_of)} first"
      ),
      class = c("xpipe_silver_error", "xpipe_error")
    )
  }

  current_as_of <- cur$as_of[[1]]
  # In your log writer, NULL is stored as NA_character_. Normalize that to NULL-like.
  if (is.na(current_as_of)) current_as_of <- NULL

  if (!identical(current_as_of, as_of)) {
    cli::cli_abort(
      c(
        "Silver-current snapshot mismatch",
        "x" = "Requested as_of = {.val {as_of}} but latest Silver-current build is as_of = {.val {current_as_of %||% 'latest'}}",
        "i" = "Rebuild Silver-current with the same snapshot, or run phase = 'all'"
      ),
      class = c("xpipe_silver_error", "xpipe_error")
    )
  }

  invisible(TRUE)
}



# Resolve canonical method for Silver-current
# @noRd
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

.is_silver_up_to_date <- function(con, stream_id, method_id, anchor_tbl, as_of = NULL) {

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

  latest_bronze <- .silver_query(
    con,
    paste0(
      "SELECT __batch_id AS batch_id
       FROM ", bronze_anchor,
      where_sql, "
       ORDER BY __batch_created_at DESC, __batch_id DESC
       LIMIT 1"
    )
  )

  latest_bronze <- if (nrow(latest_bronze) == 0) {
    NA_character_
  } else {
    latest_bronze$batch_id[[1]]
  }

  current_anchor <- paste0("current__", anchor_tbl)

  silver_latest <- if (current_anchor %in% DBI::dbListTables(con)) {
    out <- .silver_query(
      con,
      paste0(
        "SELECT __batch_id AS batch_id
         FROM ", DBI::dbQuoteIdentifier(con, current_anchor), "
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
.promote_single_harmonized_table <- function(
    con,
    source_table,
    target_table,
    column_map
) {
  # column_map: named list new_name -> old_name

  # 1. build rename expressions
  rename_sql <- character(0)

  if (length(column_map)) {
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
  }

  # 2. final SQL:
  #    - SELECT * passthrough
  #    - explicit renames override names
  sql <- paste0(
    "CREATE OR REPLACE TABLE ",
    DBI::dbQuoteIdentifier(con, target_table),
    " AS SELECT ",
    paste(c(rename_sql, "*"), collapse = ", "),
    " FROM ",
    DBI::dbQuoteIdentifier(con, source_table)
  )

  DBI::dbExecute(con, sql)
}


#' Apply harmonized enrichments (stub)
#'
#' Placeholder for future Silver-harmonized enrichments.
#' In WP3 this function is a no-op.
#'
#' @param con DuckDB connection.
#' @param stream_id Stream identifier.
#' @param method_id Canonical method identifier.
#' @param table_name Harmonized table name.
#'
#' @return Invisibly TRUE.
#' @keywords internal
.apply_harmonized_enrichments <- function(
    con,
    stream_id,
    method_id,
    table_name
) {
  # WP4+
  # no-op for now
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
.promote_all_harmonized_tables <- function(con, stream_id, config) {
  hcfg <- config$silver[[stream_id]]$harmonized
  tables <- hcfg$tables

  for (tbl_name in names(tables)) {
    src <- tables[[tbl_name]]$source
    colmap <- tables[[tbl_name]]$columns %||% list()

    source_table <- paste0("current__", src)
    target_table <- paste0("harmonized__", tbl_name)

    .promote_single_harmonized_table(
      con = con,
      source_table = source_table,
      target_table = target_table,
      column_map = colmap
    )

    .apply_harmonized_enrichments(
      con = con,
      stream_id = stream_id,
      method_id = config$silver[[stream_id]]$canonical_method,
      table_name = tbl_name
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
#' @param method_id Character scalar. Method identifier.
#' @param config xpipe_config.
#'
#' @return Invisibly TRUE on success.
#' @keywords internal
.promote_to_silver_current <- function(stream_id, config, as_of = NULL) {

  # 1. Preconditions

  checkmate::assert_string(stream_id)
  checkmate::assert_class(config, "xpipe_config")
  as_of <- .normalize_silver_as_of(as_of)

  method_id <- .resolve_silver_canonical_method(stream_id, config)

  bronze_root <- config$local$paths$bronze
  silver_root <- config$local$paths$silver

  if (!checkmate::test_string(bronze_root, min.chars = 1) ||
      !checkmate::test_string(silver_root, min.chars = 1)) {
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

  if (!checkmate::test_string(anchor_tbl, min.chars = 1) ||
      !checkmate::test_character(keys, min.len = 1)) {
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

  on.exit({
    try(.silver_exec(con_s, "DETACH bronze"), silent = TRUE)
    DBI::dbDisconnect(con_s, shutdown = TRUE)
  }, add = TRUE)

  try(.silver_exec(con_s, "DETACH bronze"), silent = TRUE)

  .silver_exec(
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

  bronze_tables <- .silver_query(
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
      class = c("xpipe_silver_anchor", "xpipe_error")
    )
  }

  current_anchor <- paste0("current__", anchor_tbl)

  key_cols <- DBI::dbQuoteIdentifier(con_s, keys)
  keys_sql <- paste(key_cols, collapse = ", ")

  bronze_anchor <- paste0(
    "bronze.main.",
    DBI::dbQuoteIdentifier(con_s, anchor_full)
  )

  # 4. Up-to-date check

  if (.is_silver_up_to_date(con_s, stream_id, method_id, anchor_tbl, as_of = as_of)) {

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
          stream_id, ". Rebuild anyway? [y/N]: "
        )
      } else {
        paste0(
          "Silver-current is already up to date for stream ",
          stream_id, " as of ", as_of, ". Rebuild anyway? [y/N]: "
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
      .silver_exec(
        con_s,
        paste0(
          "CREATE OR REPLACE TABLE ",
          DBI::dbQuoteIdentifier(con_s, current_anchor), " AS
           SELECT * EXCLUDE (rn)
           FROM (
             SELECT
               a.*,
               ROW_NUMBER() OVER (
                 PARTITION BY ", keys_sql, "
                 ORDER BY __batch_created_at DESC, __batch_id DESC
               ) AS rn
             FROM ", bronze_anchor, " a
             ", anchor_where_sql, "
           ) t
           WHERE rn = 1"
        )
      )

      for (bt in method_tables) {
        short <- sub(prefix, "", bt, fixed = TRUE)
        if (identical(short, anchor_tbl)) next

        bronze_sec <- paste0(
          "bronze.main.",
          DBI::dbQuoteIdentifier(con_s, bt)
        )

        current_sec <- paste0("current__", short)

        join_keys <- paste(
          paste0(
            "s.", DBI::dbQuoteIdentifier(con_s, keys),
            " = a.", DBI::dbQuoteIdentifier(con_s, keys)
          ),
          collapse = " AND "
        )

        .silver_exec(
          con_s,
          paste0(
            "CREATE OR REPLACE TABLE ",
            DBI::dbQuoteIdentifier(con_s, current_sec), " AS
             SELECT s.*
             FROM ", bronze_sec, " s
             INNER JOIN ", DBI::dbQuoteIdentifier(con_s, current_anchor), " a
               ON ", join_keys, "
              AND s.__batch_id = a.__batch_id"
          )
        )
      }

      .write_silver_log(
        con = con_s,
        phase = "current",
        stream_id = stream_id,
        method_id = method_id,
        as_of = as_of,
        source_tables = paste0("bronze__", anchor_tbl),
        output_tables = paste0("current__", method_tables)
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
  stopifnot(fs::file_exists(silver_db))

  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = as.character(silver_db), read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = FALSE), add = TRUE)

  as_of <- .normalize_silver_as_of(as_of)
  .assert_current_as_of_compatible(con, stream_id, as_of)

  #  passthrough + renaming
  .promote_all_harmonized_tables(
    con = con,
    stream_id = stream_id,
    config = config
  )

  #  enrichment stub
  profile_fn(
    con,
    stream_id,
    s$canonical_method,
    config
  )

  # write silver log for harmonized
  .write_silver_log(
    con = con,
    phase = "harmonized",
    stream_id = stream_id,
    method_id = s$canonical_method,
    as_of = as_of,
    source_tables = paste0("current__", names(s$harmonized$tables)),
    output_tables = paste0("harmonized__", names(s$harmonized$tables))
  )

  invisible(TRUE)
}

## CLI ---------------------------------------------------------------------

#' Confirm Silver promotion
#'
#' @param confirm Logical.
#' @keywords internal
#' @noRd
.confirm_silver_promotion <- function(confirm = interactive()) {
  checkmate::assert_flag(confirm)

  if (!isTRUE(confirm)) return(invisible(TRUE))

  # Try climenu first, fall back cleanly if unsupported
  if (requireNamespace("climenu", quietly = TRUE) && interactive()) {
    choice <- tryCatch(
      climenu::select(
        c("Yes, continue", "No, abort"),
        prompt = "Proceed with Silver promotion?"
      ),
      error = function(e) NULL
    )
    if (!is.null(choice)) {
      if (choice != "Yes, continue") {
        cli::cli_abort(
          "Silver promotion aborted by user.",
          class = c("xpipe_silver_abort", "xpipe_silver_error", "xpipe_error")
        )
      }
      return(invisible(TRUE))
    }
  }

  answer <- readline("Proceed with Silver promotion? [y/N]: ")
  if (!nzchar(answer) || tolower(substr(answer, 1, 1)) != "y") {
    cli::cli_abort(
      "Silver promotion aborted by user.",
      class = c("xpipe_silver_abort", "xpipe_silver_error", "xpipe_error")
    )
  }

  invisible(TRUE)
}

