defmodule ArmchairMetropolist.Domain.Entities.MunicipalBond do
  @moduledoc """
  One serial municipal bond issue, used for either opening finance or the commercial bridge.

  The issue amortizes level principal over a fixed term. Principal arrears are a
  subset of outstanding principal, never an additional balance; interest arrears
  are carried separately and do not themselves earn interest.
  """

  @issues [250.0, 400.0, 550.0]
  @recommended_issue 400.0
  @opening_period_ticks 20
  @call_protection_ticks 20
  @term_ticks 100
  @interest_rate 0.005

  @type t :: %__MODULE__{
          original_principal: float(),
          outstanding_principal: float(),
          interest_arrears: float(),
          principal_arrears: float(),
          started_at_tick: non_neg_integer() | nil
        }

  @type quote :: %{
          legacy: boolean(),
          original_principal: float(),
          outstanding_principal: float(),
          interest_arrears: float(),
          principal_arrears: float(),
          redemption_amount: float(),
          opening_period_remaining: non_neg_integer(),
          call_protection_remaining: non_neg_integer(),
          callable: boolean(),
          maturity_remaining: non_neg_integer(),
          next_interest: float(),
          next_principal: float(),
          next_payment: float(),
          defaulted: boolean()
        }

  defstruct original_principal: 0.0,
            outstanding_principal: 0.0,
            interest_arrears: 0.0,
            principal_arrears: 0.0,
            started_at_tick: nil

  @doc "The three issue sizes a new city may authorize."
  @spec issues() :: [float()]
  def issues, do: @issues

  @doc "The issue highlighted for a first city."
  @spec recommended_issue() :: float()
  def recommended_issue, do: @recommended_issue

  @doc "Construct and immediately start a quoted one-time commercial bridge issue."
  @spec commercial_bridge(float(), non_neg_integer()) :: t()
  def commercial_bridge(principal, tick)
      when is_number(principal) and principal > 0.0 and is_integer(tick) and tick >= 0 do
    %__MODULE__{
      original_principal: principal * 1.0,
      outstanding_principal: principal * 1.0
    }
    |> start(tick)
  end

  @doc "Ticks after first construction before debt service begins."
  @spec opening_period_ticks() :: pos_integer()
  def opening_period_ticks, do: @opening_period_ticks

  @doc "Servicing ticks before optional redemption opens."
  @spec call_protection_ticks() :: pos_integer()
  def call_protection_ticks, do: @call_protection_ticks

  @doc "Servicing ticks from first payment through final maturity."
  @spec term_ticks() :: pos_integer()
  def term_ticks, do: @term_ticks

  @doc "Simple interest charged per servicing tick."
  @spec interest_rate() :: float()
  def interest_rate, do: @interest_rate

  @doc "Construct an authorized issue."
  @spec new(float()) :: {:ok, t()} | {:error, :invalid_issue}
  def new(principal) when principal in @issues do
    {:ok,
     %__MODULE__{
       original_principal: principal,
       outstanding_principal: principal
     }}
  end

  def new(_principal), do: {:error, :invalid_issue}

  @doc "The on-time schedule figures used to compare one authorized issue."
  @spec issue_terms(float()) ::
          %{
            principal_payment: float(),
            first_interest: float(),
            first_payment: float(),
            total_interest: float(),
            final_payment: float()
          }
  def issue_terms(principal) when principal in @issues do
    {:ok, bond} = new(principal)
    bond = start(bond, 0)

    {payments, _bond} =
      Enum.map_reduce(@opening_period_ticks..(@opening_period_ticks + @term_ticks - 1), bond, fn
        tick, current ->
          %{bond: next, payment: payment} = service(current, tick, 10_000.0)
          {payment, next}
      end)

    %{
      principal_payment: principal / @term_ticks,
      first_interest: principal * @interest_rate,
      first_payment: List.first(payments),
      total_interest: Enum.sum(payments) - principal,
      final_payment: List.last(payments)
    }
  end

  @doc "The permanent debt-free record assigned to a city created before bonds existed."
  @spec legacy() :: t()
  def legacy, do: %__MODULE__{}

  @spec issued?(t() | nil) :: boolean()
  def issued?(%__MODULE__{original_principal: principal}), do: principal > 0.0
  def issued?(nil), do: false

  @spec legacy?(t() | nil) :: boolean()
  def legacy?(%__MODULE__{original_principal: principal}), do: principal == 0.0
  def legacy?(_bond), do: false

  @spec debt_free?(t() | nil) :: boolean()
  def debt_free?(%__MODULE__{} = bond) do
    bond.outstanding_principal == 0.0 and bond.interest_arrears == 0.0
  end

  def debt_free?(nil), do: false

  @spec defaulted?(t() | nil) :: boolean()
  def defaulted?(%__MODULE__{} = bond) do
    bond.interest_arrears > 0.0 or bond.principal_arrears > 0.0
  end

  def defaulted?(nil), do: false

  @spec redemption_amount(t()) :: float()
  def redemption_amount(%__MODULE__{} = bond) do
    bond.interest_arrears + bond.outstanding_principal
  end

  @doc "Record the first successful construction tick exactly once."
  @spec start(t(), non_neg_integer()) :: t()
  def start(%__MODULE__{started_at_tick: nil} = bond, tick)
      when is_integer(tick) and tick >= 0 do
    if issued?(bond) and not debt_free?(bond), do: %{bond | started_at_tick: tick}, else: bond
  end

  def start(%__MODULE__{} = bond, _tick), do: bond

  @spec callable?(t() | nil, non_neg_integer()) :: boolean()
  def callable?(%__MODULE__{started_at_tick: started} = bond, tick)
      when is_integer(started) and is_integer(tick) do
    issued?(bond) and not debt_free?(bond) and
      servicing_ticks_elapsed(bond, tick) >=
        @call_protection_ticks
  end

  def callable?(_bond, _tick), do: false

  @doc "Quote the next transition without changing the issue."
  @spec quote(t() | nil, non_neg_integer()) :: quote() | nil
  def quote(nil, _tick), do: nil

  def quote(%__MODULE__{} = bond, tick) do
    {interest, principal} = due(bond, tick)
    elapsed = servicing_ticks_elapsed(bond, tick)

    %{
      legacy: legacy?(bond),
      original_principal: bond.original_principal,
      outstanding_principal: bond.outstanding_principal,
      interest_arrears: bond.interest_arrears,
      principal_arrears: bond.principal_arrears,
      redemption_amount: redemption_amount(bond),
      opening_period_remaining: opening_period_remaining(bond, tick),
      call_protection_remaining: max(0, @call_protection_ticks - elapsed),
      callable: callable?(bond, tick),
      maturity_remaining: max(0, @term_ticks - elapsed),
      next_interest: interest,
      next_principal: principal,
      next_payment: interest + principal,
      defaulted: defaulted?(bond)
    }
  end

  @doc "Apply scheduled service from the available post-upkeep cash."
  @spec service(t() | nil, non_neg_integer(), float()) ::
          %{bond: t() | nil, payment: float()}
  def service(nil, _tick, _available), do: %{bond: nil, payment: 0.0}

  def service(%__MODULE__{} = bond, tick, available) when is_number(available) do
    {interest_due, principal_due} = due(bond, tick)
    scheduled_due = interest_due + principal_due

    if scheduled_due == 0.0 do
      %{bond: bond, payment: 0.0}
    else
      payment = min(max(available * 1.0, 0.0), scheduled_due)
      full_due_covered? = available >= scheduled_due

      interest_paid =
        if full_due_covered?, do: interest_due, else: min(payment, interest_due)

      principal_paid =
        if full_due_covered? do
          principal_due
        else
          min(bond.outstanding_principal, max(0.0, payment - interest_paid))
        end

      next_bond = allocate_service(bond, tick, interest_due, interest_paid, principal_paid)
      %{bond: next_bond, payment: interest_paid + principal_paid}
    end
  end

  @doc "Redeem an eligible amount at par, allocating arrears before unmatured principal."
  @spec redeem(t(), non_neg_integer(), float()) :: {:ok, t()} | {:error, :not_callable}
  def redeem(%__MODULE__{} = bond, tick, amount) when is_number(amount) and amount >= 0.0 do
    if callable?(bond, tick) do
      total = redemption_amount(bond)

      if amount >= total do
        {:ok,
         %{
           bond
           | outstanding_principal: 0.0,
             interest_arrears: 0.0,
             principal_arrears: 0.0
         }}
      else
        interest_paid = min(amount, bond.interest_arrears)
        principal_paid = min(bond.outstanding_principal, amount - interest_paid)
        past_principal_paid = min(bond.principal_arrears, principal_paid)

        {:ok,
         %{
           bond
           | interest_arrears: max(0.0, bond.interest_arrears - interest_paid),
             outstanding_principal: max(0.0, bond.outstanding_principal - principal_paid),
             principal_arrears: max(0.0, bond.principal_arrears - past_principal_paid)
         }}
      end
    else
      {:error, :not_callable}
    end
  end

  defp due(%__MODULE__{} = bond, tick) do
    servicing_tick = servicing_tick(bond, tick)

    cond do
      not issued?(bond) or debt_free?(bond) or is_nil(bond.started_at_tick) ->
        {0.0, 0.0}

      servicing_tick <= 0 ->
        {0.0, 0.0}

      servicing_tick < @term_ticks ->
        current_interest = @interest_rate * bond.outstanding_principal

        current_serial =
          min(
            bond.original_principal / @term_ticks,
            max(0.0, bond.outstanding_principal - bond.principal_arrears)
          )

        {bond.interest_arrears + current_interest, bond.principal_arrears + current_serial}

      true ->
        current_interest = @interest_rate * bond.outstanding_principal
        {bond.interest_arrears + current_interest, bond.outstanding_principal}
    end
  end

  defp allocate_service(bond, tick, interest_due, interest_paid, principal_paid) do
    servicing_tick = servicing_tick(bond, tick)
    next_interest_arrears = max(0.0, interest_due - interest_paid)
    next_principal = max(0.0, bond.outstanding_principal - principal_paid)

    next_principal_arrears =
      if servicing_tick >= @term_ticks do
        next_principal
      else
        current_serial =
          min(
            bond.original_principal / @term_ticks,
            max(0.0, bond.outstanding_principal - bond.principal_arrears)
          )

        past_paid = min(bond.principal_arrears, principal_paid)
        current_paid = max(0.0, principal_paid - past_paid)

        max(0.0, bond.principal_arrears - past_paid + current_serial - current_paid)
      end

    %{
      bond
      | outstanding_principal: next_principal,
        interest_arrears: next_interest_arrears,
        principal_arrears: min(next_principal, next_principal_arrears)
    }
  end

  defp opening_period_remaining(%__MODULE__{started_at_tick: nil}, _tick),
    do: @opening_period_ticks

  defp opening_period_remaining(%__MODULE__{started_at_tick: started}, tick) do
    max(0, @opening_period_ticks - (tick - started))
  end

  defp servicing_ticks_elapsed(%__MODULE__{started_at_tick: nil}, _tick), do: 0

  defp servicing_ticks_elapsed(%__MODULE__{started_at_tick: started}, tick) do
    max(0, tick - started - @opening_period_ticks)
  end

  defp servicing_tick(%__MODULE__{started_at_tick: nil}, _tick), do: 0

  defp servicing_tick(%__MODULE__{started_at_tick: started}, tick) do
    tick - started - @opening_period_ticks + 1
  end
end
