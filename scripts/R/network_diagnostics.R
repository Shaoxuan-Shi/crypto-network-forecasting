# Network diagnostic summaries for fitted BigVAR coefficients.
#
# These diagnostics describe how sparse and connected each rolling-window
# network is. They are not prediction metrics; they help interpret whether the
# BigVAR penalty is producing usable directed network structure or mostly zero
# coefficient matrices.

# Compute one diagnostic row per BigVAR refit timestamp.
compute_network_diagnostics <- function(network_features, coefficients, tolerance = 1e-8) {
  if (nrow(coefficients) == 0) {
    return(data.frame())
  }

  refit_times <- sort(unique(coefficients$refit_timestamp_utc))
  rows <- list()
  for (refit_time in refit_times) {
    # coef_block is the dense lag/source/target table for one fitted VAR(p).
    # node_block contains the corresponding asset-level network summaries.
    coef_block <- coefficients[coefficients$refit_timestamp_utc == refit_time, , drop = FALSE]
    node_block <- network_features[network_features$refit_timestamp_utc == refit_time, , drop = FALSE]
    cross_block <- coef_block[!coef_block$is_own_edge, , drop = FALSE]
    own_block <- coef_block[coef_block$is_own_edge, , drop = FALSE]

    # Sparsity is measured after applying the same near-zero tolerance used for
    # edge extraction. Cross coefficients exclude own-lag persistence terms.
    rows[[length(rows) + 1]] <- data.frame(
      refit_timestamp_utc = refit_time,
      n_coefficients = nrow(coef_block),
      n_nonzero_coefficients = sum(abs(coef_block$coefficient) > tolerance),
      sparsity_rate = mean(abs(coef_block$coefficient) <= tolerance),
      n_cross_coefficients = nrow(cross_block),
      n_nonzero_cross_coefficients = sum(abs(cross_block$coefficient) > tolerance),
      cross_sparsity_rate = mean(abs(cross_block$coefficient) <= tolerance),
      n_nonzero_own_coefficients = sum(abs(own_block$coefficient) > tolerance),
      mean_incoming_cross_effect = mean(node_block$incoming_cross_effect),
      mean_outgoing_cross_effect = mean(node_block$outgoing_cross_effect),
      mean_incoming_edge_count = mean(node_block$incoming_edge_count),
      mean_outgoing_edge_count = mean(node_block$outgoing_edge_count),
      stringsAsFactors = FALSE
    )
  }
  do.call(rbind, rows)
}
