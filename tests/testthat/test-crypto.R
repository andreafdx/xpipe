test_that("hash_phi hashes deterministically and ignores case/whitespace", {
  pepper <- "test_pepper_123"
  val1 <- hash_phi("John Doe", pepper)
  val2 <- hash_phi("JOHN DOE", pepper)
  val3 <- hash_phi("  John Doe  ", pepper)

  expect_type(val1, "character")
  expect_equal(val1, val2)
  expect_equal(val1, val3)
})

test_that("hash_phi handles NAs and empty strings", {
  pepper <- "test_pepper_123"
  expect_equal(hash_phi(NA_character_, pepper), NA_character_)
  expect_equal(hash_phi("", pepper), NA_character_)

  # Vectorized NA handling
  res <- hash_phi(c("A", NA, ""), pepper)
  expect_equal(is.na(res), c(FALSE, TRUE, TRUE))
})

test_that("hash_phi aborts on missing or empty pepper", {
  expect_error(
    hash_phi("John Doe", ""),
    class = "xpipe_runtime_pepper"
  )
  # Missing argument also fails the same guard
  expect_error(
    hash_phi("John Doe", NA_character_),
    class = "xpipe_runtime_pepper"
  )
})
