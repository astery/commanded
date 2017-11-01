defmodule Commanded.Commands.Router do
  @moduledoc """
  Command routing macro to allow configuration of each command to its command handler.

  ## Example

      defmodule BankRouter do
        use Commanded.Commands.Router

        dispatch OpenAccount,
          to: OpenAccountHandler,
          aggregate: BankAccount,
          identity: :account_number
      end

      :ok = BankRouter.dispatch(%OpenAccount{
        account_number: "ACC123",
        initial_balance: 1_000
      })

  The command handler module must implement a `handle/2` function that receives
  the aggregate's state and the command to execute. It should delegate the
  command to the aggregate.

  ## Dispatch command directly to an aggregate root

  You can route a command directly to an aggregate root, without requiring an
  intermediate command handler.

  ### Example

      defmodule BankRouter do
        use Commanded.Commands.Router

        dispatch OpenAccount, to: BankAccount, identity: :account_number
      end

  The aggregate root must implement an `execute/2` function that receives the
  aggregate's state and the command being executed.

  ## Define aggregate identity

  You can define the identity field for an aggregate once using the `identify` macro.
  The configured identity will be used for all commands registered to the aggregate,
  unless overridden by a command registration.

  ### Example

      defmodule BankRouter do
        use Commanded.Commands.Router

        identify BankAccount,
          by: :account_number,
          prefix: "bank-account-"

        dispatch OpenAccount, to: BankAccount
      end

  An optional identity prefix can be used to distinguish between different
  aggregates that  would otherwise share the same identity. As an example you
  might have a `User` and a `UserPreferences` aggregate that you wish
  to share the same identity. In this scenario you should specify a `prefix`
  for each aggregate (e.g. "user-" and "user-preference-").

  The prefix is used as the stream identity when appending, and reading, the
  aggregate's events: "<identity_prefix><aggregate_uuid>".

  ## Consistency

  You can choose to dispatch commands using either `:eventual` or `:strong`
  consistency:

      :ok = BankRouter.dispatch(command, consistency: :strong)

  Using `:strong` consistency will block command dispatch until all strongly
  consistent event handlers and process managers have successfully process all
  events created by the command.

  Use this when you have event handlers that update read models you need to
  query immediately after dispatching the command.

  ## Aggregate version

  You can optionally choose to include the aggregate's version as part of the
  dispatch result by setting `include_aggregate_version` true.

      {:ok, aggregate_version} = BankRouter.dispatch(command, include_aggregate_version: true)

  This is useful when you need to wait for an event handler (e.g. a read model
  projection) to be up-to-date before continuing or querying its data.

  ## Execution results

  You can also choose to include the execution result as part of the dispatch result by
  setting `include_execution_result` true.

      {:ok, execution_result} = BankRouter.dispatch(command, include_execution_result: true)

  You can use this if you need to get information from the events produced by the aggregate
  but you can't afford to wait for the events to be projected.

  ## Metadata

  You can associate metadata with all events created by the command.

  Supply a map containing key/value pairs comprising the metadata:

      :ok = BankRouter.dispatch(command, metadata: %{"ip_address" => "127.0.0.1"})

  """

  defmacro __using__(_) do
    quote do
      require Logger
      import unquote(__MODULE__)
      @before_compile unquote(__MODULE__)
      @registered_commands []
      @registered_middleware []
      @registered_identities %{}
      @default_middleware [
        Commanded.Middleware.ExtractAggregateIdentity,
        Commanded.Middleware.ConsistencyGuarantee,
      ]
      @default_consistency :eventual
      @default_dispatch_timeout 5_000
      @default_lifespan Commanded.Aggregates.DefaultLifespan
      @default_metadata %{}
      @default_assigns %{}
      @include_aggregate_version false
      @include_execution_result false
    end
  end

  @doc """
  Include the given middleware module to be called before and after
  success or failure of each command dispatch

  The middleware module must implement the `Commanded.Middleware` behaviour.

  Middleware modules are executed in the order they are defined.

  ## Example

      defmodule BankingRouter do
        use Commanded.Commands.Router

        middleware CommandLogger
        middleware MyCommandValidator
        middleware AuthorizeCommand

        dispatch [OpenAccount,DepositMoney] to: BankAccount, identity: :account_number
      end
  """
  defmacro middleware(middleware_module) do
    quote do
      @registered_middleware @registered_middleware ++ [unquote(middleware_module)]
    end
  end

  @doc """
  Define an aggregate's identity

  You can define the identity field for an aggregate using the `identify` macro.
  The configured identity will be used for all commands registered to the
  aggregate, unless overridden by a command registration.
  """
  defmacro identify(aggregate_module, opts) do
    quote location: :keep do
      if Map.has_key?(@registered_identities, unquote(aggregate_module)) do
        raise "aggregate #{inspect unquote(aggregate_module)} has already been identified by"
      end

      @registered_identities Map.put(@registered_identities, unquote(aggregate_module), unquote(opts))
    end
  end

  @doc """
  Configure the command, or list of commands, to be dispatched to the
  corresponding handler for a given aggregate root
  """
  defmacro dispatch(command_module_or_modules, opts) do
    opts = parse_opts(opts, [])

    command_module_or_modules
    |> List.wrap()
    |> Enum.map(fn command_module ->
      quote do
        register(unquote(command_module), unquote(opts))
      end
    end)
  end

  @register_params [
    :to,
    :function,
    :aggregate,
    :identity,
    :identity_prefix,
    :timeout,
    :lifespan,
    :consistency,
    :assigns,
  ]

  @doc false
  defmacro register(command_module,
    to: handler,
    function: function,
    aggregate: aggregate,
    identity: identity,
    identity_prefix: identity_prefix,
    timeout: timeout,
    lifespan: lifespan,
    consistency: consistency,
    assigns: _assigns)
  do
    quote location: :keep do
      if Enum.member?(@registered_commands, unquote(command_module)) do
        raise "duplicate command registration for: #{inspect unquote(command_module)}"
      end

      # sanity check the configured modules exist
      ensure_module_exists(unquote(command_module))
      ensure_module_exists(unquote(handler))
      is_nil(unquote(aggregate)) || ensure_module_exists(unquote(aggregate))

      handler_functions = unquote(handler).__info__(:functions)
      unless Keyword.get(handler_functions, unquote(function)) == 2 do
        raise "command handler #{inspect unquote(handler)} does not define a function: #{unquote(function)}/2"
      end

      @registered_commands [unquote(command_module) | @registered_commands]

      @doc """
      Dispatch the given command to the registered handler

      Returns `:ok` on success.
      """
      @spec dispatch(command :: struct) :: :ok | {:error, reason :: term}
      def dispatch(command)
      def dispatch(%unquote(command_module){} = command), do: do_dispatch(command, [])

      @doc """
      Dispatch the given command to the registered handler providing a timeout.

      - `timeout_or_opts` is either an integer timeout or a keyword list of options.
        The timeout must be an integer greater than zero which specifies how
        many milliseconds to allow the command to be handled, or the atom
        `:infinity` to wait indefinitely. The default timeout value is 5000.

        Alternatively, an options keyword list can be provided, it supports:

        Options:

          - `:consistency` as one of `:eventual` (default) or `:strong`
            By setting the consistency to `:strong` a successful command
            dispatch will block until all strongly consistent event handlers and
            process managers have handled all events created by the command.

          - `:timeout` as described above.

          - `:include_aggregate_version` set to true to include the aggregate
            stream version in the success response: `{:ok, aggregate_version}`
            The default is false, to return just `:ok`.

          - `:include_execution_result` set to true to include more information
            about the dispatch, like the aggregate name, uuid, and the produced
            events. Overrides `include_aggregate_version`. The default is false,
            to return just `:ok`. See `Commanded.Commands.Dispatcher.ExecutionResult`.

          - `:metadata` - An optional map containing key/value pairs comprising
            the metadata to be associated with all events created by the command.

      Returns `:ok` on success, unless `:include_aggregate_version` or
      `:include_execution_result` is enabled, where it respectively returns
      `{:ok, aggregate_version}` or `{:ok, execution_result}`.
      """
      @spec dispatch(command :: struct, timeout_or_opts :: integer | :infinity | keyword()) :: :ok | {:error, :consistency_timeout} | {:error, reason :: term}
      def dispatch(command, timeout_or_opts)
      def dispatch(%unquote(command_module){} = command, :infinity), do: do_dispatch(command, timeout: :infinity)
      def dispatch(%unquote(command_module){} = command, timeout) when is_integer(timeout), do: do_dispatch(command, timeout: timeout)
      def dispatch(%unquote(command_module){} = command, opts), do: do_dispatch(command, opts)

      defp do_dispatch(%unquote(command_module){} = command, opts) do
        consistency = Keyword.get(opts, :consistency) || unquote(consistency) || @default_consistency
        metadata = Keyword.get(opts, :metadata) || @default_metadata
        timeout = Keyword.get(opts, :timeout) || unquote(timeout) || @default_dispatch_timeout
        include_aggregate_version = Keyword.get(opts, :include_aggregate_version) || @include_aggregate_version
        include_execution_result = Keyword.get(opts, :include_execution_result) || @include_execution_result
        lifespan = Keyword.get(opts, :lifespan) || unquote(lifespan) || @default_lifespan
        assigns = Map.merge(@default_assigns, Keyword.get(opts, :assigns, %{}))

        default_identity = unquote(identity)
        default_identity_prefix = unquote(identity_prefix)

        {identity, identity_prefix} =
          case Map.get(@registered_identities, unquote(aggregate)) do
            nil ->
              {default_identity, default_identity_prefix}

            config ->
              identity = Keyword.get(config, :by, default_identity)
              prefix = default_identity_prefix || Keyword.get(config, :prefix, default_identity_prefix)

              {identity, prefix}
          end

        Commanded.Commands.Dispatcher.dispatch(%Commanded.Commands.Dispatcher.Payload{
          command: command,
          consistency: consistency,
          handler_module: unquote(handler),
          handler_function: unquote(function),
          aggregate_module: unquote(aggregate),
          identity: identity,
          identity_prefix: identity_prefix,
          include_aggregate_version: include_aggregate_version,
          include_execution_result: include_execution_result,
          timeout: timeout,
          lifespan: lifespan,
          metadata: metadata,
          assigns: assigns,
          middleware: @registered_middleware ++ @default_middleware,
        })
      end
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      @doc """
      Return an error if an unregistered command is dispatched
      """
      def dispatch(command), do: unregistered_command(command)
      def dispatch(command, opts), do: unregistered_command(command)

      defp unregistered_command(command) do
        Logger.error(fn -> "attempted to dispatch an unregistered command: #{inspect command}" end)
        {:error, :unregistered_command}
      end
    end
  end

  @doc false
  def ensure_module_exists(module) do
    unless Code.ensure_compiled?(module) do
      raise "module `#{inspect module}` does not exist, perhaps you forgot to `alias` the namespace"
    end
  end

  defp parse_opts([{:to, aggregate_or_handler} | opts], result) do
    case Keyword.pop(opts, :aggregate) do
      {:no, opts} ->
        handler = aggregate_or_handler
        parse_opts(opts, [function: :handle, to: handler, aggregate: nil] ++ result)
      {nil, opts} ->
        aggregate = aggregate_or_handler
        parse_opts(opts, [function: :execute, to: aggregate, aggregate: aggregate] ++ result)
      {aggregate, opts} ->
        handler = aggregate_or_handler
        parse_opts(opts, [function: :handle, to: handler, aggregate: aggregate] ++ result)
    end
  end

  defp parse_opts([{param, value} | opts], result) when param in @register_params do
    parse_opts(opts, [{param, value} | result])
  end

  defp parse_opts([{param, _value} | _opts], _result) do
    raise """
    unexpected dispatch parameter "#{param}"
    available params are: #{@register_params |> Enum.map(&to_string/1) |> Enum.join(", ")}
    """
  end

  defp parse_opts([], result) do
    Enum.map(@register_params, fn key -> {key, Keyword.get(result, key)} end)
  end
end
