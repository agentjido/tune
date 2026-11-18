# 01 DSPy workflows

Learn to validate model output, use demonstration sets, and select prompts with held-out data.

## Lessons

- [01_01 Extract a typed ticket](01_01_extract_ticket/README.md). Preview and call one predictor with the Chat, JSON, and XML adapters.
- [01_02 Route tickets from labeled examples](01_02_labeled_routing/README.md). Use LabeledFewShot with seeded sampling on a Banking77-style ticket set.
- [01_03 Bootstrap a grounded QA program](01_03_bootstrap_qa/README.md). Learn demonstrations from complete teacher runs over extraction and answering.
- [01_04 Search demonstration sets](01_04_search_demos/README.md). Compare random search and the native categorical TPE strategy on identical training and validation sets.
- [01_05 Retrieve nearby demonstrations](01_05_neighbor_demos/README.md). Use KNNFewShot to bootstrap a different demonstration for each ticket.
- [01_06 Rewrite named instructions](01_06_rewrite_instructions/README.md). Run SignatureOptimizer and COPRO on the same grounded QA program.
- [01_07 Optimize instructions and demonstrations](01_07_joint_search/README.md). Use MIPROv2 to search instruction and demonstration choices and validate promising combinations.
- [01_08 Infer escalation rules](01_08_infer_rules/README.md). Learn escalation rules from accepted examples and validate their effect.
- [01_09 Reduce inconsistent routing](01_09_simba/README.md). Use SIMBA to add a successful demonstration or instruction advice.
- [01_10 Improve an urgency predictor](01_10_avatar_urgency/README.md). Give Avatar contrasting good and bad traces and name one predictor to rewrite.
- [01_11 Learn a bounded support playbook](01_11_support_playbook/README.md). Pass a selected lesson into normal application code as an input to the urgency predictor.
- [01_12 Vote across classifiers](01_12_ensemble/README.md). Compose compatible classifiers with Tune.Ensemble.
