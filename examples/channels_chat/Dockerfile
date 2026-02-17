# Channels Chat Example Dockerfile
# Runs Hornbeam with Phoenix-style channels

FROM erlang:27

# Install Python and build tools
RUN apt-get update && apt-get install -y \
    python3 \
    python3-dev \
    python3-pip \
    python3-venv \
    git \
    wget \
    cmake \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Install rebar3
RUN wget -q https://s3.amazonaws.com/rebar3/rebar3 && chmod +x rebar3 && mv rebar3 /usr/local/bin/

# Create Python venv
RUN python3 -m venv /app/venv
ENV PATH="/app/venv/bin:$PATH"
ENV VIRTUAL_ENV="/app/venv"

# Copy Hornbeam source
WORKDIR /app
COPY . /app/hornbeam

# Build Hornbeam
WORKDIR /app/hornbeam
# Clean any local build artifacts that might have been copied
RUN rm -rf _build rebar.lock
RUN rebar3 compile

# Set up Python path
ENV PYTHONPATH="/app/hornbeam/priv:/app/hornbeam/examples/channels_chat"

# Create startup script
RUN cat > /app/start.sh << 'EOF'
#!/bin/bash
cd /app/hornbeam
exec erl -pa _build/default/lib/*/ebin \
    -config config/sys.config \
    -eval "application:ensure_all_started(hornbeam), hornbeam:start(\"app:app\", #{bind => <<\"0.0.0.0:9004\">>, worker_class => asgi, pythonpath => [\"/app/hornbeam/priv\", \"/app/hornbeam/examples/channels_chat\"]})." \
    -noshell
EOF
RUN chmod +x /app/start.sh

# Expose port
EXPOSE 9004

# Start
CMD ["/app/start.sh"]
