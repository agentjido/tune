defmodule Tune.Search.Grid do
  @moduledoc false

  alias Tune.Error
  alias Tune.Search.Generic
  alias Tune.Search.Study
  alias Tune.Space.Choice
  alias Tune.Space.Integer, as: IntegerSpace

  def run(target, runner, data_factory, variations, scores, selector, limits, opts) do
    with :ok <- options(opts),
         {:ok, axes} <- axes(variations, target),
         study = Study.new(limits: limits, metadata: %{strategy: :grid}),
         {:ok, cases} <- Generic.snapshot(data_factory, study, :grid) do
      study =
        axes
        |> combinations()
        |> Enum.reduce_while(study, fn params, study ->
          case Study.limit_reason(study) do
            nil ->
              value = Generic.apply_parameters(target, params)

              evaluation =
                Generic.evaluate(
                  cases,
                  runner,
                  value,
                  scores,
                  selector,
                  Study.evaluation_limits(study)
                )

              {_candidate, study} = Generic.record(study, value, params, evaluation, %{})
              {:cont, study}

            reason ->
              {:halt, Study.stop(study, reason)}
          end
        end)

      Generic.result(study, [])
    end
  end

  defp options([]), do: :ok
  defp options(_opts), do: invalid("grid does not accept strategy options")

  defp axes(variations, target) when map_size(variations) > 0 and is_map(target) do
    variations
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, []}, fn {key, descriptor}, {:ok, axes} ->
      with true <- key != :__struct__ and Map.has_key?(target, key),
           {:ok, values} <- values(descriptor) do
        {:cont, {:ok, [{key, values} | axes]}}
      else
        _ ->
          {:halt, invalid("#{key} must be a target field with a finite integer range or choices")}
      end
    end)
    |> case do
      {:ok, axes} -> {:ok, Enum.reverse(axes)}
      error -> error
    end
  end

  defp axes(_variations, _target),
    do: invalid("grid requires a map or struct and at least one variation")

  defp values(%Range{first: first, last: last, step: step} = range)
       when is_integer(first) and is_integer(last) and is_integer(step) and step != 0 do
    if Enum.empty?(range), do: :error, else: {:ok, range}
  end

  defp values(%IntegerSpace{min: min, max: max, step: step})
       when is_integer(min) and is_integer(max) and min <= max and is_integer(step) and step > 0,
       do: {:ok, min..max//step}

  defp values(%Choice{values: choices}), do: values(choices)
  defp values([_ | _] = choices), do: {:ok, Enum.uniq(choices)}
  defp values(_descriptor), do: :error

  defp combinations([]), do: [%{}]

  defp combinations([{key, values} | rest]) do
    Stream.flat_map(values, fn value ->
      Stream.map(combinations(rest), &Map.put(&1, key, value))
    end)
  end

  defp invalid(message),
    do: {:error, Error.Invalid.Option.exception(option: :grid, message: message)}
end
