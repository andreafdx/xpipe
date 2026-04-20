# Test Bronze Promotion state tracking
# Set WD to project root before running

# Load dependencies
if (!requireNamespace("box", quietly = TRUE)) install.packages("box")
if (!requireNamespace("fs", quietly = TRUE)) install.packages("fs")

# Source config to get load_options
source("src/fnc/config.R")

# Load the bronze promotion module
# Using backticks because of the space and leading digit
box::use(
  bronze = ./`2. bronze_promotion`
)

# 1. Load configuration
# We need to set some env vars that config.R expects
Sys.setenv(XNE_PEPPER_KEY = "test_pepper")
Sys.setenv(XACC_SKIP_HASH_CHECK = "TRUE")

cfg <- load_options()

# 2. Get initial state
state <- bronze$get_bronze_state(cfg)
cat("\nInitial state:\n")
print(state)

# 3. Modify state
test_batch_id <- paste0("test_batch_", format(Sys.time(), "%Y%m%d_%H%M%S"))
state$promoted_batches <- c(state$promoted_batches, test_batch_id)
state$last_promotion_at <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ")

# 4. Save state
bronze$save_bronze_state(cfg, state)
cat("\nUpdated state saved.\n")

# 5. Reload and verify
new_state <- bronze$get_bronze_state(cfg)
cat("\nReloaded state:\n")
print(new_state)

if (test_batch_id %in% new_state$promoted_batches) {
  message("\nSUCCESS: State saved and reloaded correctly.")
} else {
  stop("\nFAILURE: State mismatch after reload.")
}
