[
  import_deps: [
    :ash_authentication,
    :ash_paper_trail,
    :ash_phoenix,
    :ash_postgres,
    :ash,
    :reactor,
    :phoenix
  ],
  inputs: ["*.{ex,exs}", "{config,lib,test}/**/*.{ex,exs}"],
  plugins: [Spark.Formatter]
]
