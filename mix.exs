defmodule Inspex.MixProject do
  use Mix.Project

  def project do
    [
      app: :inspex,
      version: "0.2.0-dev",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Clojure spec-inspired validation for Elixir"
    ]
  end

  def application do
    [
      mod: {Inspex.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      # Step 4: {:stream_data, "~> 1.1", only: [:dev, :test]}
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
