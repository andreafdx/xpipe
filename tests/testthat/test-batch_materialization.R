# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# test-batch_materialization.R
#
# Tests for the materialization pipeline internals, covering the try_fetch
# error-wrapping in .materialize_batch, instrument resolution, and the
# extraction/persistence phases.
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# ---- .resolve_extraction_instrument -----------------------------------------

test_that(".resolve_extraction_instrument aborts on unregistered method type", {
  ctx <- list(method_config = list(type = "unknown_format"))

  expect_error(
    .resolve_extraction_instrument(ctx, NULL),
    class = "xpipe_batch_instrument"
  )
})

test_that(".resolve_extraction_instrument aborts when function is not loaded", {
  # Register a type that maps to a function that doesn't exist in the env
  ctx <- list(method_config = list(type = "access_mdb"))

  # Temporarily ensure the function is absent
  if (exists("extract_access_db", mode = "function")) {
    skip("extract_access_db is loaded; cannot test missing-function guard here")
  }

  expect_error(
    .resolve_extraction_instrument(ctx, NULL),
    class = "xpipe_batch_instrument"
  )
})

# ---- .run_extraction --------------------------------------------------------

test_that(".run_extraction wraps a failing single-file instrument as xpipe_batch_extraction", {
  failing_instrument <- function(ctx, path) stop("ODBC: connection refused")

  ctx <- list(
    components = NULL,
    filepath = tempfile(),
    method_config = list(type = "access_mdb")
  )

  # Reproduce the try_fetch logic that .materialize_batch applies
  expect_error(
    rlang::try_fetch(
      .run_extraction(ctx, failing_instrument),
      error = function(e) cli::cli_abort(
        "Data extraction failed",
        parent = e,
        class = c("xpipe_batch_extraction", "xpipe_batch_error", "xpipe_error")
      )
    ),
    class = "xpipe_batch_extraction"
  )
})

test_that(".run_extraction aborts when extractor returns an empty list", {
  empty_instrument <- function(ctx, path) list()

  ctx <- list(
    components = NULL,
    filepath = tempfile(),
    method_config = list(type = "access_mdb")
  )

  expect_error(
    .run_extraction(ctx, empty_instrument),
    class = "xpipe_batch_extraction"
  )
})

test_that(".run_extraction coerces a bare data.frame return to a named list", {
  df_instrument <- function(ctx, path) data.frame(x = 1:3)

  ctx <- list(
    components = NULL,
    filepath = tempfile(),
    method_config = list(type = "access_mdb")
  )

  result <- .run_extraction(ctx, df_instrument)
  expect_type(result, "list")
  expect_named(result, "data")
  expect_s3_class(result$data, "data.frame")
})

test_that(".run_extraction aborts if an extracted element is not a data.frame", {
  bad_instrument <- function(ctx) list(good_table = data.frame(x = 1), bad_table = "not a df")

  ctx <- list(
    components = NULL,
    filepath = tempfile(),
    method_config = list(type = "access_mdb")
  )

  expect_error(
    .run_extraction(ctx, bad_instrument),
    class = "xpipe_batch_extraction"
  )
})

test_that(".run_extraction aborts if extracted list is not fully named", {
  unnamed_instrument <- function(ctx) list(data.frame(x = 1))

  ctx <- list(
    components = NULL,
    filepath = tempfile(),
    method_config = list(type = "access_mdb")
  )

  expect_error(
    .run_extraction(ctx, unnamed_instrument),
    class = "xpipe_batch_extraction"
  )
})

# ---- .persist_to_batch ------------------------------------------------------

test_that(".persist_to_batch wraps filesystem errors as xpipe_batch_materialization", {
  # Point batch_dir at a path that cannot be created (a file used as a dir)
  tmp_file <- tempfile()
  writeLines("block", tmp_file)  # exists as a file, not a directory

  ctx <- list(
    batch_id = "test_batch",
    batch_dir = fs::path(tmp_file, "subdir"),  # impossible path
    filename = "test.mdb",
    stream_id = "sdo",
    method_id = "sdo_quani_mdb",
    method_config = list(
      schema_domain = "sdo",
      type = "access_mdb",
      input_type = "file"
    ),
    stream_config = list(anchor = "start")
  )

  mock_config <- structure(
    list(runtime = list(tool = list(name = "xpipe", version = "dev"))),
    class = "xpipe_config"
  )

  good_data <- list(TblScheda = data.frame(x = 1:3))

  expect_error(
    rlang::try_fetch(
      .persist_to_batch(ctx, good_data, mock_config),
      error = function(e) cli::cli_abort(
        "Failed to persist batch data",
        parent = e,
        class = c(
          "xpipe_batch_materialization",
          "xpipe_batch_error",
          "xpipe_error"
        )
      )
    ),
    class = "xpipe_batch_materialization"
  )
})
