defmodule Tune.Examples.Support.Tickets do
  @moduledoc "Small support ticket fixtures used for routing and example selection."

  @banking [
    {"I lost my debit card on the train", "lost_card"},
    {"My card is missing after a trip", "lost_card"},
    {"The ATM debited me and dispensed no cash", "cash_withdrawal"},
    {"Cash withdrawal failed at the station ATM", "cash_withdrawal"},
    {"There is a fee on my card purchase abroad", "card_payment_fee"},
    {"Why was there a fee on my card payment?", "card_payment_fee"}
  ]

  def classifier(instructions \\ "Route the support ticket.") do
    {:ok, predictor} =
      Tune.Predictor.new(
        signature: [
          instructions: instructions,
          inputs: [ticket: Zoi.string()],
          outputs: [label: Zoi.string()]
        ]
      )

    predictor
  end

  def banking, do: rows(@banking)

  def banking_label(ticket) do
    cond do
      ticket =~ ~r/lost|missing|find my/i -> "lost_card"
      ticket =~ ~r/atm|cash/i -> "cash_withdrawal"
      ticket =~ ~r/fee/i -> "card_payment_fee"
      true -> "unrouted"
    end
  end

  def billing(count, prefix \\ "invoice"),
    do: rows(for i <- 1..count, do: {"#{prefix} #{i}", "billing"})

  def rows(pairs), do: Enum.map(pairs, fn {ticket, label} -> row(ticket, label) end)
  def row(ticket, label), do: %{input: %{ticket: ticket}, expected: %{label: label}}

  def exact(row, %{"label" => label}), do: if(label == row.expected["label"], do: 1, else: 0)
end
