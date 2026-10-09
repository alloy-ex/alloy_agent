defmodule AlloyAgent.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/alloy-ex/alloy_agent"

  def project do
    [
      app: :alloy_agent,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Supervised OTP runtime for Alloy — sessions, async dispatch, memory stores",
      package: package(),
      docs: docs(),
      dialyzer: [
        plt_local_path: "priv/plts/project.plt",
        plt_core_path: "priv/plts/core.plt",
        # Third-party callers rely on our specs, so hold them to what the
        # code actually returns.
        flags: [:error_handling, :extra_return, :missing_return, :unmatched_returns]
      ],
      test_coverage: [
        # Ratchet: raise as coverage improves, never lower it.
        summary: [threshold: 90],
        ignore_modules: [~r/^AlloyAgent\.Test\./]
      ],
      aliases: aliases(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def cli do
    [preferred_envs: [ci: :test]]
  end

  # `mix ci` runs every gate CI enforces, in the order that fails fastest.
  # Docs build separately (`MIX_ENV=dev mix docs --warnings-as-errors`)
  # because ex_doc is a dev-only dependency.
  defp aliases do
    [
      ci: [
        "format --check-formatted",
        "deps.unlock --check-unused",
        "hex.audit",
        "compile --warnings-as-errors --force",
        "xref graph --format cycles --label compile-connected --fail-above 0",
        "credo",
        "test --warnings-as-errors --cover",
        "dialyzer"
      ]
    ]
  end

  def application do
    [
      mod: {AlloyAgent.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      alloy_dep(),
      {:phoenix_pubsub, "~> 2.1", optional: true},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  # ALLOY_PATH points at a sibling alloy checkout, for developing both
  # packages together before an alloy release reaches Hex.
  defp alloy_dep do
    case System.get_env("ALLOY_PATH") do
      nil -> {:alloy, "~> 0.12.5 or ~> 0.13.0"}
      path -> {:alloy, path: path, override: true}
    end
  end

  defp package do
    [
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE),
      maintainers: ["Chris O'Halloran"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Alloy" => "https://github.com/alloy-ex/alloy"
      }
    ]
  end

  defp docs do
    [
      main: "AlloyAgent",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end
end
