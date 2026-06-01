.PHONY: compile test ct docker-smoke

compile:
	rebar3 compile

test ct:
	rebar3 ct

# Smoke-test every Dockerfile builds. Set DOCKER_SMOKE_HEAVY=1 to also
# build the ml_caching image (slow, downloads sentence-transformers).
docker-smoke:
	scripts/docker_smoke.sh
