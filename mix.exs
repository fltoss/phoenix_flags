defmodule PhoenixFlags.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/fltoss/phoenix_flags"

  def project do
    [
      app: :phoenix_flags,
      version: @version,
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      elixirc_paths: elixirc_paths(Mix.env()),
      name: "PhoenixFlags",
      description: "Database-backed, cached, cluster-aware system configuration for Phoenix.",
      package: package(),
      docs: docs(),
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ecto_sql, "~> 3.10"},
      {:decimal, "~> 2.0"},
      {:jason, "~> 1.4"},
      {:postgrex, ">= 0.0.0", optional: true},
      {:igniter, "~> 0.5", optional: true},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "PhoenixFlags",
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end
end
