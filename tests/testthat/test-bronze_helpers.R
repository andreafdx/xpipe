test_that(".make_key creates composite keys correctly", {
  df <- data.frame(
    id = c(1, 2),
    sub_id = c("A", "B"),
    stringsAsFactors = FALSE
  )

  # Since .make_key is internal, we use the triple colon or rely on load_all()
  # load_all() exposes internals to testthat automatically.
  keys <- .make_key(df, c("id", "sub_id"))
  expect_equal(keys, c("1\rA", "2\rB"))
})

test_that(".validate_anchor_definitions passes valid config", {
  valid_config <- list(
    methods = list(
      test_method = list(
        anchor_table = "main_table",
        partition_column = "date_col",
        identity_keys = c("id_1", "id_2")
      )
    )
  )

  # Should run silently and return TRUE invisibly
  expect_invisible(.validate_anchor_definitions(valid_config, "test_method"))
})

test_that(".validate_anchor_definitions catches missing attributes", {
  invalid_config <- list(
    methods = list(
      test_method = list(
        partition_column = "date_col",
        identity_keys = "id_1"
        # missing anchor_table
      )
    )
  )

  expect_error(
    .validate_anchor_definitions(invalid_config, "test_method"),
    class = "bronze"
  )
})
