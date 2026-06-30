cli_filename := "./scripts/@walle/cli.sh"

# Install dependencies and validate consumer configs
walle-setup:
    just yarn install
    just validate-configs

# Walle cli
walle *args:
    {{cli_filename}} {{args}}

# Validate the consumer against the walle manifest
walle-check:
    {{cli_filename}} check

# Walle update design system
walle-update *args:
    curl -fsSL https://raw.githubusercontent.com/FabrizioCafolla/walle-design-system/main/scripts/@walle/cli.sh -o {{cli_filename}}
    chmod +x {{cli_filename}}
    just walle update {{args}}

# Run yarn commands
yarn *args:
    yarn {{args}}

# Validate consumer configs against the published JSON Schemas
validate-configs:
    node ./scripts/@walle/validate-configs.mjs

# Start development server
dev:
    just yarn "dev --host"

# Build the project
build:
    just yarn install
    just yarn build
