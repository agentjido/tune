# 04 Evaluation

Evaluate saved and live application results, account for failures, and make a release decision.

## Lessons

- [04_01 Replay saved JSONL answers](04_01_saved_replay/README.md). Stream saved answers into `Tune.replay/1` and score them offline.
- [04_02 Score grounding and context precision](04_02_retrieval/README.md). Use independent judges for claim support and relevance in retrieval order.
- [04_03 Evaluate streamed CSV](04_03_streamed_csv/README.md). Keep parsing in the application and report exact match, abstention, and minimized cost.
- [04_04 Evaluate multi-turn support transcripts](04_04_support_transcripts/README.md). Use ordered transcript turns for separate escalation and resolution scores.
- [04_05 Supervise evaluation in the background](04_05_background_evaluation/README.md). Start evaluation under a host Task.Supervisor and publish application progress and reports.
- [04_06 Gate a release on paired evidence](04_06_paired_release/README.md). Compare the same holdout cases in order and apply an application release rule.
