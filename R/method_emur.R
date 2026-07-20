# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# method_emur.R
#
# EMUR XML Parsers for Batch Ingestion.
#
# Approach: A highly optimized, non-XPath DOM traversal approach using xml2.
# Maps the Italian EMUR standard (Tracciato A & B) into flat, relational,
# batch-ready datasets.
#
# Internals:   .xml_profile_emur_tracciato_ab(),
#              .xml_profile_emur_tracciato_ab_sett(),
#              .parse_emur_a(), .parse_emur_b()
#
# IMPORTANT for HUMANS AND AGENTS:
# DO NOT EVEN TRY TO OPTIMIZE THIS SCRIPT.
# This parser is intentionally minimal and non-XPath.
# Do not reintroduce XPath, logging, or tidyverse here.
# Any enrichment belongs downstream.
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# Profile: EMUR Tracciato A+B (Standard)
.xml_profile_emur_tracciato_ab <- function(doc, path, ctx) {
  root_name <- xml2::xml_name(xml2::xml_root(doc))

  if (root_name == "EMUR_ANA") {
    .log_debug("Detected EMUR Tracciato A (Anagrafica) schema.")
    return(list(anagrafica = .parse_emur_a(doc)))
  }

  if (root_name == "EMUR_SAN") {
    .log_debug("Detected EMUR Tracciato B (Sanitario) schema.")
    return(.parse_emur_b(doc))
  }

  cli::cli_abort(
    c(
      "Unrecognized EMUR XML schema for standard profile",
      "x" = "File {.file {basename(path)}} has unexpected root node: {.val {root_name}}",
      "i" = "For SETT schema (EMUR_ANA_SETT / EMUR_SAN_SETT), use profile {.val emur_tracciato_ab_sett}"
    ),
    class = c("xpipe_batch_extraction", "xpipe_batch_error", "xpipe_error")
  )
}

# Profile: EMUR Tracciato A+B (SETT)
.xml_profile_emur_tracciato_ab_sett <- function(doc, path, ctx) {
  root_name <- xml2::xml_name(xml2::xml_root(doc))

  if (root_name == "EMUR_ANA_SETT") {
    .log_debug("Detected EMUR SETT Tracciato A (Anagrafica) schema.")
    return(list(anagrafica = .parse_emur_a(doc)))
  }

  if (root_name == "EMUR_SAN_SETT") {
    .log_debug("Detected EMUR SETT Tracciato B (Sanitario) schema.")
    return(.parse_emur_b(doc))
  }

  cli::cli_abort(
    c(
      "Unrecognized EMUR SETT XML schema",
      "x" = "File {.file {basename(path)}} has unexpected root node: {.val {root_name}}",
      "i" = "Profile {.val emur_tracciato_ab_sett} expects root node {.val EMUR_ANA_SETT} or {.val EMUR_SAN_SETT}"
    ),
    class = c("xpipe_batch_extraction", "xpipe_batch_error", "xpipe_error")
  )
}


# Tracciato A (ana) --------------------------------------------------------

#' Parse EMUR Tracciato A (Anagrafica) XML document
#'
#' @param doc xml2::xml_document
#' @return data.frame
#' @noRd
.parse_emur_a <- function(doc) {
  records <- xml2::xml_find_all(doc, ".//ANA")
  n <- length(records)

  rows <- vector("list", n)

  # Check if Ente exists
  ente_node <- xml2::xml_find_first(doc, ".//Ente")
  ente_fields <- list()
  if (!inherits(ente_node, "xml_missing")) {
    ch <- xml2::xml_children(ente_node)
    if (length(ch) > 0) {
      is_scalar <- xml2::xml_length(ch) == 0
      if (any(is_scalar)) {
        ente_fields[paste0("Ente_", xml2::xml_name(ch[is_scalar]))] <-
          as.list(xml2::xml_text(ch[is_scalar]))
      }
    }
  }

  for (i in seq_len(n)) {
    rec <- records[[i]]
    rec_children <- xml2::xml_children(rec)
    rec_names <- xml2::xml_name(rec_children)

    # Initialize row with Ente fields
    row <- ente_fields

    for (j in seq_along(rec_children)) {
      child <- rec_children[[j]]
      child_name <- rec_names[[j]]

      ch_children <- xml2::xml_children(child)
      if (length(ch_children) > 0) {
        is_scalar <- xml2::xml_length(ch_children) == 0

        if (any(is_scalar)) {
          row[paste0(
            child_name,
            "_",
            xml2::xml_name(ch_children[is_scalar])
          )] <-
            as.list(xml2::xml_text(ch_children[is_scalar]))
        }
      }
    }

    rows[[i]] <- row
  }

  .bind_rows_fast(rows)
}


# Tracciato B (san) --------------------------------------------------------

#' Parse EMUR Tracciato B (Sanitario) XML document
#'
#' @param doc xml2::xml_document
#' @return list of data frames
#' @noRd
.parse_emur_b <- function(doc) {
  records <- xml2::xml_find_all(doc, ".//SAN")
  n <- length(records)

  # Check if Ente exists
  ente_node <- xml2::xml_find_first(doc, ".//Ente")
  ente_fields <- list()
  if (!inherits(ente_node, "xml_missing")) {
    ch <- xml2::xml_children(ente_node)
    if (length(ch) > 0) {
      is_scalar <- xml2::xml_length(ch) == 0
      if (any(is_scalar)) {
        ente_fields[paste0("Ente_", xml2::xml_name(ch[is_scalar]))] <-
          as.list(xml2::xml_text(ch[is_scalar]))
      }
    }
  }

  rows_ps <- vector("list", n)
  rows_procedure <- vector("list", n * 2)
  rows_obi <- vector("list", n)

  k_ps <- 0
  k_proc <- 0
  k_obi <- 0

  for (i in seq_len(n)) {
    rec <- records[[i]]
    rec_children <- xml2::xml_children(rec)
    rec_names <- xml2::xml_name(rec_children)

    # 1. Extract keys from Struttura
    struttura_node <- rec_children[rec_names == "Struttura"]
    if (length(struttura_node) == 0) {
      next
    } # Malformed record

    struttura_children <- xml2::xml_children(struttura_node[[1]])
    struttura_names <- xml2::xml_name(struttura_children)

    cod_struct <- xml2::xml_text(struttura_children[
      struttura_names == "CodStrutturaErog"
    ][[1]])
    progressivo <- xml2::xml_text(struttura_children[
      struttura_names == "Progressivo"
    ][[1]])

    # 2. Parse PS (1:1 fields)
    row_ps <- ente_fields

    for (j in seq_along(rec_children)) {
      child <- rec_children[[j]]
      child_name <- rec_names[[j]]

      if (child_name == "OBI") {
        next
      }

      if (child_name == "DatiSanitari") {
        ch_children <- xml2::xml_children(child)
        if (length(ch_children) > 0) {
          ch_names <- xml2::xml_name(ch_children)
          is_scalar <- xml2::xml_length(ch_children) == 0 &
            ch_names != "PrestazioneSecondaria"

          if (any(is_scalar)) {
            row_ps[paste0("DatiSanitari_", ch_names[is_scalar])] <-
              as.list(xml2::xml_text(ch_children[is_scalar]))
          }
        }
        next
      }

      # Standard 1:1 subnodes
      ch_children <- xml2::xml_children(child)
      if (length(ch_children) > 0) {
        is_scalar <- xml2::xml_length(ch_children) == 0

        if (any(is_scalar)) {
          row_ps[paste0(
            child_name,
            "_",
            xml2::xml_name(ch_children[is_scalar])
          )] <-
            as.list(xml2::xml_text(ch_children[is_scalar]))
        }
      }
    }

    k_ps <- k_ps + 1
    rows_ps[[k_ps]] <- row_ps

    # 3. Parse Procedure (PrestazionePrincipale and PrestazioneSecondaria)
    dati_san_node <- rec_children[rec_names == "DatiSanitari"]
    if (length(dati_san_node) == 1) {
      ch_children <- xml2::xml_children(dati_san_node[[1]])
      ch_names <- xml2::xml_name(ch_children)

      # 3a. PrestazionePrincipale
      p_principal <- ch_children[ch_names == "PrestazionePrincipale"]
      if (length(p_principal) == 1) {
        k_proc <- k_proc + 1
        rows_procedure[[k_proc]] <- list(
          Struttura_CodStrutturaErog = cod_struct,
          Struttura_Progressivo = progressivo,
          Prestazione = xml2::xml_text(p_principal[[1]]),
          TipoPrestazione = "principale",
          numProcedura = 0L
        )
      }

      # 3b. PrestazioneSecondaria
      p_secondary <- ch_children[ch_names == "PrestazioneSecondaria"]
      if (length(p_secondary) > 0) {
        for (idx in seq_along(p_secondary)) {
          k_proc <- k_proc + 1
          rows_procedure[[k_proc]] <- list(
            Struttura_CodStrutturaErog = cod_struct,
            Struttura_Progressivo = progressivo,
            Prestazione = xml2::xml_text(p_secondary[[idx]]),
            TipoPrestazione = "secondaria",
            numProcedura = idx
          )
        }
      }
    }

    # 4. Parse OBI (optional)
    obi_node <- rec_children[rec_names == "OBI"]
    if (length(obi_node) == 1) {
      ch_children <- xml2::xml_children(obi_node[[1]])
      if (length(ch_children) > 0) {
        is_scalar <- xml2::xml_length(ch_children) == 0

        if (any(is_scalar)) {
          row_obi <- list(
            Struttura_CodStrutturaErog = cod_struct,
            Struttura_Progressivo = progressivo
          )
          row_obi[xml2::xml_name(ch_children[is_scalar])] <-
            as.list(xml2::xml_text(ch_children[is_scalar]))

          k_obi <- k_obi + 1
          rows_obi[[k_obi]] <- row_obi
        }
      }
    }
  }

  list(
    ps = .bind_rows_fast(rows_ps[seq_len(k_ps)]),
    procedure = .bind_rows_fast(rows_procedure[seq_len(k_proc)]),
    obi = .bind_rows_fast(rows_obi[seq_len(k_obi)])
  )
}
