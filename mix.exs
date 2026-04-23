defmodule PhoenixFlags.MixProject do
  use Mix.Project

  @version "0.5.0"
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
      {:phoenix, "~> 1.7", optional: true},
      {:phoenix_html, "~> 4.0", optional: true},
      {:phoenix_ecto, "~> 4.5", optional: true},
      {:phoenix_live_view, "~> 1.0", optional: true},
      {:floki, "~> 0.36", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:postgrex, ">= 0.0.0", optional: true},
      {:igniter, "~> 0.5", optional: true},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.0", only: [:dev, :test], runtime: false},
      {:benchee, "~> 1.3", only: :dev}
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
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv/static .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md", "LICENSE"]
    ]
  end
end
