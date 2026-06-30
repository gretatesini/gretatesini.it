import 'walle.justfile'

# Default recipe that lists available commands
default:
    just --list

import:
    chmod +x ./scripts/import-database.sh
    ./scripts/import-database.sh
