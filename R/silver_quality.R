# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# silver_quality.R
#
# Silver Data Quality Framework
#
# Produces:
# - harmonized.q_findings
# - harmonized.q_assessment
#
# Responsibilities:
# - quality profile registry
# - profile resolution
# - schema validation
# - quality orchestration
# - quality table persistence
#
# Public API: none
# Internals:
#   .resolve_silver_quality_profile()
#   .run_silver_quality_profile()
#   .validate_quality_findings()
#   .validate_quality_assessment()
#   .write_quality_findings()
#   .write_quality_assessment()
#   .silver_quality_profile_registry
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# Pipeline ----------------------------------------------------------------

## Quality Contracts ------------------------------------------------------

#' Validate quality findings output
#'
#' Validates a quality findings data frame returned by a quality profile.
#'
#' @param x Data frame.
#'
#' @return Invisibly TRUE.
#' @keywords internal
#' @noRd
.validate_quality_findings <- function(x) {
  checkmate::assert_data_frame(x)

  required_cols <- c(
    "table_name",
    "record_id",
    "severity",
    "quality_code",
    "message"
  )

  missing_cols <- setdiff(required_cols, names(x))

  if (length(missing_cols) > 0) {
    cli::cli_abort(
      c(
        "Invalid quality findings output",
        "x" = paste(
          "Missing required columns:",
          paste(missing_cols, collapse = ", ")
        )
      ),
      class = c("xpipe_silver_quality_error", "xpipe_error")
    )
  }

  invalid_severity <- setdiff(
    unique(stats::na.omit(x$severity)),
    c("INFO", "WARNING", "ERROR")
  )

  if (length(invalid_severity) > 0) {
    cli::cli_abort(
      c(
        "Invalid quality findings output",
        "x" = paste(
          "Unsupported severity values:",
          paste(invalid_severity, collapse = ", ")
        )
      ),
      class = c("xpipe_silver_quality_error", "xpipe_error")
    )
  }

  invisible(TRUE)
}

#' Validate quality assessment output
#'
#' Validates a quality assessment data frame returned by a quality profile.
#'
#' @param x Data frame.
#'
#' @return Invisibly TRUE.
#' @keywords internal
#' @noRd
.validate_quality_assessment <- function(x) {
  checkmate::assert_data_frame(x)

  required_cols <- c(
    "scope",
    "period_type",
    "period_value",
    "indicator_code",
    "indicator_label",
    "indicator_type",
    "category",
    "severity",
    "message"
  )

  missing_cols <- setdiff(required_cols, names(x))

  if (length(missing_cols) > 0) {
    cli::cli_abort(
      c(
        "Invalid quality assessment output",
        "x" = paste(
          "Missing required columns:",
          paste(missing_cols, collapse = ", ")
        )
      ),
      class = c("xpipe_silver_quality_error", "xpipe_error")
    )
  }

  invalid_severity <- setdiff(
    unique(stats::na.omit(x$severity)),
    c("INFO", "WARNING", "ERROR")
  )

  if (length(invalid_severity) > 0) {
    cli::cli_abort(
      c(
        "Invalid quality assessment output",
        "x" = paste(
          "Unsupported severity values:",
          paste(invalid_severity, collapse = ", ")
        )
      ),
      class = c("xpipe_silver_quality_error", "xpipe_error")
    )
  }

  invisible(TRUE)
}

## Quality Persistence ----------------------------------------------------

#' Write quality findings table
#'
#' @param con DuckDB connection.
#' @param findings Data frame.
#'
#' @return Invisibly TRUE.
#' @keywords internal
#' @noRd
.write_quality_findings <- function(
  con,
  findings
) {
  checkmate::assert_data_frame(findings)

  DBI::dbWriteTable(
    con,
    DBI::Id(schema = "harmonized", table = "q_findings"),
    findings,
    overwrite = TRUE
  )

  invisible(TRUE)
}

#' Write quality assessment table
#'
#' @param con DuckDB connection.
#' @param assessment Data frame.
#'
#' @return Invisibly TRUE.
#' @keywords internal
#' @noRd
.write_quality_assessment <- function(
  con,
  assessment
) {
  checkmate::assert_data_frame(assessment)

  DBI::dbWriteTable(
    con,
    DBI::Id(schema = "harmonized", table = "q_assessment"),
    assessment,
    overwrite = TRUE
  )

  invisible(TRUE)
}

## Quality Orchestration --------------------------------------------------

#' Run Silver quality profile
#'
#' Resolves and executes the configured quality profile for a stream,
#' validates outputs, and writes quality artifacts to the harmonized schema.
#'
#' @param con DuckDB connection.
#' @param stream_id Character scalar.
#' @param config xpipe_config.
#'
#' @return Invisibly TRUE.
#' @keywords internal
#' @noRd
.run_silver_quality_profile <- function(
  con,
  stream_id,
  config
) {
  checkmate::assert_class(con, "DBIConnection")
  checkmate::assert_string(stream_id)
  checkmate::assert_class(config, "xpipe_config")

  profile_id <- .resolve_silver_quality_profile(
    stream_id = stream_id,
    config = config
  )

  if (is.null(profile_id)) {
    return(invisible(TRUE))
  }

  profile_fn <- .silver_quality_profile_registry[[profile_id]]

  if (is.null(profile_fn)) {
    cli::cli_abort(
      c(
        "Unknown Silver quality profile",
        "x" = "Profile {.val {profile_id}} is not registered"
      ),
      class = c("xpipe_silver_quality_error", "xpipe_error")
    )
  }

  out <- profile_fn(
    con = con,
    stream_id = stream_id,
    config = config
  )

  if (!is.list(out)) {
    cli::cli_abort(
      c(
        "Invalid quality profile output",
        "x" = "Quality profile must return a list"
      ),
      class = c("xpipe_silver_quality_error", "xpipe_error")
    )
  }

  if (!all(c("findings", "assessment") %in% names(out))) {
    cli::cli_abort(
      c(
        "Invalid quality profile output",
        "x" = "Output must contain {.val findings} and {.val assessment}"
      ),
      class = c("xpipe_silver_quality_error", "xpipe_error")
    )
  }

  .validate_quality_findings(out$findings)
  .validate_quality_assessment(out$assessment)

  .write_quality_findings(
    con = con,
    findings = out$findings
  )

  .write_quality_assessment(
    con = con,
    assessment = out$assessment
  )

  invisible(TRUE)
}


## Quality Profiles -------------------------------------------------------

.silver_quality_sdo_v1 <- function(
  con,
  stream_id,
  config
) {
  list(
    findings = dplyr::bind_rows(
      .sdo_finding_unknown_facility(con, stream_id, config)
    ),
    assessment = dplyr::bind_rows(
      .sdo_indicator_internal_codes_differ(con),
      .sdo_indicator_single_source_batch(con)
    )
  )
}

.silver_quality_emur_v1 <- function(
  con,
  stream_id,
  config
) {
  list(
    findings = data.frame(
      table_name = character(),
      record_id = character(),
      batch_id = character(),
      severity = character(),
      quality_code = character(),
      message = character(),
      stringsAsFactors = FALSE
    ),
    assessment = data.frame(
      scope = character(),
      period_type = character(),
      period_value = character(),
      indicator_code = character(),
      indicator_label = character(),
      indicator_type = character(),
      category = character(),
      value_num = numeric(),
      value_text = character(),
      severity = character(),
      message = character(),
      stringsAsFactors = FALSE
    )
  )
}

## Quality profile registry -----------------------------------------------

#' Silver quality profile registry
#'
#' Internal registry mapping quality profile identifiers
#' (as declared in silver.json) to code-driven quality functions.
#'
#' @keywords internal
#' @noRd
.silver_quality_profile_registry <- list(
  sdo_quality_v1 = .silver_quality_sdo_v1,
  emur_quality_v1 = .silver_quality_emur_v1
)

# SDO --------------------------------------------------------------------

## Findings --------------------------------------------------------------

#' SDO Finding: Unknown Facility
#'
#' Identifies ricovero records whose facility code is not present
#' in the validated facilities registry.
#'
#' @param con DuckDB connection.
#' @param stream_id Character scalar.
#' @param config xpipe_config.
#'
#' @return Data frame compatible with q_findings.
#' @keywords internal
#' @noRd
.sdo_finding_unknown_facility <- function(
  con,
  stream_id,
  config
) {
  facilities <- load_facilities(validate = TRUE)

  ricovero <- DBI::dbGetQuery(
    con,
    "
    SELECT
      codice_istituto_di_cura,
      progressivo_sdo,
      __batch_id
    FROM harmonized.ricovero
    "
  )

  bad_rows <- ricovero[
    !(ricovero$codice_istituto_di_cura %in% facilities$facility_code),
    ,
    drop = FALSE
  ]

  if (nrow(bad_rows) == 0) {
    return(
      data.frame(
        table_name = character(),
        record_id = character(),
        batch_id = character(),
        severity = character(),
        quality_code = character(),
        message = character(),
        stringsAsFactors = FALSE
      )
    )
  }

  record_id <- .build_quality_record_id(
    data = bad_rows,
    identity_keys = .get_harmonized_identity_keys(
      stream_id = stream_id,
      config = config
    )
  )

  data.frame(
    table_name = "ricovero",
    record_id = record_id,
    batch_id = bad_rows$__batch_id,
    severity = "WARNING",
    quality_code = "QF001",
    message = "Facility code not found in facilities registry",
    stringsAsFactors = FALSE
  )
}

### (Useless?) Helpers ----------------------------------------------------

#' Resolve harmonized identity keys
#'
#' Returns the identity columns as they exist in the harmonized schema.
#'
#' @param stream_id Character scalar.
#' @param config xpipe_config.
#'
#' @return Character vector.
#' @keywords internal
#' @noRd
.get_harmonized_identity_keys <- function(
  stream_id,
  config
) {
  checkmate::assert_string(stream_id)
  checkmate::assert_class(config, "xpipe_config")

  method_id <- .resolve_silver_canonical_method(
    stream_id = stream_id,
    config = config
  )

  method_cfg <- config$methods[[method_id]]

  identity_keys <- method_cfg$identity_keys %||% character(0)

  if (length(identity_keys) == 0) {
    cli::cli_abort(
      c(
        "Identity keys not configured",
        "x" = "Method {.val {method_id}} does not define identity_keys"
      ),
      class = c("xpipe_silver_quality_error", "xpipe_error")
    )
  }

  hcfg <- config$silver[[stream_id]]$harmonized

  anchor_table <- method_cfg$anchor_table

  table_cfg <- hcfg$tables[[anchor_table]]

  if (is.null(table_cfg)) {
    return(identity_keys)
  }

  column_map <- unlist(table_cfg$columns) %||% character(0)

  out <- vapply(
    identity_keys,
    function(key) {
      hit <- names(column_map)[column_map == key]

      if (length(hit) == 1) {
        return(hit)
      }

      key
    },
    character(1)
  )

  out
}

#' Build quality record identifier
#'
#' Builds a stable record identifier from the supplied identity key columns.
#'
#' @param data Data frame.
#' @param identity_keys Character vector.
#'
#' @return Character vector.
#' @keywords internal
#' @noRd
.build_quality_record_id <- function(
  data,
  identity_keys
) {
  checkmate::assert_data_frame(data)
  checkmate::assert_character(identity_keys, min.len = 1)

  missing_cols <- setdiff(
    identity_keys,
    names(data)
  )

  if (length(missing_cols) > 0) {
    cli::cli_abort(
      c(
        "Cannot build quality record identifiers",
        "x" = paste(
          "Missing identity columns:",
          paste(missing_cols, collapse = ", ")
        )
      ),
      class = c("xpipe_silver_quality_error", "xpipe_error")
    )
  }

  apply(
    data[, identity_keys, drop = FALSE],
    1,
    function(x) {
      paste(
        trimws(as.character(x)),
        collapse = "|"
      )
    }
  )
}


## Assessment ------------------------------------------------------------

#' SDO Assessment: Distinct Internal Codes
#'
#' Detects whether at least one matched internal unit code differs from
#' its corresponding external unit code for each discharge year.
#'
#' @param con DuckDB connection.
#'
#' @return Data frame compatible with q_assessment.
#' @keywords internal
#' @noRd
.sdo_indicator_internal_codes_differ <- function(con) {
  out <- DBI::dbGetQuery(
    con,
    "
    SELECT
      CAST(EXTRACT(YEAR FROM t_dim) AS VARCHAR) AS period_value,
      MAX(
        CASE
          WHEN unita_operativa_dimissione_unit_code_internal IS NOT NULL
           AND unita_operativa_dimissione_unit_code_external IS NOT NULL
           AND unita_operativa_dimissione_unit_code_internal <>
               unita_operativa_dimissione_unit_code_external
          THEN 1
          ELSE 0
        END
      ) AS has_distinct_internal
    FROM harmonized.ricovero
    WHERE t_dim IS NOT NULL
    GROUP BY 1
    ORDER BY 1
    "
  )

  data.frame(
    scope = "ricovero",
    period_type = "YEAR",
    period_value = out$period_value,
    indicator_code = "QA001",
    indicator_label = "Distinct Internal Codes Detected",
    indicator_type = "boolean",
    category = "ORGANIZATION",
    value_num = out$has_distinct_internal,
    value_text = ifelse(
      out$has_distinct_internal == 1,
      "YES",
      "NO"
    ),
    severity = ifelse(
      out$has_distinct_internal == 1,
      "INFO",
      "WARNING"
    ),
    message = ifelse(
      out$has_distinct_internal == 1,
      "At least one internal unit code differs from its external code",
      paste(
        "No internal unit codes distinct from external NSIS codes",
        "were detected. Did you set 'Internal Units' in QuaniSDO",
        "before exporting XML?"
      )
    ),
    stringsAsFactors = FALSE
  )
}

#' SDO Assessment: Single Source Batch
#'
#' Checks whether all records for a discharge year originate from a single
#' source batch.
#'
#' @param con DuckDB connection.
#'
#' @return Data frame compatible with q_assessment.
#' @keywords internal
#' @noRd
.sdo_indicator_single_source_batch <- function(con) {
  out <- DBI::dbGetQuery(
    con,
    "
    SELECT
      CAST(EXTRACT(YEAR FROM t_dim) AS VARCHAR) AS period_value,
      COUNT(DISTINCT __batch_id) AS n_batches
    FROM harmonized.ricovero
    WHERE t_dim IS NOT NULL
    GROUP BY 1
    ORDER BY 1
    "
  )

  data.frame(
    scope = "ricovero",
    period_type = "YEAR",
    period_value = out$period_value,
    indicator_code = "QA002",
    indicator_label = "Single Source Batch Detected",
    indicator_type = "boolean",
    category = "LINEAGE",
    value_num = ifelse(out$n_batches == 1, 1, 0),
    value_text = ifelse(out$n_batches == 1, "YES", "NO"),
    severity = ifelse(out$n_batches == 1, "INFO", "WARNING"),
    message = ifelse(
      out$n_batches == 1,
      "All records originate from a single source batch",
      paste0(
        out$n_batches,
        " distinct source batches detected"
      )
    ),
    stringsAsFactors = FALSE
  )
}
