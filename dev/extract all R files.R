# Directories to scan
dirs <- c("R") #"tests"
jdirs <- c("inst")

# Collect existing directories only
dirs <- dirs[dir.exists(dirs)]
jdirs <- jdirs[dir.exists(jdirs)]


# Find all .R files recursively
r_files <- unlist(lapply(dirs, function(d) {
  list.files(d, pattern = "\\.R$", recursive = TRUE, full.names = TRUE)
}))

j_files <- unlist(lapply(jdirs, function(d) {
  list.files(d, pattern = "\\.json$", recursive = TRUE, full.names = TRUE)
}))


# Output file
out_file <- "dev/all_R_files.txt"

con <- file(out_file, open = "w", encoding = "UTF-8")

for (f in r_files) {
  writeLines(f, con)
  writeLines("'''", con)
  writeLines(readLines(f, warn = FALSE), con)
  writeLines("'''", con)
}

close(con)

out_file <- "dev/all_J_files.txt"

con <- file(out_file, open = "w", encoding = "UTF-8")

for (f in j_files) {
  writeLines(f, con)
  writeLines("'''", con)
  writeLines(readLines(f, warn = FALSE), con)
  writeLines("'''", con)
}

close(con)
