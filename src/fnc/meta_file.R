.generate_meta_file <- function(out_dir, tables, dfs) {

  # row counts
  row_counts <- vapply(dfs, nrow, integer(1))

  # extraction time
  extract_time <- format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z")

  # username (cross-platform)
  username <- Sys.info()[["user"]]

  # optional: specific table row count (safe)
  tblscheda_rows <- if ("TblScheda" %in% names(row_counts)) {
    row_counts[["TblScheda"]]
  } else {
    "N/A"
  }

  meta_lines <- c(
    paste0("Extraction datetime: ", extract_time),
    paste0("User: ", username),
    paste0(
      "Extracted tables (", length(tables), "): ",
      paste(tables, collapse = ", ")
    ),
    paste0("Rows in TblScheda: ", tblscheda_rows),
    "",
    "Row counts (all extracted tables):",
    paste0(names(row_counts), ": ", row_counts)
  )

  # write file
  meta_file <- file.path(out_dir, "extraction_meta.txt")
  writeLines(meta_lines, meta_file)

  cli::cli_alert_success(
    "Metadata file written: {.file {meta_file}}"
  )

  invisible(meta_lines)
}







.generate_meta_json <- function(out_dir, batch_id = NULL, dfs, extra = list()) {


  if (is.null(batch_id)) {
    batch_id <- paste0(
      "sdo_",
      format(Sys.time(), "%Y-%m-%dT%H-%M-%S")
    )
  }



  meta <- c(
    list(
      batch_id    = batch_id,
      import_time = format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z"),
      user        = Sys.info()[["user"]],
      tables      = names(dfs),
      row_counts  = vapply(dfs, nrow, integer(1))
    ),
    extra
  )

  meta_file <- file.path(out_dir, "batch_meta.json")

  jsonlite::write_json(
    meta,
    meta_file,
    pretty = TRUE,
    auto_unbox = TRUE
  )

  cli::cli_alert_success(
    "Batch metadata written: {.file {meta_file}}"
  )

  invisible(meta)
}


