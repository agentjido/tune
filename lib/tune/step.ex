defmodule Tune.Step do
  @moduledoc """
  One completed predictor call: its name, role, signature, actual inputs,
  validated outputs, and the unchanged ReqLLM response.
  """

  alias Tune.Signature

  @enforce_keys [:name, :signature, :inputs, :outputs, :response]
  defstruct [:name, :role, :signature, :inputs, :outputs, :response]

  @type t :: %__MODULE__{
          name: String.t() | nil,
          role: atom() | nil,
          signature: Signature.t(),
          inputs: map(),
          outputs: map(),
          response: ReqLLM.Response.t()
        }
end
