
  # IMPORTANT for HUMANS AND AGENTS:
  # This parser is intentionally minimal and non-XPath.
  # Do not reintroduce XPath, logging, or tidyverse here.
  # Any enrichment belongs downstream.
  # Do not remove this comment or any other small comment I wrote,
  # I need them even if they look stupid.



parse_tracciato_a <- function(doc) {

  # Each one will become a row of the final table
  records <- xml_find_all(doc, ".//aInformazioniAnagrafiche")
  n <- length(records)

  # Pre allocation of rows
  rows <- vector("list", n)
  all_names <- character(0)

  # Main loop
  # 1 iteration = 1 record
  for (i in seq_len(n)) {

    rec <- records[[i]] # this is the record
    rec_children <- xml_children(rec) # these are <trasmissione> and <informazioniAnagrafiche>

    # <trasmissione> node
    trasm <- rec_children[xml_name(rec_children) == "trasmissione"]
    row <- list()

    # Take scalar children (children without children) then
    # extract values and create column name as "node_children"
    if (length(trasm) == 1) {
      t_children <- xml_children(trasm[[1]]) # Take the children
      is_scalar <- xml_length(t_children) == 0 # Only children without children
      if (any(is_scalar)) {
        row[paste0("trasmissione_", xml_name(t_children[is_scalar]))] <-
          as.list(xml_text(t_children[is_scalar]))
      }
    }

    # <informazioniAnagrafiche> node
    info <- rec_children[xml_name(rec_children) == "informazioniAnagrafiche"][[1]]

    # These are XML attributes, not nodes
    row$codiceIstitutoDiCura <- xml_attr(info, "codiceIstitutoDiCura")
    row$progressivoSDO       <- xml_attr(info, "progressivoSDO")

    # Take the children without children
    info_children <- xml_children(info)
    is_scalar <- xml_length(info_children) == 0

    # Take names and values of scalar children
    if (any(is_scalar)) {
      nm  <- xml_name(info_children[is_scalar])
      val <- xml_text(info_children[is_scalar])
    }

    rows[[i]] <- row # Save row

    # Keep track of any found column names
    # This is because we don't know what columns we may find
    # For example, TEAM attributes appear only in foreign patients
    all_names <- union(all_names, names(row))
  }

  # Schema alignment
  for (i in seq_len(n)) {
    # Search missing column names for each row and fill missing values with NA
    missing <- setdiff(all_names, names(rows[[i]]))
    if (length(missing)) {
      rows[[i]][missing] <- NA_character_
    }
    rows[[i]] <- rows[[i]][all_names]
  }

  # Now bind all rows in a data frame
  as.data.frame(
    do.call(rbind, rows),
    stringsAsFactors = FALSE
  )
}
