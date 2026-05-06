test_that(".make_key creates composite keys correctly", {
  df <- data.frame(
    id = c(1, 2),
    sub_id = c("A", "B"),
    stringsAsFactors = FALSE
  )

  keys <- .make_key(df, c("id", "sub_id"))
  expect_equal(keys, c("1\rA", "2\rB"))
})

test_that(".validate_anchor_definitions passes valid config", {
  valid_config <- structure(
    list(
      methods = list(
        test_method = list(
          anchor_table = "main_table",
          partition_column = "date_col",
          identity_keys = c("id_1", "id_2")
        )
      )
    ),
    class = "xpipe_config"
  )

  # Should run silently and return TRUE invisibly
  expect_invisible(.validate_anchor_definitions(valid_config, "test_method"))
})

test_that(".validate_anchor_definitions catches missing anchor_table", {
  invalid_config <- structure(
    list(
      methods = list(
        test_method = list(
          partition_column = "date_col",
          identity_keys = "id_1"
          # anchor_table is missing
        )
      )
    ),
    class = "xpipe_config"
  )

  expect_error(
    .validate_anchor_definitions(invalid_config, "test_method"),
    class = "xpipe_bronze_anchor"
  )
})

test_that(".validate_anchor_definitions catches missing identity_keys", {
  invalid_config <- structure(
    list(
      methods = list(
        test_method = list(
          anchor_table = "main_table",
          partition_column = "date_col"
          # identity_keys is missing
        )
      )
    ),
    class = "xpipe_config"
  )

  expect_error(
    .validate_anchor_definitions(invalid_config, "test_method"),
    class = "xpipe_bronze_anchor"
  )
})
