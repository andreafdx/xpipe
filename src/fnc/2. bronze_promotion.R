box::use(
  jsonlite,
  fs,
  cli
)

#' Get Bronze State
#'
#' Reads the state of the Bronze layer from `layer.json`.
#'
#' @param config xacc_config object.
#' @return A list with the current state.
#' @export
get_bronze_state <- function(config) {
  path <- fs$path(config$local$paths$bronze, "layer.json")
  
  if (!fs$file_exists(path)) {
    cli$cli_abort(
      c(
        "Bronze layer state not found",
        "x" = "File {.file {path}} does not exist"
      ),
      class = c("bronze_state", "file_not_found")
    )
  }
  
  tryCatch(
    jsonlite$fromJSON(path, simplifyVector = TRUE),
    error = function(e) {
      cli$cli_abort(
        c(
          "Failed to read Bronze layer state",
          "x" = "Invalid JSON syntax in {.file {path}}",
          "!" = e$message
        ),
        class = c("bronze_state", "json_error")
      )
    }
  )
}

#' Save Bronze State
#'
#' Writes the updated state of the Bronze layer back to `layer.json`.
#'
#' @param config xacc_config object.
#' @param state A list representing the updated state.
#' @export
save_bronze_state <- function(config, state) {
  path <- fs$path(config$local$paths$bronze, "layer.json")
  
  tryCatch(
    {
      json_content <- jsonlite$toJSON(state, auto_unbox = TRUE, pretty = TRUE)
      writeLines(as.character(json_content), path)
    },
    error = function(e) {
      cli$cli_abort(
        c(
          "Failed to save Bronze layer state",
          "x" = "Could not write to {.file {path}}",
          "!" = e$message
        ),
        class = c("bronze_state", "write_error")
      )
    }
  )
  
  invisible(TRUE)
}
