# ======================================================================= #
# FILE: src/functions/core/crypto.R
# DESCRIZIONE: Pseudonimizzazione deterministica (HMAC-SHA256)
# ======================================================================= #

box::use(
  openssl[sha256],
  purrr[map_chr],
  cli[cli_abort, cli_alert_warning],
  dplyr[mutate, across, all_of, select, everything]
)


# Hash per Protected Health Information -----------------------------------

#' Genera Hash pseudonimizzato deterministico (HMAC-SHA256)
#' Funziona sia su singoli valori che su vettori (es. colonne in mutate)
#' @param text Stringa o vettore di stringhe (es. Codice Fiscale)
#' @param pepper Character. La chiave segreta HMAC, iniettata esplicitamente.
#' @return Vettore di stringhe esadecimali (gli hash)
#' @export
.hash_phi <- function(text, pepper) {

  if (missing(pepper) || is.null(pepper) || pepper == "") {
    cli_abort(
      "Parametro {.arg pepper} mancante o vuoto. La chiave deve essere passata esplicitamente.",
      class = "crypto"
    )
  }

  pepper_raw <- charToRaw(pepper)

  map_chr(text, function(x) {
    if (is.na(x) || x == "") return(NA_character_)
    x_clean <- toupper(trimws(x))
    as.character(sha256(charToRaw(x_clean), key = pepper_raw))
  })
}


# Verifica l'integrità della chiave di criptazione ------------------------

#' Verifica l'integrità e la coerenza della chiave di crittografia (Pepper) del team
#' @param test_string Stringa di test dal file di configurazione
#' @param expected_hash L'hash noto corretto dal file di configurazione
#' @param pepper Character. La chiave segreta HMAC.
#' @return TRUE se la chiave è corretta, FALSE altrimenti
#' @export
.verify_pepper <- function(test_string, expected_hash, pepper) {
  current_hash <- .hash_phi(test_string, pepper)

  return(current_hash == expected_hash)
}


# Pseudonimizza le colonne selezionate ------------------------------------

.pseudonymize_cols <- function(df, cols, pepper) {

  existing <- intersect(cols, names(df))

  if (length(existing) == 0) {
    cli::cli_alert_warning("Nessuna colonna da pseudonimizzare")
    return(df)
  }

  cli::cli_inform("Psudonimizzo le colonne: {paste(existing, collapse = ', ')}")

  df |>
    dplyr::mutate(
      dplyr::across(
        dplyr::all_of(existing),
        ~ .hash_phi(.x, pepper)
      )
    )
}



# Rimuovi Nome e Cognome dalla tabella principale ------------------------


.remove_nome_cognome <- function(df) {

  drop_cols <- intersect(
    c("v_Nome", "v_Cognome"),
    names(df)
  )

  if (length(drop_cols) == 0) {
    cli::cli_warning("No nome/cognome da rimuovere")
    return(df)
  }

  cli::cli_inform(
    "Rimuovo le colonne: {paste(drop_cols, collapse = ', ')}"
  )

  dplyr::select(df, -dplyr::all_of(drop_cols))
}



# Applica tutte le regole di privacy all'elenco dei dataframe -------------

.apply_privacy <- function(dfs, pepper) {

  cli::cli_alert_info("Applico le regole di privacy")

  if ("TblScheda" %in% names(dfs)) {
    cli::cli_inform("TblScheda in lavorazione")

    dfs$TblScheda <- dfs$TblScheda |>
      .pseudonymize_cols(
        cols = c("c_CodicePaziente", "c_CodiceMadre"),
        pepper = pepper
      ) |>
      .remove_nome_cognome()
  }

  if ("TblSchedaProcedure" %in% names(dfs)) {
    cli::cli_inform("TblSchedaProcedure in lavorazione")

    dfs$TblSchedaProcedure <- dfs$TblSchedaProcedure |>
      .pseudonymize_cols(
        cols = c(
          "c_Chirurgo1",
          "c_Chirurgo2",
          "c_Chirurgo3",
          "c_Anestesista"
        ),
        pepper = pepper
      )
  }

  cli::cli_alert_success("Tutte le regole di privacy applicate")

  return(dfs)
}




