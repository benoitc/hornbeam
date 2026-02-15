# Embedding Chat

A full Erlang application demonstrating:
- Erlang-Python binding for sentence-transformers
- FastAPI ASGI app calling Erlang hooks via `execute()`
- Pure Erlang WebSocket handler (cowboy_websocket)
- Custom Cowboy routes in hornbeam

## Requirements

```bash
pip install sentence-transformers fastapi
```

## Building

```bash
cd examples/embedding_chat
rebar3 compile
```

## Running

```bash
# Start Erlang shell with application
rebar3 shell

# Or start manually
erl -pa _build/default/lib/*/ebin
> application:ensure_all_started(embedding_chat).
```

The server starts on http://localhost:8000

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/embed` | POST | Get embeddings for texts |
| `/similarity` | POST | Compute similarity between two texts |
| `/find_similar` | POST | Find most similar text from candidates |
| `/chat` | GET | Chat UI with WebSocket |
| `/ws` | WS | WebSocket echo (handled in Erlang) |

## Testing

```bash
# Get embeddings
curl -X POST http://localhost:8000/embed \
  -H "Content-Type: application/json" \
  -d '{"texts": ["Hello world", "How are you?"]}'

# Compute similarity
curl -X POST http://localhost:8000/similarity \
  -H "Content-Type: application/json" \
  -d '{"text1": "I love cats", "text2": "I adore kittens"}'
# Returns: {"similarity": 0.82, "interpretation": "Very similar"}

# Find similar
curl -X POST http://localhost:8000/find_similar \
  -H "Content-Type: application/json" \
  -d '{
    "query": "programming language",
    "candidates": ["Python is great", "The weather is nice", "JavaScript rocks"]
  }'
# Returns: {"index": 0, "score": 0.67, "match": "Python is great"}

# Open chat UI
open http://localhost:8000/chat

# Test WebSocket
websocat ws://localhost:8000/ws
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    embedding_chat (Erlang OTP app)              │
├─────────────────────────────────────────────────────────────────┤
│  embedding_chat_app                                             │
│  └─ embedding_chat_sup                                          │
│      └─ Loads sentence-transformers model via py:call/3         │
├─────────────────────────────────────────────────────────────────┤
│  hornbeam (Cowboy HTTP)                                         │
│  ├─ /ws → embedding_chat_ws (cowboy_websocket, pure Erlang)    │
│  └─ /*  → hornbeam_handler → FastAPI (Python)                  │
├─────────────────────────────────────────────────────────────────┤
│  Request Flow:                                                  │
│                                                                 │
│  POST /embed                                                    │
│    → FastAPI                                                    │
│    → execute("embeddings", "embed", texts)                      │
│    → hornbeam_hooks:execute/4                                   │
│    → embedding_chat_embeddings:handle/3                         │
│    → py:call(embedding_chat_model, encode, [Model, Texts])      │
│    → sentence-transformers                                      │
│                                                                 │
│  WS /ws                                                         │
│    → embedding_chat_ws (cowboy_websocket)                       │
│    → Pure Erlang, no Python involved                            │
└─────────────────────────────────────────────────────────────────┘
```

## Configuration

In `src/embedding_chat.app.src`:

```erlang
{env, [
    {model_name, "all-MiniLM-L6-v2"},  % sentence-transformers model
    {port, 8000},                       % HTTP port
    {bind, "0.0.0.0"}                   % Bind address
]}
```

## Direct Erlang Usage

```erlang
%% Get embeddings
{ok, Embeddings} = hornbeam_hooks:execute(
    <<"embeddings">>, <<"embed">>,
    [[<<"Hello">>, <<"World">>]], #{}
).

%% Compute similarity
{ok, Score} = hornbeam_hooks:execute(
    <<"embeddings">>, <<"similarity">>,
    [<<"I love cats">>, <<"I adore kittens">>], #{}
).

%% Find similar
{ok, {Index, Score, Match}} = hornbeam_hooks:execute(
    <<"embeddings">>, <<"find_similar">>,
    [<<"programming">>, [<<"Python">>, <<"Weather">>, <<"Food">>]], #{}
).
```

## Files

```
embedding_chat/
├── rebar.config              # Rebar3 config
├── src/
│   ├── embedding_chat.app.src    # App spec
│   ├── embedding_chat_app.erl    # Application callback
│   ├── embedding_chat_sup.erl    # Supervisor (loads model)
│   ├── embedding_chat_embeddings.erl  # Hook handler
│   └── embedding_chat_ws.erl     # WebSocket handler
└── priv/
    ├── embedding_chat_model.py   # Python model wrapper
    └── embedding_chat/
        └── app.py                # FastAPI app
```
