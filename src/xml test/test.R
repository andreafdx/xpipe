library(xml2)

source("src/xml test/xml.r")
# or paste the function directly in the console
xml_path <- "C:/Users/78299/OneDrive - A.O.R.N. Antonio Cardarelli/XN3/2025_A.xml"
#xml_path <- "C:/Users/78299/2025_A.xml"
doc <- read_xml(xml_path)



# Full

elapsed <- system.time({
  df_full <- parse_tracciato_a(doc)
  })






