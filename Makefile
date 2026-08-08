SHELL := /usr/bin/env bash

.PHONY: test syntax shellcheck compose package

test:
	@bash tests/run-all.sh

syntax:
	@bash tests/syntax.sh
	@bash tests/whitespace.sh
	@bash tests/security-order.sh
	@bash tests/monitoring.sh
	@bash tests/profile-ipv4.sh
	@bash tests/upgrade.sh
	@bash tests/docs.sh
	@bash tests/release-metadata.sh
	@bash tests/publisher.sh
	@bash tests/package.sh

shellcheck:
	@if command -v shellcheck >/dev/null; then \
		find . -type f -name '*.sh' -not -path './release/*' -print0 | xargs -0 shellcheck; \
	else \
		echo "shellcheck not installed; skipping"; \
	fi

compose:
	@if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then \
		cp -n docker/.env.example docker/.env 2>/dev/null || true; \
		cp native/config/warp-gateway.env.example docker/generated/warp-gateway.env; \
		docker compose -f docker/compose.yaml config >/dev/null; \
		rm -f docker/generated/warp-gateway.env; \
	else \
		echo "docker compose not available; skipping compose validation"; \
	fi

package:
	@bash scripts/package-release.sh
