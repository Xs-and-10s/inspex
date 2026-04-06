defmodule Inspex.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/Xs-and-10s/inspex"

  def project do
    [
      app:               :inspex,
      version:           @version,
      elixir:            "~> 1.17",
      start_permanent:   Mix.env() == :prod,
      deps:              deps(),
      description:       description(),
      package:           package(),
      docs:              docs(),
      name:              "Inspex",
      source_url:        @source_url,
      homepage_url:      @source_url,
      aliases:           aliases()
    ]
  end

  def application do
    [
      mod:                {Inspex.Application, []},
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
      name:        "inspex",
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
        "Core":       [Inspex],
        "Types":      [Inspex.Spec, Inspex.All, Inspex.Any, Inspex.Not,
                       Inspex.Maybe, Inspex.Ref, Inspex.ListOf, Inspex.Cond,
                       Inspex.Schema, Inspex.SchemaKey],
        "Errors":     [Inspex.Error, Inspex.ExplainResult,
                       Inspex.ConformError, Inspex.SignatureError],
        "Signature":  [Inspex.Signature],
        "Typespec":   [Inspex.Typespec],
        "Internals":  [Inspex.Registry, Inspex.Coercions,
                       Inspex.Constraints, Inspex.Gen]
      ]
    ]
  end

  defp deps do
    [
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
