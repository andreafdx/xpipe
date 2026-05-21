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
#' Applies method-level privacy rules to a data frame produced during Batch
#' extraction, before Parquet writing.
#'
#' - `privacy$skip`: drops declared columns (supports `scalar` and `list`)
#' - `privacy$hash`: pseudonymizes declared columns using HMAC-SHA256
#'      (supports `scalar` and `list`, list-columns are hashed element-wise)
#'    The declared shape (`scalar` vs `list`) is authoritative; mismatches abort.
#'
#' Hashing is deterministic (same input + pepper = same hash) and
#' case/whitespace-insensitive, allowing downstream joins without exposing raw
#' identifiers. The pepper is never stored on disk.
#'
#' @param df Data frame to process.
#' @param table_name Character scalar. Name of the extracted table.
#' @param method_config Named list that may contain a `privacy` block.
#'   If `privacy` is absent, the function is a no-op and returns `df` unchanged.
#' @param pepper Character scalar. HMAC key loaded from the environment via
#'   [load_xpipe_config()]. Must be non-empty.
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

  if (is.null(method_config$privacy)) {
    return(df)
  }

  privacy <- method_config$privacy

  .assert_shape <- function(x, shape, tbl, col, action) {
    if (identical(shape, "scalar") && is.list(x)) {
      cli::cli_abort(
        c(
          "Privacy rule shape mismatch",
          "x" = "Column {.val {tbl}.{col}} is a list-column but declared as scalar ({.val {action}})"
        ),
        class = c("xpipe_privacy", "xpipe_batch_error", "xpipe_error")
      )
    }
    if (identical(shape, "list") && !is.list(x)) {
      cli::cli_abort(
        c(
          "Privacy rule shape mismatch",
          "x" = "Column {.val {tbl}.{col}} is scalar but declared as list ({.val {action}})"
        ),
        class = c("xpipe_privacy", "xpipe_batch_error", "xpipe_error")
      )
    }
    if (!identical(shape, "scalar") && !identical(shape, "list")) {
      cli::cli_abort(
        c(
          "Invalid privacy rule",
          "x" = "Unsupported privacy shape {.val {shape}} for {.val {tbl}.{col}}"
        ),
        class = c("xpipe_privacy", "xpipe_batch_error", "xpipe_error")
      )
    }
    invisible(TRUE)
  }

  # 1) SKIP
  skip_spec <- privacy$skip %||% list()
  skip_tbl  <- skip_spec[[table_name]] %||% NULL
  if (!is.null(skip_tbl) && length(skip_tbl) > 0) {
    cols <- intersect(names(skip_tbl), names(df))
    for (col in cols) .assert_shape(df[[col]], skip_tbl[[col]], table_name, col, "skip")
    if (length(cols) > 0) df[cols] <- NULL
  }

  # 2) HASH
  hash_spec <- privacy$hash %||% list()
  hash_tbl  <- hash_spec[[table_name]] %||% NULL
  if (!is.null(hash_tbl) && length(hash_tbl) > 0) {
    cols <- intersect(names(hash_tbl), names(df))
    for (col in cols) {
      shape <- hash_tbl[[col]]
      x <- df[[col]]
      .assert_shape(x, shape, table_name, col, "hash")
      if (identical(shape, "scalar")) {
        df[[col]] <- hash_phi(as.character(x), pepper)
      } else {
        df[[col]] <- lapply(x, function(v) {
          if (is.null(v)) return(NULL)
          if (length(v) == 0) return(character(0))
          hash_phi(as.character(v), pepper)
        })
      }
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
