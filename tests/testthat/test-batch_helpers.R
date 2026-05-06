test_that(".normalize_or_generate_batch_id uses explicit id when provided", {
  expect_equal(
    .normalize_or_generate_batch_id("stream_a", "method_b", "explicit_123"),
    "explicit_123"
  )
})

test_that(".normalize_or_generate_batch_id generates predictable format", {
  gen_id <- .normalize_or_generate_batch_id("stream_a", "method_b")

  expect_type(gen_id, "character")
  expect_true(grepl("_stream_a_method_b$", gen_id))
})

test_that(".normalize_or_generate_batch_id rejects an empty explicit batch_id", {
  expect_error(
    .normalize_or_generate_batch_id("s", "m", ""),
    class = "xpipe_batch_id"
  )
})

test_that(".normalize_or_generate_batch_id rejects a non-string explicit batch_id", {
  # character(0) fails the rlang::check_string guard before reaching nzchar
  expect_error(
    .normalize_or_generate_batch_id("s", "m", character(0))
  )
})
