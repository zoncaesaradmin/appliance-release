# Metadata Bundle Contract Fixture

This example is the release-side contract fixture for the Automation Runtime
metadata bundle layout.

It is intentionally small and illustrative:

- it shows the required top-level section shape
- it includes one `debug-tools` automation example
- it keeps `mcp-tools/` present as a named section without defining the MCP
  payload contract yet
- it is not a signed artifact and is not the packaging source of truth for the
  product build

Use this fixture to review bundle structure, sample DSL layout, and schema
placement before the runtime implementation consumes equivalent content from the
real metadata-bundle generator in `appliance-code`.
