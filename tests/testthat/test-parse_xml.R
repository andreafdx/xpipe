# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# test-parse_xml.R
#
# Tests for the EMUR XML extractors and profile dispatching.
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

test_that(".parse_emur_a extracts correct columns and data", {
  xml_path <- testthat::test_path("fixtures/sample_emur_ana.xml")
  skip_if_not(file.exists(xml_path), "EMUR ANA sample XML file not found")

  doc <- xml2::read_xml(xml_path)
  res <- .parse_emur_a(doc)

  expect_s3_class(res, "data.frame")
  expect_gt(nrow(res), 0)

  # Check key columns
  expected_cols <- c(
    "Ente_CodRegione",
    "Struttura_Anno",
    "Struttura_CodStrutturaErog",
    "Struttura_Progressivo",
    "Assistito_CognomeAssistito",
    "Assistito_NomeAssistito",
    "Assistito_CodFiscaleAssistito"
  )
  for (col in expected_cols) {
    expect_true(
      col %in% names(res),
      label = sprintf("Column %s missing from ANA data", col)
    )
  }
})

test_that(".parse_emur_b extracts correct tables and fields", {
  xml_path <- testthat::test_path("fixtures/sample_emur_san.xml")
  skip_if_not(file.exists(xml_path), "EMUR SAN sample XML file not found")

  doc <- xml2::read_xml(xml_path)
  res <- .parse_emur_b(doc)

  expect_type(res, "list")
  expect_named(res, c("ps", "procedure", "obi"))

  # Validate 'ps' table
  expect_s3_class(res$ps, "data.frame")
  expect_gt(nrow(res$ps), 0)
  expect_true("Struttura_CodStrutturaErog" %in% names(res$ps))
  expect_true("Struttura_Progressivo" %in% names(res$ps))
  expect_true("Accesso_DataEntrata" %in% names(res$ps))
  expect_true("DatiSanitari_DiagnosiPrincipale" %in% names(res$ps))
  expect_true("DatiSanitari_PrestazionePrincipale" %in% names(res$ps))

  # Validate 'procedure' table
  expect_s3_class(res$procedure, "data.frame")
  expect_gt(nrow(res$procedure), 0)
  expect_true("Struttura_CodStrutturaErog" %in% names(res$procedure))
  expect_true("Struttura_Progressivo" %in% names(res$procedure))
  expect_true("Prestazione" %in% names(res$procedure))
  expect_true("TipoPrestazione" %in% names(res$procedure))
  expect_true("numProcedura" %in% names(res$procedure))
  expect_true("principale" %in% res$procedure$TipoPrestazione)
  expect_true("secondaria" %in% res$procedure$TipoPrestazione)
  expect_true(0L %in% res$procedure$numProcedura)
  expect_true(1L %in% res$procedure$numProcedura)

  # Validate 'obi' table
  expect_s3_class(res$obi, "data.frame")
  expect_gt(nrow(res$obi), 0)
  expect_true("Struttura_CodStrutturaErog" %in% names(res$obi))
  expect_true("Struttura_Progressivo" %in% names(res$obi))
  expect_true("ProblemaPrincipaleOBI" %in% names(res$obi))
})

test_that(".xml_profile_emur_tracciato_ab rejects SETT root nodes and accepts standard root nodes", {
  doc_std <- xml2::read_xml("<EMUR_ANA><ANA><Assistito><CodFiscale>123</CodFiscale></Assistito></ANA></EMUR_ANA>")
  res_std <- .xml_profile_emur_tracciato_ab(doc_std, "test.xml", NULL)
  expect_named(res_std, "anagrafica")
  expect_equal(nrow(res_std$anagrafica), 1)

  doc_sett <- xml2::read_xml("<EMUR_ANA_SETT><ANA><Assistito><CodFiscale>123</CodFiscale></Assistito></ANA></EMUR_ANA_SETT>")
  expect_error(
    .xml_profile_emur_tracciato_ab(doc_sett, "test.xml", NULL),
    class = "xpipe_batch_extraction"
  )
})

test_that(".xml_profile_emur_tracciato_ab_sett accepts SETT root nodes and rejects standard root nodes", {
  doc_sett <- xml2::read_xml("<EMUR_ANA_SETT><ANA><Assistito><CodFiscale>123</CodFiscale></Assistito></ANA></EMUR_ANA_SETT>")
  res_sett <- .xml_profile_emur_tracciato_ab_sett(doc_sett, "test.xml", NULL)
  expect_named(res_sett, "anagrafica")
  expect_equal(nrow(res_sett$anagrafica), 1)

  doc_std <- xml2::read_xml("<EMUR_ANA><ANA><Assistito><CodFiscale>123</CodFiscale></Assistito></ANA></EMUR_ANA>")
  expect_error(
    .xml_profile_emur_tracciato_ab_sett(doc_std, "test.xml", NULL),
    class = "xpipe_batch_extraction"
  )
})

