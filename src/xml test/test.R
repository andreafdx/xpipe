library(xml2)

source("src/xml test/xml.R")
# or paste the function directly in the console
xml_path <- "C:/Users/78299/OneDrive - A.O.R.N. Antonio Cardarelli/XN3/2025_A.xml"
#xml_path <- "C:/Users/78299/2025_A.xml"
#xml_path <- "inbox/xml/2025_A.xml"
doc <- read_xml(xml_path)


xmlb_path <- "C:/Users/78299/OneDrive - A.O.R.N. Antonio Cardarelli/XN3/2025_B.xml"
#xmlb_path <- "inbox/xml/2025_B.xml"
docb <- read_xml(xmlb_path)

# Full

system.time({
  df_full <- parse_tracciato_a(doc)
})

system.time({
  list_b <- parse_tracciato_b(docb)
})






