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
