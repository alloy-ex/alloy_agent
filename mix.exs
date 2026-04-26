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
        plt_core_path: "priv/plts/core.plt"
      ],
      elixirc_paths: elixirc_paths(Mix.env())
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
      {:alloy, "~> 0.12.2"},
      {:jason, "~> 1.2"},
      {:telemetry, "~> 1.0"},
      {:phoenix_pubsub, "~> 2.1", optional: true},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
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
