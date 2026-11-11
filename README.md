# Erlang agent harness

An OTP agent runtime with an educkui terminal client. Each session owns its
turn state and transcript. Temporary model and tool workers report events back
to the session, which advances the loop and streams updates to the client.

## Run

Use Erlang/OTP 28 or newer and Rebar3 on your PATH. Launch from this directory in
an interactive terminal with raw input support. The first build fetches the
pinned educkui dependency.

```powershell
$env:OPENROUTER_API_KEY = 'your-key'
./build.ps1 tui
```

On Linux, WSL, or macOS, with Erlang and Rebar3 installed in that environment:

```bash
export OPENROUTER_API_KEY='your-key'
bash start.sh
```

In WSL, this checkout is at `/mnt/c/dev/erl-harness/erl_harness`. The launcher
uses `_build/unix` by default, so it can share the checkout with Windows.

Enter sends a prompt. Up/Down and Page Up/Page Down scroll the transcript.
Esc or Ctrl+C cancels the current turn or exits when idle. Ctrl+Q exits.

## Configuration

`config/sys.config` sets the default OpenRouter model, full Chat Completions
URL, and API key source. Copy `config/local.config.example` to the ignored
`config/local.config` to override values. Set `ERL_HARNESS_CONFIG` to read
another file containing a single Erlang map. A key can be an environment
reference such as `{env, "OPENROUTER_API_KEY"}` or a binary in the local file.
Use a model that supports function calling if you enable tools.

```erlang
#{
    model => <<"openai/gpt-4o-mini">>,
    url => <<"https://openrouter.ai/api/v1/chat/completions">>,
    api_key => {env, "OPENROUTER_API_KEY"},
    max_model_calls => 12,
    context_budget_bytes => 96000,
    native_tools => [erl_harness_workspace],
    mcp_servers => [
        #{name => <<"example">>, url => <<"http://127.0.0.1:4832/mcp">>,
          allow => [<<"get_diagram_content">>]}
    ]
}.
```

MCP servers default to an empty list. Add an explicit `allow` list for each
Streamable HTTP endpoint. An optional `api_key_env` string names a bearer token
environment variable. Discovered tools appear as `server__tool` at the next
turn. Allowing a tool authorizes it to run automatically when the model calls
it. The built-in native tools list directories and read UTF-8 files under the
launch directory. To register a native tool, implement the `erl_harness_tool`
behaviour and add the module to `native_tools`.

## Runtime

- The app controller starts sessions and resolves session handles. The
  session's `gen_statem` owns model and tool phases, cancellation, and budgets.
- The context builder keeps recent complete turns within a configurable byte
  budget. It preserves tool call/result pairs and keeps the full transcript
  in memory until the session closes.
- The model worker collects streamed text and function-call fragments. Native
  and MCP calls share registry, argument checks, and normalized results.
  Tool calls run serially in temporary workers. Failed or cancelled work is
  never automatically retried.
- The MCP supervisor starts the catalog manager and one client process per
  endpoint. Clients negotiate a protocol version, discover tools, and retain
  the server session for subsequent calls.

Run tests with `./build.ps1 test` or `rebar3 eunit`. The test suite uses local
HTTP fixtures and needs loopback access. Build a release with
`./build.ps1 release` or `rebar3 as prod release`.
