defmodule CommonplaceAttributeMap.MixProject do
  use Mix.Project

  def project do
    [
      app: :commonplace_attribute_map,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp elixirc_paths(:test),
    do: ["lib", "test/support", Path.expand("../test_support", __DIR__)]

  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:commonplace_log_reducer, path: "../commonplace_log_reducer"},
      {:jason, "~> 1.4"},
      {:stream_data, "~> 1.1", only: [:test, :dev]}
    ]
  end
end
