defmodule AlloyAgent do
  @moduledoc """
  Supervised OTP runtime for [Alloy](https://hex.pm/packages/alloy).

  `alloy_agent` wraps Alloy's pure loop (`Alloy.run/2`) in a GenServer
  that holds conversation state, handles async dispatch with
  backpressure, broadcasts results over PubSub, and ships default
  memory stores. Use it when you want an agent running in your
  supervision tree; use plain `Alloy.run/2` when you want the loop as
  a pure function.

  ## Quick start

      {:ok, pid} = AlloyAgent.start_link(
        provider: {Alloy.Provider.Anthropic, api_key: key, model: "claude-sonnet-4-6"},
        tools: [Alloy.Tool.Core.Read, Alloy.Tool.Core.Write],
        system_prompt: "You are a helpful assistant."
      )

      {:ok, result} = AlloyAgent.chat(pid, "Read mix.exs and tell me the version")

  ## Division of responsibility

  - **Alloy** owns the protocol: loop, providers, tools, memory
    behaviour, compaction mechanism. Pure functions. Use
    `Alloy.run/2` directly when you don't need process ownership.
  - **AlloyAgent** owns the runtime: supervised process, session state,
    PubSub broadcast, backpressure, default memory stores, fallback
    provider chains, cost guard. Elixir has OTP — use it.

  See `AlloyAgent.Server` for the full client API.
  """

  alias AlloyAgent.Server

  @type result :: Alloy.Result.t()

  @doc """
  Start a supervised, persistent agent process. Delegates to
  `AlloyAgent.Server.start_link/1`.
  """
  defdelegate start_link(opts), to: Server

  @doc """
  Send a message and wait for the agent to finish its loop.
  """
  defdelegate chat(server, message, opts \\ []), to: Server

  @doc """
  Stream text deltas from the agent as they arrive.
  """
  defdelegate stream_chat(server, message, on_chunk, opts \\ []), to: Server

  @doc """
  Fire a non-blocking async request; result delivered via PubSub.
  """
  defdelegate send_message(server, message, opts \\ []), to: Server

  @doc """
  Cancel an async request by `request_id`.
  """
  defdelegate cancel_request(server, request_id), to: Server

  @doc """
  Return the full conversation history.
  """
  defdelegate messages(server), to: Server

  @doc """
  Return accumulated token usage across all turns.
  """
  defdelegate usage(server), to: Server

  @doc """
  Clear conversation history. Config and tools are preserved.
  """
  defdelegate reset(server), to: Server

  @doc """
  Switch the provider mid-session.
  """
  defdelegate set_model(server, provider_opts), to: Server

  @doc """
  Export the current conversation as a serializable Session struct.
  """
  defdelegate export_session(server), to: Server

  @doc """
  Health summary map for the agent process.
  """
  defdelegate health(server), to: Server

  @doc """
  Stop the agent process.
  """
  defdelegate stop(server), to: Server
end
