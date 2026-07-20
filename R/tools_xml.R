# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# tools_xml.R
#
# XML Extraction Dispatcher and Shared Helpers for Batch Ingestion.
#
# Approach: Provides the profile-based dispatch mechanism for XML extraction
# and shared row-binding utilities used by all method-specific parsers.
# Method-specific parsers live in their own files (method_sdo.R, method_emur.R).
#
# Public API:  extract_xml()
# Internals:   .xml_profile_registry(), .bind_rows_safe(), .bind_rows_fast(),
#              .rbind_fill_dfs()
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# Profile registry  -------------------------------------------------

.xml_profile_registry <- function() {
  list(
    sdo_tracciato_abcd = .xml_profile_sdo_tracciato_abcd,
    emur_tracciato_ab = .xml_profile_emur_tracciato_ab,
    emur_tracciato_ab_sett = .xml_profile_emur_tracciato_ab_sett
  )
}

# Internal API ------------------------------------------------------------

#' Extract XML Data (Profile Dispatcher)
#' @export
#' @keywords internal
extract_xml <- function(ctx) {
  checkmate::assert_list(ctx)

  profile <- ctx$method_config$xml_profile %||% NA_character_
  if (!checkmate::test_string(profile, min.chars = 1)) {
    cli::cli_abort(
      c(
        "Invalid method configuration",
        "x" = "Missing {.field xml_profile} for XML method {.val {ctx$method_id}}"
      ),
      class = c("xpipe_batch_extraction", "xpipe_batch_error", "xpipe_error")
    )
  }

  parser <- .xml_profile_registry()[[profile]] %||% NULL
  if (is.null(parser) || !is.function(parser)) {
    cli::cli_abort(
      c(
        "Unknown XML profile",
        "x" = "No parser registered for profile {.val {profile}}",
        "i" = "Registered profiles: {.val {names(.xml_profile_registry())}}"
      ),
      class = c("xpipe_batch_extraction", "xpipe_batch_error", "xpipe_error")
    )
  }

  paths <- unique(as.character(unlist(ctx$resolved_inputs)))
  if (length(paths) == 0) {
    paths <- ctx$filepath
  }

  # accumulate per-table outputs across multiple XML files
  acc <- list()

  for (path in paths) {
    cli::cli_inform("Reading XML document: {.file {basename(path)}}")
    doc <- xml2::read_xml(path)

    res <- parser(doc, path, ctx)

    for (nm in names(res)) {
      if (is.null(acc[[nm]])) {
        acc[[nm]] <- res[[nm]]
      } else {
        acc[[nm]] <- .rbind_fill_dfs(list(acc[[nm]], res[[nm]]))
      }
    }
  }

  acc
}


# Helpers ----------------------------------------------------------------

#' Schema-safe row binder (base R)
#'
#' Binds a list of named lists into a data.frame, aligning schemas safely.
#' This is the *canonical* version: predictable, dependency-free, and correct.
#'
#' @param rows List of named lists (each list represents one row)
#' @return data.frame with aligned columns
#' @noRd
.bind_rows_safe <- function(rows) {
  if (length(rows) == 0) {
    return(data.frame())
  }

  all_names <- unique(unlist(lapply(rows, names)))
  rows <- lapply(rows, function(r) {
    missing <- setdiff(all_names, names(r))
    if (length(missing)) {
      r[missing] <- NA_character_
    }
    r[all_names]
  })

  as.data.frame(do.call(rbind, rows))
}

#' Fast row binder with optional data.table acceleration
#'
#' Uses data.table::rbindlist() when available for large batches,
#' otherwise falls back to `.bind_rows_safe()`.
#'
#' @param rows List of named lists
#' @return data.frame
#' @noRd
.bind_rows_fast <- function(rows) {
  if (!length(rows)) {
    return(data.frame())
  }

  if (requireNamespace("data.table", quietly = TRUE)) {
    return(as.data.frame(data.table::rbindlist(rows, fill = TRUE)))
  }

  .bind_rows_safe(rows)
}

# Bind data.frames preserving list-columns, aligning missing columns
.rbind_fill_dfs <- function(dfs) {
  dfs <- dfs[!vapply(dfs, is.null, logical(1))]
  if (length(dfs) == 0) {
    return(NULL)
  }
  if (length(dfs) == 1) {
    return(dfs[[1]])
  }

  all_cols <- unique(unlist(lapply(dfs, names)))
  dfs2 <- lapply(dfs, function(d) {
    missing <- setdiff(all_cols, names(d))
    if (length(missing) > 0) {
      for (m in missing) {
        d[[m]] <- NA
      }
    }
    d[all_cols]
  })
  do.call(rbind, dfs2)
}
