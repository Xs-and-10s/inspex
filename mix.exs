defmodule Gladius.MixProject do
  use Mix.Project

  @version "0.3.0"
  @source_url "https://github.com/Xs-and-10s/gladius"

  def project do
    [
      app:               :gladius,
      version:           @version,
      elixir:            "~> 1.17",
      start_permanent:   Mix.env() == :prod,
      deps:              deps(),
      description:       description(),
      package:           package(),
      docs:              docs(),
      name:              "Gladius",
      source_url:        @source_url,
      homepage_url:      @source_url,
      aliases:           aliases()
    ]
  end

  def application do
    [
      mod:                {Gladius.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp description do
    """
    Clojure spec-inspired validation and parsing for Elixir. Parse, don't
    validate — conform/2 returns a shaped value on success, not just true.
    Composable spec algebra, named constraints, coercion pipelines, property-
    based generators, function signature checking, and typespec bridge.
    """
  end

  defp package do
    [
      name:        "gladius",
      licenses:    ["MIT"],
      links:       %{
        "GitHub"    => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      },
      files:       ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main:            "readme",
      source_ref:      "v#{@version}",
      source_url:      @source_url,
      extras:          ["README.md", "CHANGELOG.md"],
      groups_for_modules: [
        "Core":       [Gladius],
        "Types":      [Gladius.Spec, Gladius.All, Gladius.Any, Gladius.Not,
                       Gladius.Maybe, Gladius.Ref, Gladius.ListOf, Gladius.Cond,
                       Gladius.Schema, Gladius.SchemaKey],
        "Errors":     [Gladius.Error, Gladius.ExplainResult,
                       Gladius.ConformError, Gladius.SignatureError],
        "Signature":  [Gladius.Signature],
        "Typespec":   [Gladius.Typespec],
        "Internals":  [Gladius.Registry, Gladius.Coercions,
                       Gladius.Constraints, Gladius.Gen]
      ]
    ]
  end

  defp deps do
    [
      {:ecto, "~> 3.0", optional: true},
      {:stream_data, "~> 1.1",  only: [:dev, :test]},
      {:ex_doc,      "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      "hex.release": ["hex.build", "hex.publish"]
    ]
  end
end
