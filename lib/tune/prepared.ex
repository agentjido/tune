defmodule Tune.Prepared do
  @moduledoc """
  A rendered, inspectable request for one predictor call.

  It holds normalized inputs, the signature, the demonstrations used, the
  adapter and its options, the ReqLLM context, and the output descriptor. It
  holds no model, credentials, or request options, and preparing it makes no
  model request. A host may execute `context` with `output` through its own
  inference path and pass the response to `Tune.Predictor.finish/2`.
  """

  alias Tune.Demo
  alias Tune.Signature

  @enforce_keys [:signature, :demos, :inputs, :adapter, :adapter_options, :context, :output]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          signature: Signature.t(),
          demos: [Demo.t()],
          inputs: map(),
          adapter: module(),
          adapter_options: keyword(),
          context: ReqLLM.Context.t(),
          output: ReqLLM.Output.t()
        }
end
