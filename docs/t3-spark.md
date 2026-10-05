# T3 Code with Spark local models

**Status: experimental.** Model selection and gateway tool calls are verified, but
repeated coding runs can produce malformed tool calls or time out. This optional
integration still needs model/backend tuning for reliable coding.

T3 Code can use the Spark's existing Qwen model through a separate **Spark Local**
Codex provider instance. The working connection is:

```text
T3 Code → Codex app-server → LiteLLM → vLLM → Qwen on the DGX Spark
                           127.0.0.1:4000/v1
```

Codex supplies the coding tools and agent loop; Qwen supplies model inference.
No OpenAI model subscription or OpenAI API key is needed for this provider.

## Use it

1. Create a new T3 Code thread on the Spark environment.
2. Open the model picker, click the **SL** provider button (its tooltip is
   **Spark Local**), and choose **Qwen3.6 35B A3B · Spark**.
3. Send a coding task. The model reads and edits files through the Codex tools.

If the instance is missing, open **Settings → Providers** and refresh the provider
status, or reload T3. The instance should show **Ready**. An unavailable OpenAI
usage meter is normal for a local provider.

The connection belongs to the T3 **server environment**. A desktop or browser
connected to the Spark uses the Spark's loopback endpoint. If the T3 server itself
runs on another computer, it needs a reachable gateway address or a tunnel.

## Verified on this Spark

Setup was checked with T3 Code **0.0.45**, Codex CLI **0.160.0**, and LiteLLM
**1.89.3** on October 4, 2026.

| Setting | Value |
| --- | --- |
| T3 instance | `spark-local` / Spark Local |
| Model alias | `qwen36-nvfp4` |
| Served model | `nvidia/Qwen3.6-35B-A3B-NVFP4` |
| Gateway | `http://127.0.0.1:4000/v1` |
| Transport | Streaming Responses API over HTTP |
| Codex context limit | 131,072 tokens; automatic compaction at 98,304 |
| Tool mode | Direct function calls |
| Reasoning | Off for the non-thinking `qwen36-nvfp4` alias |

The gateway passed a streaming function-call check. The initial Codex app-server
smoke test read a Python file, fixed an addition bug, and ran two passing tests.
Independent assertions checked the edited function, including an extra case.
However, repeated coding tests also returned malformed tool markup or timed out;
the current model/backend's coding reliability is inconsistent. Those failures
remain unresolved and are separate from the picker visibility fix.

T3's own provider probe reports the instance as ready. The model is registered
through T3's custom-model setting. Its visibility and selection were also verified
in the actual T3 web model picker, under the **SL / Spark Local** provider button.

Only the verified `qwen36-nvfp4` alias is enabled by default. The separate
`qwen36-think` alias did not pass the bounded 512-output-token protocol probe;
that result does not establish that it is incompatible. It needs further testing
before use here. Listing a model in `/v1/models` alone does not verify that its
backend is running or that its tools work.

## Reproduce the setup

Requirements: Python 3, a current Codex CLI on PATH, an existing T3 installation,
and a LiteLLM gateway serving a model that supports streaming Responses and tools.
The installer is intended for POSIX hosts and uses `cat` as a credential helper.

From this repository, run:

```bash
python3 scripts/setup-t3-spark.py install
```

Enter the **LiteLLM gateway key** at the hidden prompt. Automation can supply
`SPARK_LITELLM_API_KEY` through its environment, or use `--api-key-file` pointing
to a private file. Keep credentials outside the repository. The installer rejects
Codex state or T3 settings paths inside a Git working tree, including symlinked paths.

The installer checks inference before making changes, creates a dedicated Codex
home, and adds the provider to T3's existing settings. T3 watches the settings file
and loads the new instance automatically. Existing settings and provider instances
are preserved; a timestamped settings backup is written before the update.
Rerunning the installer regenerates the files it manages below.

| File | Purpose |
| --- | --- |
| `~/.config/lightning-compute/codex/config.toml` | Selects the Spark gateway, model, context and tool settings |
| `~/.config/lightning-compute/codex/models.json` | Model metadata and the local-only model catalog |
| `~/.config/lightning-compute/codex/api-key` | Private gateway credential, mode `0600` |
| `~/.t3/userdata/settings.json` | Adds `providerInstances.spark-local` |
| `~/.t3/userdata/settings.before-spark-*.json` | Settings backup |

The generated Codex home is mode `0700`. The key is read by Codex's credential
helper and is absent from T3 settings, the model catalog, and command arguments.
This instance has built-in cloud web search, OpenAI Apps, and multi-agent spawning
disabled. Coding tools run where the T3 server runs.

To check the gateway again without changing configuration:

```bash
python3 scripts/setup-t3-spark.py check \
  --api-key-file ~/.config/lightning-compute/codex/api-key
```

To repeat the actual coding test in a temporary directory:

```bash
python3 scripts/check-codex-spark.py
```

The test normally requests Codex's `workspace-write` sandbox. On this Spark,
bubblewrap currently fails to create its network namespace (`Failed RTM_NEWADDR:
Operation not permitted`). Verification therefore used the same Full Access mode
as the current T3 session:

```bash
python3 scripts/check-codex-spark.py --sandbox danger-full-access
```

That flag applies only to the temporary smoke-test session. The installer does
not change T3 permission settings or host security settings. A T3 thread using a
sandboxed mode on this host can encounter the same bubblewrap error.

## Other models or another T3 server

Repeat `--model` to choose the aliases shown by the new instance:

```bash
python3 scripts/setup-t3-spark.py install \
  --model qwen36-nvfp4 \
  --context-window 131072
```

Each alias must pass the protocol check. Set the context limit no higher than the
actual backend's configured limit; the installer does not discover it. Model
quality and tool reliability still need a coding smoke test. The generated
catalog advertises text input only.

The live LiteLLM service on this Spark binds to **127.0.0.1**, so the older repo
examples using the Spark's Tailnet IP with port 4000 do not currently connect.
For a T3 server on another machine, one option is an SSH tunnel over Tailscale:

```bash
ssh -N -L 127.0.0.1:14000:127.0.0.1:4000 <spark-user>@<spark-tailnet-host>
```

On that machine, run the installer with `--base-url http://127.0.0.1:14000/v1`.
Keep the tunnel running. This leaves the gateway's existing network binding intact.

## Remove it

Remove **Spark Local** in T3's provider settings. After closing its threads, the
dedicated `~/.config/lightning-compute/codex/` directory can also be removed.
The regular Codex configuration is separate. Prefer removing just this instance
over restoring an old settings backup, which could undo later settings changes.

## Why this configuration

The installed Codex uses the Responses API, so a working Chat Completions endpoint
alone is insufficient. LiteLLM supplies the compatible endpoint in this setup.
See the [official Codex provider configuration](https://learn.chatgpt.com/docs/config-file/config-advanced#custom-model-providers)
and [protocol reference](https://learn.chatgpt.com/docs/config-file/config-reference).

T3's installed provider schema supports a separate Codex `homePath` and custom
models. The dedicated catalog supplies the local model's context and tool metadata
with `visibility = "hide"`, while T3's `customModels` setting makes it visible in
the picker. This distinction matters in T3 0.0.45: a model returned by Codex's
normal catalog is treated as built-in, and an unfamiliar model family is marked
legacy and collapsed in the picker. Registering the same slug in both places does
not override that classification.

The smoke test checks this catalog behavior as well as actual coding. It verifies
the installed binaries rather than assuming that every documented configuration
key works across Codex versions.

The custom model also explicitly advertises reasoning **Off**. Leaving its option
descriptors empty makes T3 fall back to `medium`, which does not match this
non-thinking alias. Both the Codex configuration and the T3 model selection set
`none`, with reasoning summaries disabled. This correction did not eliminate the
malformed generations observed in repeat tests. For a backend configured to
reason, choose an appropriate `--reasoning-effort` when installing.
