# Hornbeam v2: HTTP Proxy Architecture

## Overview

This document describes the redesigned architecture for hornbeam that replaces NIF-based marshalling with an HTTP proxy model inspired by nginx and HAProxy.

### Goals

1. Remove NIF marshalling overhead for Python apps
2. Enable body streaming from request start (HAProxy hybrid model)
3. Reuse gunicorn's battle-tested HTTP parser and PROXY v2 implementation
4. Support sendfile() for file responses
5. Keep Erlang routing/arbitration for multi-app and Erlang handler support

### Non-Goals

1. Replace Cowboy (it remains the HTTP frontend)
2. Change the Erlang app handler path (direct Cowboy handlers still work)
3. Support HTTP/2 end-to-end to Python (unnecessary complexity)

## Architecture

```
                           HORNBEAM v2 ARCHITECTURE

┌─────────────────────────────────────────────────────────────────────────────┐
│                              CLIENT                                          │
│                         HTTP/1.1 or HTTP/2                                   │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         COWBOY (Erlang)                                      │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  • Accept HTTP/1.1 and HTTP/2 connections                              │ │
│  │  • TLS termination                                                     │ │
│  │  • HTTP/2 stream demultiplexing                                        │ │
│  │  • Parse request line + headers (minimal)                              │ │
│  │  • Route decision (Erlang handler vs Python app)                       │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────┘
           │                                              │
           │ Erlang Handler                               │ Python App
           ▼                                              ▼
┌──────────────────────┐                  ┌───────────────────────────────────┐
│  Direct Cowboy       │                  │  PROXY BRIDGE (Erlang)            │
│  Handler (existing)  │                  │  ┌─────────────────────────────┐  │
│                      │                  │  │ • Get/create worker conn    │  │
│  • hornbeam_handler  │                  │  │ • Send PROXY v2 header      │  │
│  • Custom handlers   │                  │  │ • Forward HTTP/1.1 request  │  │
│                      │                  │  │ • Stream body via FD        │  │
└──────────────────────┘                  │  │ • Receive response          │  │
                                          │  │ • Translate to HTTP/2 if    │  │
                                          │  │   needed                    │  │
                                          │  └─────────────────────────────┘  │
                                          └───────────────────────────────────┘
                                                          │
                                                          │ Unix socket / TCP
                                                          │ PROXY v2 + HTTP/1.1
                                                          ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                      PYTHON WORKER PROCESS                                   │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  hornbeam_worker.py                                                    │ │
│  │  • Parse PROXY v2 header (gunicorn code)                               │ │
│  │  • Parse HTTP/1.1 request (gunicorn parser)                            │ │
│  │  • Build environ (WSGI) or scope (ASGI)                                │ │
│  │  • Stream body via FD (hybrid model)                                   │ │
│  │  • Run application                                                     │ │
│  │  • Write response to FD (sendfile support)                             │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Components

### 1. Cowboy Frontend (existing, minimal changes)

Cowboy continues to:
- Accept HTTP/1.1 and HTTP/2 connections
- Handle TLS termination
- Parse request headers for routing
- Serve Erlang handlers directly

New behavior for Python apps:
- Route to proxy bridge instead of NIF path
- Don't read body (let Python stream it)

### 2. Proxy Bridge (new Erlang module)

**Module:** `hornbeam_proxy.erl`

Responsibilities:
- Manage connection pool to Python workers
- Send PROXY v2 header with client metadata
- Forward HTTP/1.1 request (translate from HTTP/2 if needed)
- Stream request body chunks
- Receive and forward response
- Handle connection keep-alive

### 3. Python Worker (new Python module)

**Module:** `hornbeam_worker.py`

Responsibilities:
- Accept connections (Unix socket or TCP)
- Parse PROXY v2 header (from gunicorn)
- Parse HTTP/1.1 request (from gunicorn)
- Build WSGI environ or ASGI scope
- Stream request body to application
- Execute WSGI/ASGI application
- Write response (with sendfile support)
- Handle keep-alive

### 4. Worker Pool Manager (new Erlang module)

**Module:** `hornbeam_worker_pool.erl`

Responsibilities:
- Spawn Python worker processes
- Manage worker lifecycle
- Connection pooling (like nginx upstream keepalive)
- Health checks
- Load balancing across workers

## Implementation Phases

### Phase 1: Python Worker Foundation

**Goal:** Create standalone Python HTTP worker using gunicorn components.

**Tasks:**

1. **Extract gunicorn components**
   - `gunicorn/http/message.py` - Request parser with PROXY v2
   - `gunicorn/http/parser.py` - Parser utilities
   - `gunicorn/http/body.py` - Body readers (chunked, length, EOF)
   - `gunicorn/http/wsgi.py` - WSGI response handling
   - `gunicorn/http/errors.py` - HTTP errors

2. **Create `hornbeam_worker.py`**
   ```python
   # Core worker loop
   class Worker:
       def __init__(self, socket_path, app_module, app_callable):
           self.socket_path = socket_path
           self.app = load_app(app_module, app_callable)

       def run(self):
           sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
           sock.bind(self.socket_path)
           sock.listen(128)

           while True:
               conn, _ = sock.accept()
               self.handle_connection(conn)

       def handle_connection(self, conn):
           # Parse PROXY v2 header
           proxy_info = parse_proxy_protocol(conn)

           # Parse HTTP request (streaming body)
           request = Request(cfg, SocketUnreader(conn), proxy_info.client_addr)

           # Build environ with streaming body
           environ = create_environ(request, proxy_info)

           # Run WSGI app
           response = Response(conn)
           result = self.app(environ, response.start_response)
           response.write(result)
   ```

3. **Hybrid body streaming**
   ```python
   class StreamingBody:
       """Body that reads from FD on demand (HAProxy hybrid model)."""

       def __init__(self, fd, content_length=None, chunked=False):
           self.fd = fd
           self.content_length = content_length
           self.chunked = chunked
           self.bytes_read = 0

       def read(self, size=-1):
           # Read directly from FD - no buffering
           if self.content_length:
               remaining = self.content_length - self.bytes_read
               size = min(size, remaining) if size > 0 else remaining

           data = os.read(self.fd, size)
           self.bytes_read += len(data)
           return data
   ```

4. **ASGI support**
   ```python
   class ASGIWorker(Worker):
       async def handle_request(self, request, proxy_info):
           scope = create_scope(request, proxy_info)

           async def receive():
               # Stream body chunks from FD
               chunk = await self.read_body_chunk()
               if chunk:
                   return {"type": "http.request", "body": chunk, "more_body": True}
               return {"type": "http.request", "body": b"", "more_body": False}

           async def send(message):
               if message["type"] == "http.response.start":
                   self.write_response_start(message)
               elif message["type"] == "http.response.body":
                   self.write_response_body(message)

           await self.app(scope, receive, send)
   ```

**Deliverables:**
- `priv/hornbeam_worker.py` - Standalone WSGI/ASGI worker
- `priv/hornbeam_http/` - Extracted gunicorn HTTP components
- Unit tests for HTTP parsing and PROXY v2

### Phase 2: Erlang Proxy Bridge

**Goal:** Create Erlang proxy that connects Cowboy to Python workers.

**Tasks:**

1. **Worker pool manager**
   ```erlang
   %% hornbeam_worker_pool.erl
   -module(hornbeam_worker_pool).

   -export([start_link/1, get_worker/1, return_worker/2]).

   %% Start N Python worker processes
   start_workers(N, AppModule, AppCallable) ->
       SocketDir = filename:join([code:priv_dir(hornbeam), "sockets"]),
       lists:map(fun(I) ->
           SocketPath = filename:join(SocketDir, io_lib:format("worker_~p.sock", [I])),
           spawn_python_worker(SocketPath, AppModule, AppCallable)
       end, lists:seq(1, N)).

   %% Get connection to available worker
   get_worker(Pool) ->
       %% Round-robin or least-connections
       {ok, WorkerConn}.

   %% Return connection for reuse (keepalive)
   return_worker(Pool, Conn) ->
       %% Add back to pool if healthy
       ok.
   ```

2. **PROXY v2 encoder**
   ```erlang
   %% hornbeam_proxy_protocol.erl
   -module(hornbeam_proxy_protocol).

   -export([encode_v2/1]).

   -define(PP_V2_SIGNATURE, <<13,10,13,10,0,13,10,81,85,73,84,10>>).

   encode_v2(#{client_addr := {A,B,C,D}, client_port := CPort,
               server_addr := {E,F,G,H}, server_port := SPort}) ->
       %% Version 2, PROXY command, TCP over IPv4
       VerCmd = 16#21,
       FamProto = 16#11,  % INET + STREAM
       AddrLen = 12,      % 4+4+2+2

       <<?PP_V2_SIGNATURE/binary,
         VerCmd:8, FamProto:8, AddrLen:16/big,
         A:8, B:8, C:8, D:8,      % src addr
         E:8, F:8, G:8, H:8,      % dst addr
         CPort:16/big,            % src port
         SPort:16/big>>.          % dst port
   ```

3. **HTTP/1.1 request forwarding**
   ```erlang
   %% hornbeam_proxy.erl
   -module(hornbeam_proxy).

   -export([forward_request/3]).

   forward_request(Req, WorkerConn, ProxyInfo) ->
       %% Send PROXY v2 header
       ProxyHeader = hornbeam_proxy_protocol:encode_v2(ProxyInfo),
       gen_tcp:send(WorkerConn, ProxyHeader),

       %% Build HTTP/1.1 request line
       Method = cowboy_req:method(Req),
       Path = cowboy_req:path(Req),
       Qs = cowboy_req:qs(Req),
       FullPath = case Qs of
           <<>> -> Path;
           _ -> <<Path/binary, "?", Qs/binary>>
       end,
       RequestLine = <<Method/binary, " ", FullPath/binary, " HTTP/1.1\r\n">>,
       gen_tcp:send(WorkerConn, RequestLine),

       %% Forward headers
       Headers = cowboy_req:headers(Req),
       lists:foreach(fun({Name, Value}) ->
           gen_tcp:send(WorkerConn, [Name, <<": ">>, Value, <<"\r\n">>])
       end, maps:to_list(Headers)),
       gen_tcp:send(WorkerConn, <<"\r\n">>),

       %% Stream body
       stream_body(Req, WorkerConn).

   stream_body(Req, WorkerConn) ->
       case cowboy_req:read_body(Req, #{length => 65536, period => 5000}) of
           {ok, Data, Req2} ->
               gen_tcp:send(WorkerConn, Data),
               {ok, Req2};
           {more, Data, Req2} ->
               gen_tcp:send(WorkerConn, Data),
               stream_body(Req2, WorkerConn)
       end.
   ```

4. **Response handling**
   ```erlang
   receive_response(WorkerConn, Req) ->
       %% Read response status and headers
       {ok, Status, Headers} = read_response_headers(WorkerConn),

       %% Stream response body to client
       Req2 = cowboy_req:stream_reply(Status, Headers, Req),
       stream_response_body(WorkerConn, Req2).
   ```

**Deliverables:**
- `src/hornbeam_proxy.erl` - Request forwarding
- `src/hornbeam_proxy_protocol.erl` - PROXY v2 encoding
- `src/hornbeam_worker_pool.erl` - Worker management
- Integration tests

### Phase 3: FD-based Streaming (Reactor Integration)

**Goal:** Use erlang-python reactor for direct FD I/O instead of TCP.

**Tasks:**

1. **FD handoff from Cowboy**
   ```erlang
   %% For HTTP/1.1: hand off the client socket FD directly
   handle_http1_request(Req, State) ->
       %% Get raw socket FD from Cowboy
       {ok, Transport, Socket} = cowboy_req:sock(Req),
       {ok, Fd} = inet:getfd(Socket),

       %% Duplicate FD for Python ownership
       {ok, PyFd} = py:dup_fd(Fd),

       %% Hand off to Python reactor context
       ClientInfo = #{
           addr => cowboy_req:peer(Req),
           method => cowboy_req:method(Req),
           path => cowboy_req:path(Req),
           headers => cowboy_req:headers(Req),
           http_version => cowboy_req:version(Req)
       },

       %% Python takes over the connection
       py_reactor_context:handoff(PyFd, ClientInfo).
   ```

2. **Python reactor protocol for HTTP**
   ```python
   # hornbeam_http_protocol.py
   import erlang.reactor as reactor
   from hornbeam_http import Request, parse_proxy_v2

   class HTTPProtocol(reactor.Protocol):
       def __init__(self):
           super().__init__()
           self.parser_state = "proxy_header"
           self.request_buffer = bytearray()
           self.app = None  # Set by factory

       def connection_made(self, fd, client_info):
           super().connection_made(fd, client_info)
           # Client info already has headers from Cowboy
           self.cowboy_info = client_info

       def data_received(self, data):
           self.request_buffer.extend(data)

           if self.parser_state == "proxy_header":
               if self.parse_proxy_header():
                   self.parser_state = "http_request"

           if self.parser_state == "http_request":
               if self.parse_http_request():
                   self.parser_state = "body"

           if self.parser_state == "body":
               return self.handle_body()

           return "continue"

       def handle_body(self):
           # Build environ with streaming body reader
           environ = self.build_environ()
           environ['wsgi.input'] = FDBodyReader(self.fd, self.content_length)

           # Run WSGI app
           response = Response(self)
           result = self.app(environ, response.start_response)
           response.finish(result)

           if self.keep_alive:
               self.reset()
               return "read_pending"
           return "close"
   ```

3. **Sendfile support**
   ```python
   class Response:
       def write_file(self, file_path):
           """Use sendfile() for efficient file transfer."""
           with open(file_path, 'rb') as f:
               file_fd = f.fileno()
               offset = 0
               size = os.path.getsize(file_path)

               while offset < size:
                   sent = os.sendfile(self.socket_fd, file_fd, offset, size - offset)
                   offset += sent
   ```

**Deliverables:**
- `priv/hornbeam_http_protocol.py` - Reactor-based HTTP protocol
- `src/hornbeam_fd_proxy.erl` - FD handoff for HTTP/1.1
- Benchmarks comparing TCP vs FD approaches

### Phase 4: HTTP/2 Translation

**Goal:** Translate HTTP/2 streams to HTTP/1.1 for Python workers.

**Tasks:**

1. **HTTP/2 stream collection**
   ```erlang
   %% For HTTP/2: collect stream, translate to HTTP/1.1
   handle_http2_request(Req, State) ->
       %% Read complete request (HTTP/2 framing handled by Cowboy)
       {ok, Body, Req2} = cowboy_req:read_body(Req),

       %% Get worker connection
       {ok, WorkerConn} = hornbeam_worker_pool:get_worker(State#state.pool),

       %% Send as HTTP/1.1
       forward_as_http1(Req2, Body, WorkerConn),

       %% Read response and translate back to HTTP/2
       receive_and_stream_response(WorkerConn, Req2, State).
   ```

2. **Chunked encoding for streaming**
   ```erlang
   %% Stream HTTP/2 DATA frames as HTTP/1.1 chunked
   stream_http2_body_as_chunked(Req, WorkerConn) ->
       cowboy_req:read_body(Req, #{
           period => infinity,
           timeout => 30000
       }, fun
           ({ok, Data, Req2}) ->
               %% Last chunk
               send_chunk(WorkerConn, Data),
               send_chunk(WorkerConn, <<>>),  % Terminal chunk
               {ok, Req2};
           ({more, Data, Req2}) ->
               send_chunk(WorkerConn, Data),
               stream_http2_body_as_chunked(Req2, WorkerConn)
       end).

   send_chunk(Conn, Data) ->
       Size = integer_to_binary(byte_size(Data), 16),
       gen_tcp:send(Conn, [Size, <<"\r\n">>, Data, <<"\r\n">>]).
   ```

**Deliverables:**
- HTTP/2 to HTTP/1.1 translation in `hornbeam_proxy.erl`
- Tests for HTTP/2 streaming scenarios

### Phase 5: Handler Router Update

**Goal:** Update hornbeam_handler to route Python apps through proxy.

**Tasks:**

1. **Router decision**
   ```erlang
   init(Req, #{handler_type := Type} = State) ->
       case Type of
           erlang ->
               %% Direct Cowboy handler (existing path)
               handle_erlang_app(Req, State);
           python_wsgi ->
               %% Proxy to Python worker (new path)
               hornbeam_proxy:handle_wsgi(Req, State);
           python_asgi ->
               %% Proxy to Python worker (new path)
               hornbeam_proxy:handle_asgi(Req, State)
       end.
   ```

2. **Configuration update**
   ```erlang
   %% New config options
   #{
       %% Worker pool settings
       python_workers => 4,
       worker_connections => 100,  % keepalive pool per worker
       worker_socket_type => unix, % unix | tcp

       %% Proxy settings
       proxy_buffer_size => 65536,
       proxy_timeout => 30000,

       %% Backward compatibility
       use_legacy_nif => false  % Set true to use old path
   }
   ```

**Deliverables:**
- Updated `hornbeam_handler.erl` with proxy routing
- Updated `hornbeam_config.erl` with new options
- Migration guide

### Phase 6: WebSocket and ASGI Lifespan

**Goal:** Handle WebSocket upgrades and ASGI lifespan through proxy.

**Tasks:**

1. **WebSocket FD handoff**
   ```erlang
   %% After Cowboy handles WebSocket upgrade, hand off to Python
   websocket_init(State) ->
       %% Get socket FD
       {ok, Fd} = get_websocket_fd(State),
       {ok, PyFd} = py:dup_fd(Fd),

       %% Python handles WebSocket protocol from here
       py_reactor_context:handoff(PyFd, #{
           type => websocket,
           subprotocol => State#state.subprotocol
       }),

       %% Cowboy process exits, Python owns connection
       {stop, State}.
   ```

2. **ASGI lifespan over control socket**
   ```erlang
   %% Lifespan messages over separate control channel
   send_lifespan_startup(WorkerConn) ->
       Msg = jsx:encode(#{type => <<"lifespan.startup">>}),
       gen_tcp:send(WorkerConn, [<<"LIFESPAN ">>, Msg, <<"\n">>]).
   ```

**Deliverables:**
- WebSocket FD handoff
- ASGI lifespan over control channel
- Tests for WebSocket and lifespan

## File Structure

```
hornbeam/
├── src/
│   ├── hornbeam_proxy.erl           # NEW: HTTP proxy forwarding
│   ├── hornbeam_proxy_protocol.erl  # NEW: PROXY v2 encoder
│   ├── hornbeam_worker_pool.erl     # NEW: Worker management
│   ├── hornbeam_fd_proxy.erl        # NEW: FD-based proxy (reactor)
│   ├── hornbeam_handler.erl         # MODIFIED: Route to proxy
│   └── ...
├── priv/
│   ├── hornbeam_worker.py           # NEW: Python HTTP worker
│   ├── hornbeam_http_protocol.py    # NEW: Reactor HTTP protocol
│   ├── hornbeam_http/               # NEW: Extracted gunicorn HTTP
│   │   ├── __init__.py
│   │   ├── message.py               # Request parser + PROXY v2
│   │   ├── parser.py
│   │   ├── body.py
│   │   ├── wsgi.py
│   │   └── errors.py
│   └── ...
└── docs/
    └── design/
        └── http-proxy-architecture.md  # This document
```

## Migration Path

### Backward Compatibility

The `use_legacy_nif` config option allows gradual migration:

```erlang
%% Phase 1: Default to legacy, opt-in to proxy
hornbeam:start(#{
    app => "myapp:application",
    use_legacy_nif => true  % default
}).

%% Phase 2: Default to proxy, opt-out to legacy
hornbeam:start(#{
    app => "myapp:application",
    use_legacy_nif => false  % new default
}).

%% Phase 3: Remove legacy path
```

### Performance Validation

Before removing legacy path:
1. Benchmark proxy vs NIF for various workloads
2. Validate streaming performance
3. Test under high concurrency
4. Measure memory usage

## Open Questions

1. **Unix socket vs TCP for workers?**
   - Unix sockets: Lower overhead, same-host only
   - TCP: Remote workers possible, slightly higher overhead
   - Recommendation: Unix sockets default, TCP optional

2. **Worker process model?**
   - Option A: Long-lived workers with connection pooling (like nginx)
   - Option B: Worker per request (simpler but higher overhead)
   - Recommendation: Option A (nginx model)

3. **HTTP/2 body streaming latency?**
   - Full body buffering: Simple, higher latency
   - Chunked translation: Complex, lower latency
   - Recommendation: Start with buffering, add chunked later

4. **Keep erlang-python NIF for callbacks?**
   - WSGI/ASGI go through HTTP proxy
   - Python-to-Erlang callbacks (RPC, state) stay via NIF
   - This is the recommended hybrid approach

## Timeline Estimate

| Phase | Description | Complexity |
|-------|-------------|------------|
| 1 | Python worker foundation | Medium |
| 2 | Erlang proxy bridge | Medium |
| 3 | FD-based streaming | High |
| 4 | HTTP/2 translation | Medium |
| 5 | Handler router update | Low |
| 6 | WebSocket and lifespan | Medium |

## References

- [nginx HTTP/2 Module](https://nginx.org/en/docs/http/ngx_http_v2_module.html)
- [HAProxy Architecture](https://www.haproxy.org/download/2.4/doc/architecture.txt)
- [PROXY Protocol v2 Spec](https://www.haproxy.org/download/1.8/doc/proxy-protocol.txt)
- [gunicorn HTTP Parser](https://github.com/benoitc/gunicorn/tree/master/gunicorn/http)
- [erlang-python Reactor](../erlang-python/reactor.md)
