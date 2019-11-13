defmodule Cloister.Actor do
  @moduledoc ~s"""

  > - **Client** The _Client_ issues a request to the distributed system, and waits
  for a response. For instance, a write request on a file in a distributed file server.
  > - **Acceptor** (**Voters**) The _Acceptors_ act as the fault-tolerant "memory"
  of the protocol. _Acceptors_ are collected into groups called _Quorums_.
  Any message sent to an _Acceptor_ must be sent to a _Quorum_ of _Acceptors_.
  Any message received from an _Acceptor_ is ignored unless a copy is received
  from each _Acceptor_ in a _Quorum_.
  > - **Proposer** A _Proposer_ advocates a client request, attempting to convince
  the _Acceptors_ to agree on it, and acting as a coordinator to move the protocol
  forward when conflicts occur.
  > - **Learner** _Learners_ act as the replication factor for the protocol.
  Once a _Client_ request has been agreed upon by the _Acceptors_, the _Learner_
  may take action (i.e.: execute the request and send a response to the client).
  To improve availability of processing, additional _Learners_ can be added.
  > - **Leader** [Paxos](https://en.wikipedia.org/wiki/Paxos_(computer_science)#Basic_Paxos)
  requires a distinguished _Proposer_ (called the leader) to make progress.
  Many processes may believe they are leaders, but the protocol only guarantees
  progress if one of them is eventually chosen. If two processes believe they are
  leaders, they may stall the protocol by continuously proposing conflicting updates.
  However, the safety properties are still preserved in that case.
  """

  @roles [:client, :acceptor, :proposer, :learner, :leader]
  @messages [:prepare]

  defmodule State do
    defstruct otp_app: :cloister, roles: [], payload: %{}
  end

  defmacro __using__(opts) do
    roles =
      case opts[:roles] do
        nil -> @roles
        role when role in @roles -> [role]
        [_ | _] = roles -> roles
        _ -> raise "roles: must be a list of one or more " <> inspect(@roles)
      end

    delegates = [
      quote do
        alias Cloister.Actor.State
        alias Cloister.Message.{Prepare}

        @impl GenServer
        def handle_call({action, message}, _from, %State{} = state)
            when action in unquote(@messages) do
          feedback =
            case action do
              :prepare ->
                {response, state} = perform_prepare(state)
                {:reply, response, state}
            end
        end

        def perform_prepare(%State{} = state), do: {state, state}
        defoverridable perform_prepare: 1
      end
      | Enum.map(roles, fn role ->
          mod = Module.concat("Cloister.Actors", role |> to_string() |> Macro.camelize())
          quote do: use(unquote(mod), name: Keyword.get(unquote(opts), :name, __MODULE__))
        end)
    ]

    [
      quote location: :keep, generated: true do
        use GenServer

        @name Keyword.get(unquote(opts), :name, __MODULE__)

        def start_link(%{} = payload) do
          GenServer.start_link(
            __MODULE__,
            %State{
              otp_app: Keyword.get(unquote(opts), :otp_app, :cloister),
              roles: unquote(roles),
              payload: Map.merge(payload, %State{}.payload)
            },
            name: @name
          )
        end

        def state, do: GenServer.call(@name, :state)
        def roles, do: GenServer.call(@name, :state).roles

        @impl GenServer
        def init(state), do: {:ok, state, {:continue, :quorum}}

        @impl GenServer
        def handle_continue(:quorum, %{} = state) do
          {:noreply, state}
          # active_sentry =
          #   for sentry <- Application.fetch_env!(state.otp_app, :sentry),
          #       Node.connect(sentry),
          #       do: sentry

          # if active_sentry,
          #   do: {:noreply, %State{state | ready: true}},
          #   else: {:noreply, state, {:continue, :quorum}}
        end

        @impl GenServer
        def handle_info({action, message}, state) do
          IO.inspect({{action, message}, state}, label: "State")
          {:noreply, state}
        end

        @impl GenServer
        def handle_call(:state, _from, state), do: {:reply, state, state}
      end
      | delegates
    ]
  end
end
