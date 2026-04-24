

# Layer inspection --------------------------------------------------------


## Helpers ----------------------------------------------------------------

#' Inspect the Batch layer
#'
#' Scans the local Batch layer directory and returns a structured
#' representation of all discovered batches and their metadata.
#'
#' Incomplete batches (missing `_batch_metadata.json`) are recorded
#' but marked as such and excluded from detailed inspection.
#'
#' @param config An \code{xpipe_config} object.
#'
#' @return An object of class \code{"xpipe_batch_layer"} containing:
#' \itemize{
#'   \item \code{root} – batch layer root path
#'   \item \code{count} – number of batch directories found
#'   \item \code{batches} – named list of batch metadata
#' }
#'
#' @keywords internal
#' @noRd
inspect_batch_layer <- function(config) {
  if (!inherits(config, "xpipe_config")) {
    cli::cli_abort(
      "{.arg config} must be a valid xpipe_config",
      class = c("batch_layer", "config")
    )
  }

  batch_root <- config$local$paths$batch

  if (!fs::dir_exists(batch_root)) {
    cli::cli_abort(
      "Batch layer directory does not exist: {.file {batch_root}}",
      class = c("batch_layer", "paths")
    )
  }

  batch_dirs <- fs::dir_ls(
    batch_root,
    type = "directory",
    recurse = FALSE
  )

  # Defensive: remove empty directory names
  batch_dirs <- batch_dirs[nzchar(basename(batch_dirs))]

  ids <- basename(batch_dirs)
  metadata_files <- fs::path(batch_dirs, "_batch_metadata.json")
  has_meta <- fs::file_exists(metadata_files)

  batches <- vector("list", length(ids))
  names(batches) <- ids

  for (i in seq_along(ids)) {
    if (!has_meta[i]) {
      batches[[i]] <- list(.status = "incomplete")
      next
    }

    batches[[i]] <- jsonlite::fromJSON(
      metadata_files[i],
      simplifyVector = TRUE
    )
  }

  structure(
    list(
      root    = batch_root,
      count   = length(ids),
      batches = batches
    ),
    class = "xpipe_batch_layer"
  )
}


#' Format execution timestamps for display
#'
#' Converts ISO‑8601 or SQL‑style timestamps to a compact,
#' human‑readable \code{YYYY‑MM‑DD HH:MM} format.
#'
#' @param x Character vector of datetime strings.
#'
#' @return Character vector of formatted datetimes.
#'
#' @keywords internal
#' @noRd
.format_datetime <- function(x) {
  format(
    as.POSIXct(
      x,
      tryFormats = c(
        "%Y-%m-%dT%H:%M:%S%z",
        "%Y-%m-%d %H:%M:%S"
      )
    ),
    "%Y-%m-%d %H:%M"
  )
}


## S3 Print Method ----------------------------------------------------------

#' @export
print.xpipe_batch_layer <- function(x, ...) {

  cli::cli_div(
    theme = list(
      rule = list(color = "cyan", "line-type" = "double")
    )
  )

  cli::cli_rule("Batch Layer", right = "xpipe")

  cli::cli_bullets(c(
    "Path        : {.file {x$root}}",
    "Batch count : {.val {x$count}}"
  ))

  if (x$count == 0) {
    cli::cli_alert_info("No batches found.")
    return(invisible(x))
  }

  # Filter valid batches
  metas <- x$batches
  metas <- metas[!vapply(
    metas,
    function(m) isTRUE(m$.status == "incomplete"),
    logical(1)
  )]

  created <- vapply(
    metas,
    function(m) as.POSIXct(m$execution$created_at, tz = "UTC"),
    as.POSIXct(NA)
  )

  latest_id <- names(which.max(created))
  latest    <- metas[[latest_id]]


  # Latest batch
  cli::cli_h2("Latest Batch")
  cli::cli_text("{.strong {latest_id}}")

  cli::cli_bullets(c(
    paste0(
      "Stream       : ",
      latest$stream$id,
      " [", latest$stream$schema_domain, "]"
    ),
    paste0(
      "Method       : ",
      latest$method$id,
      " [", latest$method$type, "]"
    ),
    paste0("Input        : ", latest$input$path),
    paste0("Created at   : ", latest$execution$created_at),
    paste0(
      "Producer     : ",
      latest$execution$tool,
      " ",
      latest$execution$tool_version
    )
  ))

  # Components
  if (!is.null(latest$components)) {
    cli::cli_text("Components")

    items <- purrr::imap_chr(
      latest$components,
      ~ paste0(.x)
    )

    cli::cli_ul(items)
  }


  # Other batches
  others <- metas[names(metas) != latest_id]

  if (length(others) > 0) {
    cli::cli_h2("Other batches")

    by_stream <- split(
      others,
      vapply(others, function(m) m$stream$id, character(1))
    )

    for (stream_id in names(by_stream)) {
      cli::cli_h3("{stream_id} stream")

      items <- vapply(
        names(by_stream[[stream_id]]),
        function(batch_id) {
          m <- by_stream[[stream_id]][[batch_id]]
          paste(
            batch_id,
            "|",
            m$method$id,
            "|",
            .format_datetime(m$execution$created_at)
          )
        },
        character(1)
      )

      cli::cli_ul(items)
    }
  }

  cli::cli_rule()
  cli::cli_end()

  invisible(x)
}
