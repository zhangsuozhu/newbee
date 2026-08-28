defmodule Newbee.MixProject do
  use Mix.Project

  def project do
    [
      app: :newbee,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Newbee.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:jason, "~> 1.0"},
      {:req, "~> 0.5"},
{:sourceror, "~> 1.0"},
{:bandit, "~> 1.5"},
{:websock_adapter, "~> 0.5"},
      {:wax_, "~> 0.7"}
    ]
  end
end
