# 03 Evolution and configuration search

Use exact finite search or supply genetic operators for application-owned data.

## Lessons

- [03_01 Search batch and worker settings](03_01_batch_grid/README.md). Enumerate finite integer and choice spaces and compare the winner with the original on fresh workloads.
- [03_02 Evolve a word](03_02_evolve_string/README.md). Seed generation zero with strings and use application crossover and mutation.
- [03_03 Pack a kit under a weight limit](03_03_pack_kit/README.md). Use a binary genome and score only feasible kits.
- [03_04 Minimize delivery distance](03_04_delivery_route/README.md). Use permutation-safe crossover and a custom parent selector to minimize a round trip.
- [03_05 Tune Axon training](03_05_axon_training/README.md). Use a fixed batch and application-owned Axon training for each hyperparameter choice.
- [03_06 Evolve and interrupt a dispatch policy](03_06_dispatch_queue/README.md). Run a queue simulator with genetic search and record generation snapshots.
