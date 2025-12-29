# Monorepo Fixture

This fixture simulates a monorepo where:
- The root directory is NOT an Elixir project (no mix.exs)
- The actual Elixir project is in a subdirectory (`backend/`)

This is used to test Expert's behavior when opened at the monorepo root
rather than the actual Elixir project directory.
