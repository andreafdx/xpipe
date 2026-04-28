# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# crypto.R
#
# Pseudonymization and privacy rule application.
#
# Approach: PHI columns are pseudonymized using HMAC-SHA256 with a runtime
# pepper loaded from the environment. The pepper is never stored on disk.
# Pseudonymization is deterministic (same input + pepper = same hash), which
# allows downstream joins without exposing raw identifiers.
#
# Public API:  apply_privacy_rules()
# Internal:    hash_phi(), .pseudonymize_cols()
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~


# Private API ------------------------------------------------------------------

#' Apply Privacy Rules to an Extracted Data Frame
#'
#' Applies method-level privacy rules to a data frame produced during batch
#' extraction. Two rule types are supported:
#'
#' - **Pseudonymization**: selected columns are replaced with HMAC-SHA256
#'   hashes, keyed by a runtime pepper. Hashing is deterministic and
#'   case/whitespace-insensitive.
#' - **Column removal**: columns listed under `skip` are dropped entirely
#'   before persistence.
#'
#' Rules are defined in `methods.json` and loaded as part of the method
#' configuration. This function is called by the batch materialization
#' pipeline and should not need to be invoked directly.
#'
#' @param df Data frame to process.
#' @param method_config Named list containing privacy rule fields
#'   (`pseudonymize`, `skip`) as defined in the methods contract.
#' @param pepper Character scalar. HMAC key loaded from the environment
#'   via [load_xpipe_config()]. Must be non-empty.
#'
#' @return The input data frame with privacy rules applied.
#'
#' @seealso [hash_phi()] for the underlying hashing primitive.
#' @keywords internal
apply_privacy_rules <- function(df, method_config, pepper) {
  cli::cli_alert_info("Applying privacy rules for method: {.val {method_config$type}}")

  if (!is.null(method_config$pseudonymize)) {
    df <- .pseudonymize_cols(df, method_config$pseudonymize, pepper)
  }

  if (!is.null(method_config$skip)) {
    existing_skip <- intersect(method_config$skip, names(df))
    if (length(existing_skip) > 0) {
      cli::cli_inform("Removing skipped columns: {paste(existing_skip, collapse = ', ')}")
      df <- dplyr::select(df, -dplyr::all_of(existing_skip))
    }
  }

  cli::cli_alert_success("Privacy rules applied successfully.")
  df
}



#' HMAC-SHA256 Hash for PHI
#'
#' Hashes a character vector using HMAC-SHA256 keyed by a runtime pepper.
#' Input is uppercased and stripped of leading/trailing whitespace before
#' hashing, making the operation case- and whitespace-insensitive.
#' `NA` and empty strings are returned as `NA_character_`.
#'
#' @param text Character vector of values to hash.
#' @param pepper Character scalar. HMAC key. Must be non-empty.
#'
#' @return Character vector of hex-encoded HMAC-SHA256 hashes,
#'   same length as `text`.
#'
#' @keywords internal
hash_phi <- function(text, pepper) {
  if (missing(pepper) || is.null(pepper) || pepper == "") {
    cli::cli_abort("Missing key for hashing.")
  }

  pepper_raw <- charToRaw(pepper)

  purrr::map_chr(text, function(x) {
    if (is.na(x) || x == "") return(NA_character_)
    x_clean <- toupper(trimws(as.character(x)))
    as.character(openssl::sha256(charToRaw(x_clean), key = pepper_raw))
  })
}

# Helpers ---------------------------------------------------------------------

#' Pseudonymize Selected Columns
#'
#' @param df Data frame.
#' @param cols Character vector of column names to pseudonymize.
#' @param pepper Character scalar. HMAC key.
#'
#' @return Data frame with selected columns replaced by HMAC-SHA256 hashes.
#'
#' @noRd
.pseudonymize_cols <- function(df, cols, pepper) {
  existing <- intersect(cols, names(df))
  if (length(existing) == 0) return(df)

  cli::cli_inform("Pseudonymizing columns: {paste(existing, collapse = ', ')}")
  dplyr::mutate(df, dplyr::across(dplyr::all_of(existing), ~ hash_phi(.x, pepper)))
}
