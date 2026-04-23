##---------------

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

  # Remove directories with empty names (defensive)
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
      root = batch_root,
      count = length(ids),
      batches = batches
    ),
    class = "xpipe_batch_layer"
  )
}

print.xpipe_batch_layer <- function(x, ...) {
  cli::cli_div(
    theme = list(rule = list(color = "cyan", "line-type" = "double"))
  )

  cli::cli_rule("xpipe Batch Layer")

  cli::cli_bullets(c(
    paste0("Path        : ", x$root),
    paste0("Batch count : ", x$count)
  ))

  if (x$count == 0) {
    cli::cli_alert_info("No batches found.")
    cli::cli_end()
    return(invisible(x))
  }

  cli::cli_h2("Batches")

  for (id in names(x$batches)) {
    meta <- x$batches[[id]]

    if (isTRUE(meta$.status == "incomplete")) {
      cli::cli_alert_warning(
        paste0("Batch ", id, " is incomplete (missing _batch_metadata.json)")
      )
      next
    }

    # Extract values explicitly (NO glue access to meta)
    stream_id   <- meta$stream$id
    domain      <- meta$stream$schema_domain
    method_id   <- meta$method$id
    method_type <- meta$method$type
    anchor      <- meta$stream$anchor
    input_path  <- meta$input$path
    created_at  <- meta$execution$created_at
    producer    <- paste(meta$execution$tool, meta$execution$tool_version)

    cli::cli_h3(id)

    cli::cli_bullets(c(
      paste0("Stream       : ", stream_id),
      paste0("Domain       : ", domain),
      paste0("Method       : ", method_id, " [", method_type, "]"),
      paste0("Anchor       : ", anchor),
      paste0("Input        : ", input_path),
      paste0("Created at   : ", created_at),
      paste0("Producer     : ", producer)
    ))

    if (!is.null(meta$components)) {
      cli::cli_text("  Components:")
      cli::cli_bullets(
        purrr::imap_chr(
          meta$components,
          ~ paste0("    ", .y, " → ", .x)
        )
      )
    }
  }

  cli::cli_rule()
  cli::cli_end()
  invisible(x)
}
