# Default: list recipes
default:
	@just --list

# Build the linpeas package
build:
	nix build .#linpeas

# Run all flake checks (eval, formatting, pre-commit)
check:
	nix flake check

# Format every file via treefmt
fmt:
	nix fmt

# Run pre-commit hooks against all files
lint:
	pre-commit run --all-files

# Run lychee link checker against tracked markdown files
lint-links:
	lychee --config lychee.toml README.md SECURITY.md 'docs/**/*.md'

# Manually refresh linpeas pin from upstream latest release
bump:
	./scripts/bump-linpeas.sh

# Regenerate the <!-- BEGIN/END flake-show --> block in README.md
show:
	./scripts/refresh-flake-show.sh

# Build the OCI image
image:
	nix build .#linpeas-image

# Build the portable bundle for the current arch
bundle:
	nix build .#linpeas-bundle

# Build the Pages site
site:
	nix build "path:$(pwd)#site"

# Live-preview site at http://127.0.0.1:8000 (regenerates data first)
site-dev:
	./scripts/gen-dashboard-data.sh
	mkdocs serve

# Regenerate docs/_data/dashboard.yml standalone
site-data:
	./scripts/gen-dashboard-data.sh
