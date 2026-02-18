---
title: Add AI to Your Erlang App
description: Guide for integrating AI and machine learning capabilities into Erlang applications using erlang_python, including embeddings, LLM APIs, and RAG systems.
order: 2
---

This guide shows how to integrate AI and machine learning capabilities into your Erlang application using erlang_python.

## Overview

Erlang excels at building distributed, fault-tolerant systems. Python dominates the AI/ML ecosystem with libraries like PyTorch, TensorFlow, sentence-transformers, and OpenAI clients. erlang_python bridges these worlds, letting you:

- Generate text embeddings for semantic search
- Call LLM APIs (OpenAI, Anthropic, local models)
- Run inference with pre-trained models
- Build RAG (Retrieval-Augmented Generation) systems
- Leverage Erlang's concurrency from Python (10x+ speedups)

## Setup

### 1. Create a Virtual Environment

```bash
# Create venv with AI dependencies
python3 -m venv ai_venv
source ai_venv/bin/activate

# Install common AI libraries
pip install sentence-transformers numpy openai anthropic
```

### 2. Activate in Erlang

```erlang
1> application:ensure_all_started(erlang_python).
{ok, [erlang_python]}

2> py:activate_venv(<<"/path/to/ai_venv">>).
ok
```

## Text Embeddings

Embeddings convert text into numerical vectors, enabling semantic search, clustering, and similarity comparisons.

### Using sentence-transformers

```erlang
%% Load a model - NOTE: This loads in one worker only.
%% Each worker will lazy-load the model on first use.
init_embedding_model() ->
    py:exec(<<"
from sentence_transformers import SentenceTransformer
model = SentenceTransformer('all-MiniLM-L6-v2')
">>).

%% Better pattern: use a module that lazy-loads
%% and cache embeddings in shared state

%% Generate embedding for a single text
embed(Text) ->
    {ok, Embedding} = py:eval(
        <<"model.encode(text).tolist()">>,
        #{text => Text}
    ),
    Embedding.

%% Generate embeddings for multiple texts (more efficient)
embed_batch(Texts) ->
    {ok, Embeddings} = py:eval(
        <<"model.encode(texts).tolist()">>,
        #{texts => Texts}
    ),
    Embeddings.
```

### Example: Semantic Search

```erlang
-module(semantic_search).
-export([index/1, search/2]).

%% Index documents with their embeddings
index(Documents) ->
    Embeddings = embed_batch(Documents),
    lists:zip(Documents, Embeddings).

%% Search for similar documents
search(Query, Index) ->
    QueryEmb = embed(Query),
    Scored = [{Doc, cosine_similarity(QueryEmb, DocEmb)}
              || {Doc, DocEmb} <- Index],
    lists:reverse(lists:keysort(2, Scored)).

%% Cosine similarity in Erlang
cosine_similarity(A, B) ->
    Dot = lists:sum([X * Y || {X, Y} <- lists:zip(A, B)]),
    NormA = math:sqrt(lists:sum([X * X || X <- A])),
    NormB = math:sqrt(lists:sum([X * X || X <- B])),
    Dot / (NormA * NormB).
```

### Example: Using the Search

```erlang
1> semantic_search:init_embedding_model().
ok

2> Docs = [
    <<"Erlang is great for building distributed systems">>,
    <<"Python excels at machine learning">>,
    <<"The BEAM VM provides fault tolerance">>,
    <<"Neural networks require GPU acceleration">>
].

3> Index = semantic_search:index(Docs).

4> semantic_search:search(<<"concurrent programming">>, Index).
[{<<"Erlang is great for building distributed systems">>, 0.42},
 {<<"The BEAM VM provides fault tolerance">>, 0.38},
 ...]
```

## Calling LLM APIs

### OpenAI

```erlang
%% Initialize OpenAI client
init_openai() ->
    py:exec(<<"
import os
from openai import OpenAI
client = OpenAI(api_key=os.environ.get('OPENAI_API_KEY'))
">>).

%% Chat completion
chat(Messages) ->
    %% Convert Erlang messages to Python format
    PyMessages = [#{role => Role, content => Content}
                  || {Role, Content} <- Messages],
    {ok, Response} = py:eval(<<"
response = client.chat.completions.create(
    model='gpt-4',
    messages=messages
)
response.choices[0].message.content
">>, #{messages => PyMessages}),
    Response.

%% Usage
chat([{system, <<"You are a helpful assistant.">>},
      {user, <<"What is Erlang?">>}]).
%% => <<"Erlang is a programming language designed for...">>
```

### Anthropic Claude

```erlang
init_anthropic() ->
    py:exec(<<"
import os
import anthropic
client = anthropic.Anthropic(api_key=os.environ.get('ANTHROPIC_API_KEY'))
">>).

claude_chat(Prompt) ->
    {ok, Response} = py:eval(<<"
message = client.messages.create(
    model='claude-sonnet-4-20250514',
    max_tokens=1024,
    messages=[{'role': 'user', 'content': prompt}]
)
message.content[0].text
">>, #{prompt => Prompt}),
    Response.
```

### Local Models with Ollama

```erlang
init_ollama() ->
    py:exec(<<"
import requests

def ollama_generate(prompt, model='llama3.2'):
    response = requests.post(
        'http://localhost:11434/api/generate',
        json={'model': model, 'prompt': prompt, 'stream': False}
    )
    return response.json()['response']
">>).

ollama_chat(Prompt) ->
    {ok, Response} = py:eval(
        <<"ollama_generate(prompt)">>,
        #{prompt => Prompt}
    ),
    Response.
```

## Building a RAG System

Retrieval-Augmented Generation combines semantic search with LLM generation.

```erlang
-module(rag).
-export([init/0, add_document/2, query/2]).

-record(state, {
    index = [] :: [{binary(), [float()]}]
}).

init() ->
    %% Initialize embedding model
    py:exec(<<"
from sentence_transformers import SentenceTransformer
from openai import OpenAI
import os

embedder = SentenceTransformer('all-MiniLM-L6-v2')
llm = OpenAI(api_key=os.environ.get('OPENAI_API_KEY'))

def embed(text):
    return embedder.encode(text).tolist()

def embed_batch(texts):
    return embedder.encode(texts).tolist()

def generate(prompt, context):
    response = llm.chat.completions.create(
        model='gpt-4',
        messages=[
            {'role': 'system', 'content': f'Use this context to answer: {context}'},
            {'role': 'user', 'content': prompt}
        ]
    )
    return response.choices[0].message.content
">>),
    #state{}.

add_document(Doc, #state{index = Index} = State) ->
    {ok, Embedding} = py:eval(<<"embed(doc)">>, #{doc => Doc}),
    State#state{index = [{Doc, Embedding} | Index]}.

query(Question, #state{index = Index}) ->
    %% 1. Embed the question
    {ok, QueryEmb} = py:eval(<<"embed(q)">>, #{q => Question}),

    %% 2. Find top-k similar documents
    Scored = [{Doc, cosine_sim(QueryEmb, DocEmb)} || {Doc, DocEmb} <- Index],
    TopK = lists:sublist(lists:reverse(lists:keysort(2, Scored)), 3),
    Context = iolist_to_binary([Doc || {Doc, _} <- TopK]),

    %% 3. Generate answer with context
    {ok, Answer} = py:eval(
        <<"generate(question, context)">>,
        #{question => Question, context => Context}
    ),
    Answer.

cosine_sim(A, B) ->
    Dot = lists:sum([X * Y || {X, Y} <- lists:zip(A, B)]),
    NormA = math:sqrt(lists:sum([X * X || X <- A])),
    NormB = math:sqrt(lists:sum([X * X || X <- B])),
    Dot / (NormA * NormB).
```

### Using the RAG System

```erlang
1> State0 = rag:init().

2> State1 = rag:add_document(<<"Erlang was created at Ericsson in 1986.">>, State0).
3> State2 = rag:add_document(<<"The BEAM VM runs Erlang and Elixir code.">>, State1).
4> State3 = rag:add_document(<<"OTP provides behaviors like gen_server.">>, State2).

5> rag:query(<<"When was Erlang created?">>, State3).
<<"Erlang was created at Ericsson in 1986.">>
```

## Parallel Embedding with Sub-interpreters

For high-throughput embedding, use parallel execution:

```erlang
%% Embed many documents in parallel
embed_parallel(Documents) ->
    %% Split into batches
    BatchSize = 100,
    Batches = partition(Documents, BatchSize),

    %% Build parallel calls
    Calls = [{mymodule, embed_batch, [Batch]} || Batch <- Batches],

    %% Execute in parallel across sub-interpreters
    {ok, Results} = py:parallel(Calls),

    %% Flatten results
    lists:flatten([R || {ok, R} <- Results]).

partition([], _) -> [];
partition(L, N) ->
    {H, T} = lists:split(min(N, length(L)), L),
    [H | partition(T, N)].
```

## Leveraging Erlang's Concurrency from Python

A powerful pattern is to let Python call Erlang functions and leverage Erlang's lightweight processes for parallelism. This is especially useful when you need to:

- Process multiple items concurrently
- Fan out work to many workers
- Combine Python AI with Erlang's fault-tolerant concurrency

### Registering Erlang Functions

```erlang
%% Register functions that Python can call
init_erlang_functions() ->
    %% Simple computation
    py:register_function(process_item, fun([Item]) ->
        %% Your Erlang processing logic
        do_heavy_computation(Item)
    end),

    %% Parallel map: spawn one process per item
    py:register_function(parallel_map, fun([FuncName, Items]) ->
        Parent = self(),
        Refs = [begin
            Ref = make_ref(),
            spawn(fun() ->
                Result = execute_function(FuncName, Item),
                Parent ! {Ref, Result}
            end),
            Ref
        end || Item <- Items],
        %% Collect results in order
        [receive {Ref, R} -> R after 5000 -> {error, timeout} end
         || Ref <- Refs]
    end),

    %% Parallel HTTP fetches using Erlang processes
    py:register_function(parallel_fetch, fun([Urls]) ->
        Parent = self(),
        Refs = [begin
            Ref = make_ref(),
            spawn(fun() ->
                Result = http_fetch(Url),  % Your HTTP client
                Parent ! {Ref, Result}
            end),
            Ref
        end || Url <- Urls],
        [receive {Ref, R} -> R after 30000 -> {error, timeout} end
         || Ref <- Refs]
    end).
```

### Calling Erlang from Python

The `erlang` module is automatically available in Python code executed via `py:eval`:

```python
# In Python (via py:eval)
import erlang

# Call a single Erlang function
result = erlang.call('process_item', data)

# Process multiple items in parallel using Erlang processes
results = erlang.call('parallel_map', 'process_item', items)

# Fetch multiple URLs concurrently
responses = erlang.call('parallel_fetch', urls)
```

### Example: AI Pipeline with Erlang Parallelism

Combine AI embeddings with Erlang's concurrent processing:

```erlang
-module(ai_pipeline).
-export([init/0, process_documents/1]).

init() ->
    %% Initialize embedding model
    ok = py:exec(<<"
from sentence_transformers import SentenceTransformer
model = SentenceTransformer('all-MiniLM-L6-v2')

def embed_doc(doc):
    import erlang
    # Get metadata from Erlang (processed in parallel)
    metadata = erlang.call('fetch_metadata', doc['id'])
    # Generate embedding
    embedding = model.encode(doc['text']).tolist()
    return {'id': doc['id'], 'embedding': embedding, 'metadata': metadata}
">>),

    %% Register Erlang functions
    py:register_function(fetch_metadata, fun([DocId]) ->
        %% Simulate database lookup (could be actual DB call)
        timer:sleep(50),
        #{id => DocId, fetched_at => erlang:system_time(millisecond)}
    end),

    py:register_function(parallel_embed, fun([Docs]) ->
        %% Spawn a process for each document
        Parent = self(),
        Refs = [begin
            Ref = make_ref(),
            spawn(fun() ->
                {ok, Result} = py:eval(<<"embed_doc(doc)">>, #{doc => Doc}),
                Parent ! {Ref, Result}
            end),
            Ref
        end || Doc <- Docs],
        [receive {Ref, R} -> R after 30000 -> {error, timeout} end
         || Ref <- Refs]
    end).

process_documents(Docs) ->
    %% Process all documents in parallel
    {ok, Results} = py:eval(
        <<"__import__('erlang').call('parallel_embed', docs)">>,
        #{docs => Docs}
    ),
    Results.
```

### Performance: Sequential vs Parallel

The Erlang concurrency model provides dramatic speedups:

```erlang
%% Sequential: 10 items × 100ms = 1 second
Sequential = [process(Item) || Item <- Items].

%% Parallel with Erlang processes: ~100ms total (10x speedup!)
Parallel = py:eval(<<"erlang.call('parallel_map', 'process', items)">>,
                   #{items => Items}).
```

Real-world results from the example:
```
Sequential (10 items × 100ms): 1.01 seconds
Parallel (10 Erlang processes): 0.10 seconds
Speedup: 10x faster!
```

### Batch AI Operations with Erlang Workers

For high-throughput AI workloads, combine batching with Erlang workers:

```erlang
%% Register a worker pool function
py:register_function(spawn_workers, fun([Tasks]) ->
    Parent = self(),
    Refs = [begin
        Ref = make_ref(),
        spawn(fun() ->
            %% Each worker can call Python AI functions
            Result = case Task of
                #{type := embed, text := Text} ->
                    {ok, Emb} = py:eval(<<"model.encode(t).tolist()">>,
                                        #{t => Text}),
                    #{type => embedding, result => Emb};
                #{type := classify, text := Text} ->
                    {ok, Class} = py:eval(<<"classify(t)">>, #{t => Text}),
                    #{type => classification, result => Class}
            end,
            Parent ! {Ref, Result}
        end),
        Ref
    end || Task <- Tasks],
    [receive {Ref, R} -> R after 60000 -> {error, timeout} end
     || Ref <- Refs]
end).

%% Usage from Python
process_ai_batch(Tasks) ->
    {ok, Results} = py:eval(
        <<"erlang.call('spawn_workers', tasks)">>,
        #{tasks => Tasks}
    ),
    Results.
```

### Running the Example

A complete working example is available:

```bash
# Run the Erlang concurrency example
escript examples/erlang_concurrency.erl
```

This demonstrates:
- Registering Erlang functions (`echo`, `slow_compute`, `fib`, etc.)
- Calling them from Python via `erlang.call()`
- Parallel processing with `parallel_map`
- Spawning worker pools with `spawn_workers`
- Simulated parallel HTTP fetches

## Async LLM Calls

For non-blocking LLM calls:

```erlang
%% Start async LLM call
ask_async(Question) ->
    py:call_async('__main__', generate, [Question, <<"">>]).

%% Gather multiple responses
ask_many(Questions) ->
    Refs = [ask_async(Q) || Q <- Questions],
    [py:await(Ref, 30000) || Ref <- Refs].
```

## Streaming LLM Responses

For streaming responses from LLMs:

```erlang
init_streaming() ->
    py:exec(<<"
from openai import OpenAI
import os

client = OpenAI(api_key=os.environ.get('OPENAI_API_KEY'))

def stream_chat(prompt):
    stream = client.chat.completions.create(
        model='gpt-4',
        messages=[{'role': 'user', 'content': prompt}],
        stream=True
    )
    for chunk in stream:
        if chunk.choices[0].delta.content:
            yield chunk.choices[0].delta.content
">>).

stream_response(Prompt) ->
    {ok, Chunks} = py:stream('__main__', stream_chat, [Prompt]),
    %% Chunks is a list of text fragments
    iolist_to_binary(Chunks).
```

## Performance Tips

### 1. Batch Operations

```erlang
%% Slow: one call per embedding
[embed(Doc) || Doc <- Documents].

%% Fast: batch embedding
embed_batch(Documents).
```

### 2. Reuse Models

```erlang
%% Load model once at startup
init() ->
    py:exec(<<"model = SentenceTransformer('...')">>).

%% Reuse in each request
embed(Text) ->
    py:eval(<<"model.encode(text).tolist()">>, #{text => Text}).
```

### 3. Use GPU When Available

```erlang
init_gpu_model() ->
    py:exec(<<"
import torch
from sentence_transformers import SentenceTransformer

device = 'cuda' if torch.cuda.is_available() else 'cpu'
model = SentenceTransformer('all-MiniLM-L6-v2', device=device)
">>).
```

### 4. Cache Embeddings in Shared State

Avoid recomputing embeddings for the same text:

```erlang
%% Check cache before computing
embed_cached(Text) ->
    Key = <<"emb:", (crypto:hash(md5, Text))/binary>>,
    case py:state_fetch(Key) of
        {ok, Embedding} ->
            {ok, Embedding};
        {error, not_found} ->
            {ok, Embedding} = py:eval(
                <<"model.encode(text).tolist()">>,
                #{text => Text}
            ),
            py:state_store(Key, Embedding),
            {ok, Embedding}
    end.
```

Or from Python:

```python
from erlang import state_get, state_set
import hashlib

def embed_cached(text):
    key = f"emb:{hashlib.md5(text.encode()).hexdigest()}"
    cached = state_get(key)
    if cached is not None:
        return cached
    embedding = model.encode(text).tolist()
    state_set(key, embedding)
    return embedding
```

### 5. Monitor Rate Limits

```erlang
%% Check current load before heavy operations
check_capacity() ->
    Current = py_semaphore:current(),
    Max = py_semaphore:max_concurrent(),
    case Current / Max of
        Ratio when Ratio > 0.8 ->
            {error, high_load};
        _ ->
            ok
    end.
```

## Error Handling

```erlang
safe_embed(Text) ->
    try
        case py:eval(<<"model.encode(text).tolist()">>, #{text => Text}) of
            {ok, Embedding} -> {ok, Embedding};
            {error, Reason} -> {error, {python_error, Reason}}
        end
    catch
        error:timeout -> {error, timeout}
    end.

%% With retry
embed_with_retry(Text, Retries) when Retries > 0 ->
    case safe_embed(Text) of
        {ok, _} = Result -> Result;
        {error, _} ->
            timer:sleep(1000),
            embed_with_retry(Text, Retries - 1)
    end;
embed_with_retry(_, 0) ->
    {error, max_retries}.
```

## Complete Example: AI-Powered Search Service

```erlang
-module(ai_search).
-behaviour(gen_server).

-export([start_link/0, index/1, search/2]).
-export([init/1, handle_call/3, handle_cast/2]).

-record(state, {
    documents = #{} :: #{binary() => [float()]}
}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

index(Documents) ->
    gen_server:call(?MODULE, {index, Documents}, 60000).

search(Query, TopK) ->
    gen_server:call(?MODULE, {search, Query, TopK}, 10000).

init([]) ->
    %% Initialize embedding model
    ok = py:exec(<<"
from sentence_transformers import SentenceTransformer
model = SentenceTransformer('all-MiniLM-L6-v2')
">>),
    {ok, #state{}}.

handle_call({index, Documents}, _From, State) ->
    {ok, Embeddings} = py:eval(
        <<"model.encode(docs).tolist()">>,
        #{docs => Documents}
    ),
    NewDocs = maps:from_list(lists:zip(Documents, Embeddings)),
    {reply, ok, State#state{documents = maps:merge(State#state.documents, NewDocs)}};

handle_call({search, Query, TopK}, _From, #state{documents = Docs} = State) ->
    {ok, QueryEmb} = py:eval(
        <<"model.encode(q).tolist()">>,
        #{q => Query}
    ),
    Scored = [{Doc, cosine_sim(QueryEmb, Emb)} || {Doc, Emb} <- maps:to_list(Docs)],
    Results = lists:sublist(lists:reverse(lists:keysort(2, Scored)), TopK),
    {reply, {ok, Results}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

cosine_sim(A, B) ->
    Dot = lists:sum([X * Y || {X, Y} <- lists:zip(A, B)]),
    NormA = math:sqrt(lists:sum([X * X || X <- A])),
    NormB = math:sqrt(lists:sum([X * X || X <- B])),
    Dot / (NormA * NormB).
```

## Using from Elixir

All AI examples work seamlessly from Elixir:

```elixir
# Start erlang_python
{:ok, _} = Application.ensure_all_started(:erlang_python)

# Activate venv with AI libraries
:ok = :py.activate_venv("/path/to/ai_venv")

# Generate embeddings using ai_helpers module
{:ok, embeddings} = :py.call(:ai_helpers, :embed_texts, [
  ["Elixir is functional", "Python does ML", "BEAM is concurrent"]
])

# Semantic search
{:ok, query_emb} = :py.call(:ai_helpers, :embed_single, ["concurrent programming"])

# Calculate similarity in Elixir
similarities = Enum.zip(texts, embeddings)
|> Enum.map(fn {text, emb} -> {text, cosine_similarity(query_emb, emb)} end)
|> Enum.sort_by(fn {_, score} -> score end, :desc)
```

### Parallel AI with BEAM Processes

```elixir
# Register parallel embedding function
:py.register_function(:parallel_embed, fn [texts] ->
  parent = self()

  refs = Enum.map(texts, fn text ->
    ref = make_ref()
    spawn(fn ->
      {:ok, emb} = :py.call(:ai_helpers, :embed_single, [text])
      send(parent, {ref, emb})
    end)
    ref
  end)

  Enum.map(refs, fn ref ->
    receive do
      {^ref, result} -> result
    after
      30_000 -> {:error, :timeout}
    end
  end)
end)
```

### Running the Elixir AI Example

```bash
# Full Elixir example with AI integration
elixir --erl "-pa _build/default/lib/erlang_python/ebin" examples/elixir_example.exs
```

The example demonstrates:
- Basic Python calls from Elixir
- Data type conversion
- Registering Elixir callbacks for Python
- Parallel processing (10x speedup)
- Semantic search with embeddings

## See Also

- [Getting Started](getting-started.md) - Basic usage
- [Type Conversion](type-conversion.md) - How data is converted
- [Scalability](scalability.md) - Parallel execution and rate limiting
- [Streaming](streaming.md) - Working with generators
