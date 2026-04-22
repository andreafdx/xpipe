
  # IMPORTANT for HUMANS AND AGENTS:
  # This parser is intentionally minimal and non-XPath.
  # Do not reintroduce XPath, logging, or tidyverse here.
  # Any enrichment belongs downstream.
  # Do not remove this comment or any other small comment I wrote,
  # I need them even if they look stupid.


# Tracciato A -------------------------------------------------------------

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



# Tracciato B -------------------------------------------------------------
#
# Tracciato B – Minimal, non-XPath, Batch-correct parser
# Produces 4 tables:
#   - ricovero
#   - diagnosi
#   - procedure
#   - accessi_dh
#
# IMPORTANT:
# - No hashing
# - No privacy rules
# - No lineage
# - No clinical enrichment



## Helper B ---------------------------------------------------------------

parse_b_ricovero <- function(rec) {

  rec_children <- xml_children(rec)
  row <- list()

  # trasmissione (1-1, flatten)
  trasm <- rec_children[xml_name(rec_children) == "trasmissione"]
  if (length(trasm) == 1) {
    t_children <- xml_children(trasm[[1]])
    is_scalar <- xml_length(t_children) == 0
    if (any(is_scalar)) {
      row[paste0("trasmissione_", xml_name(t_children[is_scalar]))] <-
        as.list(xml_text(t_children[is_scalar]))
    }
  }

  # informazioniRicovero
  info <- rec_children[xml_name(rec_children) == "informazioniRicovero"][[1]]

  # attributi
  row[names(xml_attrs(info))] <- as.list(xml_attrs(info))

  # campi scalari diretti
  info_children <- xml_children(info)
  is_scalar <- xml_length(info_children) == 0
  if (any(is_scalar)) {
    row[xml_name(info_children[is_scalar])] <-
      as.list(xml_text(info_children[is_scalar]))
  }

  # dimissione (1-1, flatten con prefisso)
  dim_node <- info_children[xml_name(info_children) == "dimissione"]
  if (length(dim_node) == 1) {
    d_children <- xml_children(dim_node[[1]])
    is_scalar <- xml_length(d_children) == 0
    if (any(is_scalar)) {
      row[paste0("dim_", xml_name(d_children[is_scalar]))] <-
        as.list(xml_text(d_children[is_scalar]))
    }
  }

  # accessiInDH (1-1, as a list column)
  dh_nodes <- info_children[xml_name(info_children) == "AccessiInDH"]
  if (length(dh_nodes) == 1) {
    dates <- xml_children(dh_nodes[[1]])
    row$accessi_dh <- list(xml_text(dates))
  } else {
    row$accessi_dh <- list(character(0))
  }

  row
}


parse_b_diagnosi <- function(rec) {

  rec_children <- xml_children(rec)
  info <- rec_children[xml_name(rec_children) == "informazioniRicovero"][[1]]

  codice <- xml_attr(info, "codiceIstitutoDiCura")
  prog   <- xml_attr(info, "progressivoSDO")

  out <- list()

  # Diagnosi principale
  dp <- xml_children(info)[xml_name(xml_children(info)) == "diagnosiPrincipale"]
  if (length(dp) == 1) {
    dp_children <- xml_children(dp[[1]])
    is_scalar <- xml_length(dp_children) == 0
    if (any(is_scalar)) {
      row <- list(
        codiceIstitutoDiCura = codice,
        progressivoSDO       = prog,
        tipoDiagnosi         = "principale",
        numDiagnosi          = 0L
      )
      row[xml_name(dp_children[is_scalar])] <-
        as.list(xml_text(dp_children[is_scalar]))
      out[[length(out) + 1]] <- row
    }
  }

  # Diagnosi secondarie
  ds_nodes <- xml_children(info)[xml_name(xml_children(info)) == "diagnosiSecondarie"]
  if (length(ds_nodes) > 0) {
    for (ds in ds_nodes) {
      num <- suppressWarnings(as.integer(xml_attr(ds, "numDiagnosiSecondaria")))
      ds_children <- xml_children(ds)
      is_scalar <- xml_length(ds_children) == 0
      if (any(is_scalar)) {
        row <- list(
          codiceIstitutoDiCura = codice,
          progressivoSDO       = prog,
          tipoDiagnosi         = "secondaria",
          numDiagnosi          = num
        )
        row[xml_name(ds_children[is_scalar])] <-
          as.list(xml_text(ds_children[is_scalar]))
        out[[length(out) + 1]] <- row
      }
    }
  }

  out
}


parse_b_procedure <- function(rec) {

  rec_children <- xml_children(rec)
  info <- rec_children[xml_name(rec_children) == "informazioniRicovero"][[1]]

  codice <- xml_attr(info, "codiceIstitutoDiCura")
  prog   <- xml_attr(info, "progressivoSDO")

  out <- list()

  # funzione interna per estrarre una procedura
  extract_proc <- function(node, tipo, num) {
    children <- xml_children(node)
    is_scalar <- xml_length(children) == 0

    row <- list(
      codiceIstitutoDiCura = codice,
      progressivoSDO       = prog,
      tipoIntervento       = tipo,
      numIntervento        = num
    )

    # campi scalar (inclusi operatori)
    if (any(is_scalar)) {
      row[xml_name(children[is_scalar])] <-
        as.list(xml_text(children[is_scalar]))
    }

    row
  }

  # Intervento principale
  ip <- xml_children(info)[xml_name(xml_children(info)) == "interventoPrincipale"]
  if (length(ip) == 1) {
    out[[length(out) + 1]] <- extract_proc(ip[[1]], "principale", 0L)
  }

  # Interventi secondari
  isec <- xml_children(info)[xml_name(xml_children(info)) == "interventiSecondari"]
  if (length(isec) > 0) {
    for (sec in isec) {
      num <- suppressWarnings(as.integer(xml_attr(sec, "numInterventoSecondario")))
      out[[length(out) + 1]] <- extract_proc(sec, "secondario", num)
    }
  }

  out
}


# Main B ------------------------------------------------------------------


parse_tracciato_b <- function(doc) {

  records <- xml_find_all(doc, ".//bInformazioniRicovero")

  rows_ricovero   <- list()
  rows_diagnosi   <- list()
  rows_procedure  <- list()

  for (rec in records) {
    rows_ricovero   <- c(rows_ricovero,   list(parse_b_ricovero(rec)))
    rows_diagnosi   <- c(rows_diagnosi,   parse_b_diagnosi(rec))
    rows_procedure  <- c(rows_procedure,  parse_b_procedure(rec))
  }

  # helper di allineamento schema
  bind_rows_safe <- function(rows) {
    if (length(rows) == 0) return(data.frame())
    all_names <- unique(unlist(lapply(rows, names)))
    rows <- lapply(rows, function(r) {
      missing <- setdiff(all_names, names(r))
      if (length(missing)) {
        r[missing] <- NA_character_
        if ("accessi_dh" %in% missing) r$accessi_dh <- list(character(0))
      }
      r[all_names]
    })
    as.data.frame(do.call(rbind, rows), stringsAsFactors = FALSE)
  }

  list(
    ricovero   = bind_rows_safe(rows_ricovero),
    diagnosi   = bind_rows_safe(rows_diagnosi),
    procedure  = bind_rows_safe(rows_procedure)
  )
}
