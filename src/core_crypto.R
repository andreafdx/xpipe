# ======================================================================= #
# FILE: src/fnc/crypto.R
#
# Pseudonymization and Privacy Rules
# ======================================================================= #

box::use(
  openssl[sha256],
  purrr[map_chr],
  cli[cli_abort, cli_alert_warning, cli_alert_info, cli_alert_success, cli_inform],
  dplyr[mutate, across, all_of, select]
)

#' HMAC-SHA256 Hash for PHI
#'
#' @param text Character vector.
#' @param pepper Character scalar.
#' @return Character vector of hashes.
#' @keywords internal
hash_phi <- function(text, pepper) {
  if (missing(pepper) || is.null(pepper) || pepper == "") {
    cli_abort("Missing key for hashing.")
  }

  pepper_raw <- charToRaw(pepper)

  map_chr(text, function(x) {
    if (is.na(x) || x == "") return(NA_character_)
    x_clean <- toupper(trimws(as.character(x)))
    as.character(sha256(charToRaw(x_clean), key = pepper_raw))
  })
}

#' Pseudonymize Columns
#'
#' Pseudonymize Columns
#'
#' @noRd
.pseudonymize_cols <- function(df, cols, pepper) {
  existing <- intersect(cols, names(df))
  if (length(existing) == 0) return(df)

  cli_inform("Pseudonymizing columns: {paste(existing, collapse = ', ')}")

  mutate(df, across(all_of(existing), ~ hash_phi(.x, pepper)))
}

#' Apply Stream Privacy Rules
#'
#' @param df Data frame to process.
#' @param stream_config List containing stream rules (pseudonymize, skip).
#' @param pepper Security pepper.
#' @return Processed data frame.
#' @export
apply_privacy_rules <- function(df, stream_config, pepper) {
  cli_alert_info("Applying privacy rules for stream: {.val {stream_config$stream_id}}")

  # 1. Pseudonymization
  if (!is.null(stream_config$pseudonymize)) {
    df <- .pseudonymize_cols(df, stream_config$pseudonymize, pepper)
  }

  # 2. Skip Columns
  if (!is.null(stream_config$skip)) {
    existing_skip <- intersect(stream_config$skip, names(df))
    if (length(existing_skip) > 0) {
      cli_inform("Removing skipped columns: {paste(existing_skip, collapse = ', ')}")
      df <- select(df, -all_of(existing_skip))
    }
  }

  cli_alert_success("Privacy rules applied successfully.")
  return(df)
}
