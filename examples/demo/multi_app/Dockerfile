# Multi-App Demo Dockerfile
# Builds Hornbeam multi-app demo with per-mount virtual environments

FROM erlang:28

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

# Copy Hornbeam source
WORKDIR /build
COPY . /build/hornbeam

# Set up example directory
WORKDIR /build/hornbeam/examples/demo/multi_app

# Clean any local build artifacts and create _checkouts symlink
RUN rm -rf _checkouts _build rebar.lock && \
    rm -rf /build/hornbeam/_build && \
    mkdir -p _checkouts && ln -s /build/hornbeam _checkouts/hornbeam

# Create virtual environments for each app
RUN python3 -m venv priv/api/venv && \
    priv/api/venv/bin/pip install --no-cache-dir -r priv/api/requirements.txt

RUN python3 -m venv priv/admin/venv && \
    priv/admin/venv/bin/pip install --no-cache-dir -r priv/admin/requirements.txt

# Build the release
RUN rebar3 release

# Expose port
EXPOSE 8000

# Start the release
CMD ["/build/hornbeam/examples/demo/multi_app/_build/default/rel/multi_app/bin/multi_app", "foreground"]
