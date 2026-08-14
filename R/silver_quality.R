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
    findings = data.frame(
      table_name = character(),
      record_id = character(),
      batch_id = character(),
      severity = character(),
      quality_code = character(),
      message = character(),
      stringsAsFactors = FALSE
    ),
    assessment = dplyr::bind_rows(
      .sdo_indicator_internal_codes_differ(con)
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
  sdo_quality_v1 = .silver_quality_sdo_v1
)

# SDO --------------------------------------------------------------------

## Assessment ------------------------------------------------------------

#' SDO Assessment: Internal Codes Differ From External
#'
#' Detects whether at least one matched internal unit code differs from
#' its corresponding external unit code.
#'
#' @param con DuckDB connection.
#'
#' @return One-row data frame compatible with q_assessment.
#' @keywords internal
#' @noRd
.sdo_indicator_internal_codes_differ <- function(con) {
  has_distinct_internal <- DBI::dbGetQuery(
    con,
    "
    SELECT EXISTS (
      SELECT 1
      FROM harmonized.ricovero
      WHERE unita_operativa_dimissione_unit_code_internal IS NOT NULL
        AND unita_operativa_dimissione_unit_code_external IS NOT NULL
        AND unita_operativa_dimissione_unit_code_internal <>
            unita_operativa_dimissione_unit_code_external
    ) AS has_indicator
    "
  )$has_indicator[[1]]

  data.frame(
    scope = "ricovero",
    indicator_code = "QA001",
    indicator_label = "Distinct Internal Codes Detected",
    indicator_type = "boolean",
    category = "ORGANIZATION",
    value_num = if (isTRUE(has_distinct_internal)) 1 else 0,
    value_text = if (isTRUE(has_distinct_internal)) "YES" else "NO",
    severity = if (isTRUE(has_distinct_internal)) "INFO" else "WARNING",
    message = if (isTRUE(has_distinct_internal)) {
      "At least one internal unit code differs from its external code"
    } else {
      "No internal unit codes distinct from external NSIS codes were detected. Did you set 'Internal Units' before exporting XML?"
    },
    stringsAsFactors = FALSE
  )
}
