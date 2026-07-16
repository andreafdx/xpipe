library(xml2)

source("R/tools_xml.R")
# or paste the function directly in the console
#xml_path <- "C:/Users/78299/OneDrive - A.O.R.N. Antonio Cardarelli/XN3/2025_A.xml"
#xml_path <- "C:/Users/78299/2025_A.xml"
xml_path <- "inbox/xml/2025_A.xml"
doc <- read_xml(xml_path)


#xmlb_path <- "C:/Users/78299/OneDrive - A.O.R.N. Antonio Cardarelli/XN3/2025_B.xml"
xmlb_path <- "inbox/xml/2025_B.xml"
docb <- read_xml(xmlb_path)

# Full

system.time({
  df_full <- .parse_tracciato_a(doc)
})

system.time({
  list_b <- .parse_tracciato_b(docb)
})


# speed tests -------

library(xml2)

xml_file <- xmlb_path

# 1. Parse XML document
t_parse <- system.time({
  doc <- read_xml(xml_file)
})

# 2. Find records (this is part of parsing cost)
t_find <- system.time({
  records <- xml_find_all(doc, ".//bInformazioniRicovero")
})

# 3. Extract rows (your parser)
t_extract <- system.time({
  res <- parse_tracciato_b(doc)
})

list(
  xml_parse = t_parse,
  xml_find = t_find,
  extraction = t_extract
)


Rprof("xml_profile.out")
res <- parse_tracciato_b(doc)
Rprof(NULL)

summaryRprof("xml_profile.out")
