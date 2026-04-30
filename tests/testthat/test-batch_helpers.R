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

test_that(".normalize_or_generate_batch_id catches invalid explicit ids", {
  expect_error(
    .normalize_or_generate_batch_id("s", "m", ""),
    class = "batch"
  )
  expect_error(
    .normalize_or_generate_batch_id("s", "m", character(0)),
    class = "batch"
  )
})
