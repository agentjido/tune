defmodule Tune.Error do
  @moduledoc """
  Structured errors owned by Tune.

  Provider and transport failures from ReqLLM are never wrapped into these
  classes. They are kept unchanged as the `cause` of an
  `Tune.Error.Execution.Failed` error.
  """

  use Splode,
    error_classes: [
      invalid: Tune.Error.Invalid,
      output: Tune.Error.Output,
      execution: Tune.Error.Execution,
      unknown: Tune.Error.Unknown
    ],
    unknown_error: Tune.Error.Unknown.Unknown

  defmodule Invalid do
    @moduledoc "Error class for invalid definitions, options, and inputs."
    use Splode.ErrorClass, class: :invalid
  end

  defmodule Output do
    @moduledoc "Error class for model replies that cannot become a validated output."
    use Splode.ErrorClass, class: :output
  end

  defmodule Execution do
    @moduledoc "Error class for runtime failures that retain partial results."
    use Splode.ErrorClass, class: :execution
  end

  defmodule Unknown do
    @moduledoc "Error class for unexpected failures."
    use Splode.ErrorClass, class: :unknown
  end

  defmodule Invalid.Definition do
    @moduledoc "A signature, field, predictor, demonstration, or model configuration is invalid."
    use Splode.Error, fields: [:message, :details], class: :invalid

    @spec message(map()) :: String.t()
    def message(%{message: message}), do: message
  end

  defmodule Invalid.Option do
    @moduledoc "An option is unknown, forbidden, or has an invalid value."
    use Splode.Error, fields: [:option, :message], class: :invalid

    @spec message(map()) :: String.t()
    def message(%{option: option, message: message}), do: "#{inspect(option)}: #{message}"
  end

  defmodule Invalid.Dataset do
    @moduledoc "A dataset source failed while Tune was reading its rows."
    use Splode.Error, fields: [:split, :cause], class: :invalid

    @spec message(map()) :: String.t()
    def message(%{split: split, cause: cause}),
      do: "could not read #{inspect(split)} data: #{Exception.message(cause)}"
  end

  defmodule Invalid.Input do
    @moduledoc "Program inputs do not match the declared input fields."
    use Splode.Error, fields: [:message, :errors], class: :invalid

    @spec message(map()) :: String.t()
    def message(%{message: message}), do: message
  end

  defmodule Output.Rejected do
    @moduledoc """
    A ReqLLM response is not an acceptable completed reply.

    `reason` is one of `:response_error`, `:refusal`, `:finish_reason`, or
    `:repaired`. The original response is retained.
    """
    use Splode.Error, fields: [:reason, :message, :response], class: :output

    @spec message(map()) :: String.t()
    def message(%{message: message}), do: message
  end

  defmodule Output.Parse do
    @moduledoc "An adapter could not parse the reply into declared output fields."
    use Splode.Error, fields: [:message, :field, :reply, :response], class: :output

    @spec message(map()) :: String.t()
    def message(%{message: message}), do: message
  end

  defmodule Output.Invalid do
    @moduledoc "Parsed output values do not match the declared output schema."
    use Splode.Error, fields: [:message, :errors, :value, :response], class: :output

    @spec message(map()) :: String.t()
    def message(%{message: message}), do: message
  end

  defmodule Execution.Failed do
    @moduledoc """
    A program run failed after it started.

    `cause` is the original error, unchanged, including ReqLLM provider errors.
    `result` is the partial `Tune.Prediction` with managed call counts,
    observed responses, and completed steps.
    """
    use Splode.Error, fields: [:cause, :result, :step], class: :execution

    @spec message(map()) :: String.t()
    def message(%{cause: cause, step: step}) do
      "step #{inspect(step)} failed: #{describe(cause)}"
    end

    defp describe(%{__exception__: true} = cause), do: Exception.message(cause)
    defp describe(cause), do: inspect(cause)
  end

  defmodule Execution.LimitReached do
    @moduledoc """
    A managed limit stopped a call before dispatch.

    `limit` is `:model_calls`, `:steps`, or `:deadline`.
    """
    use Splode.Error, fields: [:limit, :message], class: :execution

    @spec message(map()) :: String.t()
    def message(%{message: message}), do: message
  end

  defmodule Execution.Callback do
    @moduledoc "Application code did not follow a Tune callback contract."
    use Splode.Error, fields: [:message, :value], class: :execution

    @spec message(map()) :: String.t()
    def message(%{message: message}), do: message
  end

  defmodule Optimization.Failed do
    @moduledoc """
    An optimization could not return an eligible program.

    `report` is the optimization report with partial records. `cause` is the
    original error when one stopped the run.
    """
    use Splode.Error, fields: [:message, :cause, :report], class: :execution

    @spec message(map()) :: String.t()
    def message(%{message: message}), do: message
  end

  defmodule Unknown.Unknown do
    @moduledoc "An unexpected error."
    use Splode.Error, fields: [:error], class: :unknown

    @spec message(map()) :: String.t()
    def message(%{error: error}), do: inspect(error)
  end
end
