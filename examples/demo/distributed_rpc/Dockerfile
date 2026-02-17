# Distributed RPC Demo - Cluster Node
#
# Builds a hornbeam node that can participate in an Erlang cluster.

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

# Create Python venv
RUN python3 -m venv /app/venv
ENV PATH="/app/venv/bin:$PATH"
ENV VIRTUAL_ENV="/app/venv"

# Copy hornbeam source
WORKDIR /build
COPY . /build/hornbeam

# Set up distributed_rpc directory
WORKDIR /build/hornbeam/examples/demo/distributed_rpc

# Clean any local build artifacts and create _checkouts symlink
RUN rm -rf _checkouts _build rebar.lock && \
    rm -rf /build/hornbeam/_build && \
    mkdir -p _checkouts && ln -s /build/hornbeam _checkouts/hornbeam

# Install Python dependencies
RUN pip install --no-cache-dir fastapi uvicorn pydantic

# Build hornbeam (needed for the release)
WORKDIR /build/hornbeam
RUN rebar3 compile

# Compile the inference module for the demo
WORKDIR /build/hornbeam/examples/demo/distributed_rpc
RUN mkdir -p ebin && erlc -o ebin src/inference.erl

# Copy startup script
COPY examples/demo/distributed_rpc/start_node.sh /app/start_node.sh
RUN chmod +x /app/start_node.sh

# Expose port
EXPOSE 8000

# Start the node
WORKDIR /build/hornbeam
CMD ["/app/start_node.sh"]
