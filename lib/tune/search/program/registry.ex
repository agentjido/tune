defmodule Tune.Search.Program.Registry do
  @moduledoc false

  @strategies %{
    labeled_few_shot: Tune.Optimizers.LabeledFewShot,
    bootstrap_few_shot: Tune.Optimizers.BootstrapFewShot,
    bootstrap_few_shot_random_search: Tune.Optimizers.BootstrapFewShotWithRandomSearch,
    bootstrap_few_shot_optuna: Tune.Optimizers.BootstrapFewShotWithOptuna,
    knn_few_shot: Tune.Optimizers.KNNFewShot,
    copro: Tune.Optimizers.COPRO,
    signature_optimizer: Tune.Optimizers.SignatureOptimizer,
    mipro_v2: Tune.Optimizers.MIPROv2,
    infer_rules: Tune.Optimizers.InferRules,
    simba: Tune.Optimizers.SIMBA,
    gepa: Tune.Optimizers.GEPA,
    avatar: Tune.Optimizers.Avatar,
    playbook: Tune.Optimizers.Playbook,
    anything: Tune.Optimizers.Anything,
    ensemble: Tune.Optimizers.Ensemble
  }

  @spec fetch(atom() | module()) :: module() | nil
  def fetch(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :compile, 3),
      do: module,
      else: Map.get(@strategies, module)
  end

  @spec tags() :: [atom()]
  def tags, do: Map.keys(@strategies)
end
