# Hornbeam Docker Image
# Erlang/OTP + Python runtime for WSGI/ASGI applications

FROM erlang:26 AS builder

# Install build dependencies
RUN apt-get update && apt-get install -y \
    git \
    python3 \
    python3-dev \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

# Install rebar3
RUN wget https://s3.amazonaws.com/rebar3/rebar3 && chmod +x rebar3 && mv rebar3 /usr/local/bin/

WORKDIR /app

# Copy source
COPY rebar.config rebar.lock ./
COPY src ./src
COPY priv ./priv
COPY config ./config

# Build release
RUN rebar3 release

# Runtime image
FROM erlang:26-slim

RUN apt-get update && apt-get install -y \
    python3 \
    python3-pip \
    python3-venv \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy release from builder
COPY --from=builder /app/_build/default/rel/hornbeam /app/hornbeam

# Copy examples
COPY examples /app/examples

# Create Python virtual environment
RUN python3 -m venv /app/venv
ENV PATH="/app/venv/bin:$PATH"

# Default port
EXPOSE 8000

# Environment variables
ENV HORNBEAM_PORT=8000
ENV PYTHONPATH=/app/examples

# Start script
COPY <<'EOF' /app/start.sh
#!/bin/bash
set -e

# Install Python dependencies if requirements.txt exists
if [ -f "$APP_DIR/requirements.txt" ]; then
    pip install -r "$APP_DIR/requirements.txt"
fi

# Start Hornbeam
exec /app/hornbeam/bin/hornbeam foreground
EOF

RUN chmod +x /app/start.sh

CMD ["/app/start.sh"]
