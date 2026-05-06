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
#' @param table_name Character scalar. Table name used in progress messages.
#' @param method_config Named list containing privacy rule fields
#'   (`pseudonymize`, `skip`) as defined in the methods contract.
#' @param pepper Character scalar. HMAC key loaded from the environment
#'   via [load_xpipe_config()]. Must be non-empty.
#'
#' @return The input data frame with privacy rules applied.
#'
#' @seealso [hash_phi()] for the underlying hashing primitive.
#' @noRd
apply_privacy_rules <- function(df, table_name, method_config, pepper) {
  checkmate::assert_data_frame(df)
  checkmate::assert_string(table_name)
  checkmate::assert_list(method_config)
  checkmate::assert_string(pepper, min.chars = 1)

  if (nrow(df) == 0) return(df)

  existing_pseudo <- character(0)
  existing_skip   <- character(0)

  if (!is.null(method_config$pseudonymize)) {
    existing_pseudo <- intersect(method_config$pseudonymize, names(df))
  }

  if (!is.null(method_config$skip)) {
    existing_skip <- intersect(method_config$skip, names(df))
  }

  if (length(existing_pseudo) > 0 || length(existing_skip) > 0) {

    cli::cli_inform("Applying privacy to {table_name}")

    if (length(existing_pseudo) > 0) {
      df <- .pseudonymize_cols(df, existing_pseudo, pepper)
      .log_debug("Pseudonymized: {paste(existing_pseudo, collapse = ', ')}")
    }

    if (length(existing_skip) > 0) {
      df <- dplyr::select(df, -dplyr::all_of(existing_skip))
      # Visible only if local.json has level: "debug"
      .log_debug("Dropped: {paste(existing_skip, collapse = ', ')}")
    }
  }

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
#' @export
#' @keywords internal
hash_phi <- function(text, pepper) {
  if (!checkmate::test_string(pepper, min.chars = 1)) {
    cli::cli_abort(
      "Hashing key (pepper) is missing or empty.",
      class = c("xpipe_runtime_pepper", "xpipe_runtime_error", "xpipe_error")
    )
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
  rlang::check_required(df)
  checkmate::assert_character(cols, min.len = 1)
  checkmate::assert_string(pepper)

  existing <- intersect(cols, names(df))
  if (length(existing) == 0) return(df)
  dplyr::mutate(df, dplyr::across(dplyr::all_of(existing), ~ hash_phi(.x, pepper)))
}
