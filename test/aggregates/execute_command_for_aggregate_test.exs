defmodule Commanded.Entities.ExecuteCommandForAggregateTest do
  use Commanded.StorageCase

  alias Commanded.Aggregates.{Aggregate,ExecutionContext}
  alias Commanded.EventStore
  alias Commanded.ExampleDomain.{BankAccount,OpenAccountHandler,DepositMoneyHandler}
  alias Commanded.ExampleDomain.BankAccount.Commands.{OpenAccount,DepositMoney}
  alias Commanded.ExampleDomain.BankAccount.Events.BankAccountOpened
  alias Commanded.Helpers

  @registry_provider Application.get_env(:commanded, :registry_provider, Registry)

  test "execute command against an aggregate" do
    account_number = UUID.uuid4

    {:ok, ^account_number} = Commanded.Aggregates.Supervisor.open_aggregate(BankAccount, account_number)

    command = %OpenAccount{account_number: account_number, initial_balance: 1_000}
    context = %ExecutionContext{command: command, handler: BankAccount, function: :open_account}

    {:ok, 1, events} = Aggregate.execute(BankAccount, account_number, context)

    assert events == [%BankAccountOpened{account_number: account_number, initial_balance: 1000}]

    Helpers.Process.shutdown(BankAccount, account_number)

    # reload aggregate to fetch persisted events from event store and rebuild state by applying saved events
    {:ok, ^account_number} = Commanded.Aggregates.Supervisor.open_aggregate(BankAccount, account_number)

    assert Aggregate.aggregate_version(BankAccount, account_number) == 1
    assert Aggregate.aggregate_state(BankAccount, account_number) == %BankAccount{account_number: account_number, balance: 1_000, state: :active}
  end

  test "execute command via a command handler" do
    account_number = UUID.uuid4

    {:ok, ^account_number} = Commanded.Aggregates.Supervisor.open_aggregate(BankAccount, account_number)

    command = %OpenAccount{account_number: account_number, initial_balance: 1_000}
    context = %ExecutionContext{command: command, handler: OpenAccountHandler, function: :handle}

    {:ok, 1, events} = Aggregate.execute(BankAccount, account_number, context)

    assert events == [%BankAccountOpened{account_number: account_number, initial_balance: 1000}]

    Helpers.Process.shutdown(BankAccount, account_number)

    # reload aggregate to fetch persisted events from event store and rebuild state by applying saved events
    {:ok, ^account_number} = Commanded.Aggregates.Supervisor.open_aggregate(BankAccount, account_number)

    assert Aggregate.aggregate_version(BankAccount, account_number) == 1
    assert Aggregate.aggregate_state(BankAccount, account_number) == %BankAccount{account_number: account_number, balance: 1_000, state: :active}
  end

  test "aggregate raising an exception should not persist pending events or state" do
    account_number = UUID.uuid4

    {:ok, ^account_number} = Commanded.Aggregates.Supervisor.open_aggregate(BankAccount, account_number)

    command = %OpenAccount{account_number: account_number, initial_balance: 1_000}
    context = %ExecutionContext{command: command, handler: OpenAccountHandler, function: :handle}

    {:ok, 1, _events} = Aggregate.execute(BankAccount, account_number, context)

    state_before = Aggregate.aggregate_state(BankAccount, account_number)

    assert_process_exit(account_number, fn ->
      command = %OpenAccount{account_number: account_number, initial_balance: 1}
      context = %ExecutionContext{command: command, handler: OpenAccountHandler, function: :handle}

      Aggregate.execute(BankAccount, account_number, context)
    end)

    {:ok, ^account_number} = Commanded.Aggregates.Supervisor.open_aggregate(BankAccount, account_number)
    assert state_before == Aggregate.aggregate_state(BankAccount, account_number)
  end

  test "executing a command against an aggregate with concurrency error should terminate aggregate process" do
    account_number = UUID.uuid4

    {:ok, ^account_number} = Commanded.Aggregates.Supervisor.open_aggregate(BankAccount, account_number)

    # block until aggregate has loaded its initial (empty) state
    Aggregate.aggregate_state(BankAccount, account_number)

    # write an event to the aggregate's stream, bypassing the aggregate process (simulate concurrency error)
    {:ok, _} = EventStore.append_to_stream(account_number, 0, [
      %Commanded.EventStore.EventData{
        event_type: "Elixir.Commanded.ExampleDomain.BankAccount.Events.BankAccountOpened",
        data: %BankAccountOpened{account_number: account_number, initial_balance: 1_000}
      }
    ])

    assert_process_exit(account_number, fn ->
      command = %DepositMoney{account_number: account_number, transfer_uuid: UUID.uuid4, amount: 50}
      context = %ExecutionContext{command: command, handler: DepositMoneyHandler, function: :handle}

      Aggregate.execute(BankAccount, account_number, context)
    end)
  end

  def assert_process_exit(aggregate_uuid, fun) do
    Process.flag(:trap_exit, true)

    spawn_link(fun)

    # process should exit
    assert_receive({:EXIT, _from, _reason})
    assert apply(@registry_provider, :whereis_name, [{:aggregate_registry, {BankAccount, aggregate_uuid}}]) == :undefined
  end
end
