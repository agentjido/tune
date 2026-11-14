defmodule Tune.Adapter do
  @moduledoc """
  A pure prompt format.

  An adapter renders a signature, demonstrations, and inputs into a ReqLLM
  context and output descriptor, and parses a reply into a map of declared
  output fields. It never calls a model, retries, repairs, or falls back to
  another format. The caller validates the parsed map against the signature.
  """

  alias Tune.Demo
  alias Tune.Signature

  @typedoc "A rendered request: the ReqLLM context and the output descriptor to request."
  @type rendering :: %{context: ReqLLM.Context.t(), output: ReqLLM.Output.t()}

  @typedoc """
  A reply to parse: raw response text for text output, or the validated
  structured value for object output.
  """
  @type reply :: {:text, String.t()} | {:object, map()}

  @doc "Validates and normalizes adapter options once, when a model configuration is built."
  @callback normalize_options(keyword()) :: {:ok, keyword()} | {:error, Exception.t()}

  @doc "Renders a request. Inputs are already normalized and validated."
  @callback render(Signature.t(), [Demo.t()], map(), keyword()) ::
              {:ok, rendering()} | {:error, Exception.t()}

  @doc "Parses a reply into a string-keyed map of every declared output field."
  @callback parse(Signature.t(), reply(), keyword()) :: {:ok, map()} | {:error, Exception.t()}
end
