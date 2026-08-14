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


# Quality Contracts --------------------------------------------------------

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
    "batch_id",
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
    "value_num",
    "value_text",
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
