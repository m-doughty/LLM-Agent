[![Actions Status](https://github.com/m-doughty/LLM-Agent/actions/workflows/test.yml/badge.svg)](https://github.com/m-doughty/LLM-Agent/actions)

LLM::Agent
==========

The engine behind a coding agent: a streaming loop that calls tools through a duck-typed provider, survives backend failure with per-round-trip retry and fallback, writes a durable JSONL transcript you can resume from tomorrow, and compacts the conversation before it outgrows the context window.

It is the machinery, not the product. There is no permission model here (that is [MCP::Client::Policy](https://raku.land/zef:apogee/MCP::Client)), no UI, no scheduler, and no opinion about what your agent is for.

Synopsis
--------

```raku
use LLM::Agent;

my $loop = LLM::Agent::Loop.new(backends => [$primary, $fallback]);
my $run  = $loop.run([$system-message, $user-message]);

# One Supply, every kind of event.
start react whenever $run.events -> $event {
    given $event {
        when LLM::Agent::Event::Token    { print $event.text }
        when LLM::Agent::Event::ToolCall { note "  -> {$event.name}" }
    }
}

# The Promise is KEPT even when the run failed: a failure is data.
my %outcome = await $run.result;
given %outcome<outcome> {
    when 'completed' { say %outcome<final> }
    when 'failed'    { note "gave up: {%outcome<error>}" }
    when 'cancelled' { note 'cancelled' }
}
```

The modules
-----------

<table class="pod-table">
<thead><tr>
<th>Module</th> <th>What it is</th>
</tr></thead>
<tbody>
<tr> <td>LLM::Agent::Loop</td> <td>the state machine; everything else serves it</td> </tr> <tr> <td>LLM::Agent::Run</td> <td>the handle on one run: events, result, cancel</td> </tr> <tr> <td>LLM::Agent::Event</td> <td>the typed event taxonomy, and the framing contract</td> </tr> <tr> <td>LLM::Agent::Session</td> <td>the durable JSONL transcript, and resuming from one</td> </tr> <tr> <td>LLM::Agent::ToolOperation</td> <td>one tool call&#39;s states: dispatched, settled, unknown</td> </tr> <tr> <td>LLM::Agent::Compactor</td> <td>summarize the middle before the window fills</td> </tr> <tr> <td>LLM::Agent::TokenCount</td> <td>how big is this conversation: three answers</td> </tr> <tr> <td>LLM::Agent::Prompt</td> <td>the four pieces a system prompt is made of</td> </tr> <tr> <td>LLM::Agent::Canonical</td> <td>stable digests: is this the same message, conversation, snapshot?</td> </tr>
</tbody>
</table>

`use LLM::Agent;` loads all nine and is enough for every class. It does not re-export `LLM::Agent::Prompt`'s **subs** — an `is export` reaches one scope, not two — so call those fully qualified (`LLM::Agent::Prompt::assemble(...)`) or `use LLM::Agent::Prompt;` as well.

A round, step by step
---------------------

  * **Compaction check, at the top.** Before spending a request, not after: a round that ends with six tool results is exactly the round that blew the budget, so checking on the way in means the next request is the one that fits.

  * **The round trip.** `AttemptStarted`, a streamed completion, `Token` events as the text arrives. Retry and fallback happen here, per round trip.

  * **Limits, before anything is committed.** A limit emits `LimitReached`, appends a system message in `LLM::Chat::ToolLoop`'s exact wording, switches tools off, and gives the model one last round to answer with what it has.

  * **The assistant turn is committed.** `AssistantMessage` and `TurnCommitted`, appended to the conversation and written to the transcript with `reasoning` and `usage` as replay-visible extras.

  * **Tools, one at a time.** One `ToolCall` per call (the model asked), and then each call is dispatched, waited for and settled on its own: a `tool-dispatched` transcript line, `ToolStarted`, the provider, then the `role => 'tool' ` message, a `tool-settled` line and either `ToolResult` or `ToolAbandoned`. Only then does the next call start. Side effects therefore happen in the order the model asked for them, and every call has a durable start and end — which is what lets a resumed transcript tell "never ran" from "was running" from "finished, and the settle never landed".

  * **Grants.** If the provider `can('grants')` — a policy does — a changed snapshot is written to the transcript, so a resumed session does not ask the human the same question again. With `on-grant => $loop.grant-hook ` wired that happens the moment the policy records the rule; without it, at the latest when the running call settles.

No tool calls, or tools switched off: `RunCompleted`, and the run ends.

### Tool deadlines, and the outcome nobody knows

`tool-deadline` (off by default) bounds a single call. When it passes the call is detached and the operation settles **outcome-unknown** — no `ToolResult`, a `ToolAbandoned` with `reason => 'deadline' `, and a `tool` message telling the model that whether it took effect is unknown. It is never an error: a local clock knows nothing about a remote side effect, and a model told its `fs_write` failed will write it again. The run carries on; `$run.drained ` waits for the detached call even though `$run.result ` did not.

The deadline **pauses while a human is being asked**. Dispatch is sequential, so a permission prompt raised inside a call belongs to that call, and the seconds it takes are subtracted from that call's clock.

Failure, retry and fallback
---------------------------

Every failure is classified by [LLM::Chat::Retry](https://raku.land/zef:apogee/LLM::Chat)'s `classify-error` — the same policy `LLM::Data::Inference::Task` has run in production — into one of three buckets:

<table class="pod-table">
<thead><tr>
<th>Bucket</th> <th>What the loop does</th>
</tr></thead>
<tbody>
<tr> <td>abort</td> <td>AttemptFailed, then RunFailed. A 4xx will not heal in eight seconds.</td> </tr> <tr> <td>retry-same</td> <td>AttemptFailed with a backoff, sleep, same backend again</td> </tr> <tr> <td>advance</td> <td>AttemptFailed, next backend in the chain, no wait</td> </tr>
</tbody>
</table>

`max-retries` is the number of **attempts per backend** (Task's semantics, not "extra tries"): 3 means one call and two retries before the chain advances. When the budget runs out, the `AttemptFailed` says `advance`, because `disposition` reports what the loop **does** rather than what the classifier said in the abstract. When every backend is spent, `RunFailed` carries the full `attempts` list.

### The timeout is inactivity, not duration

`round-trip-timeout` (default 120s) measures the gap since the response last did anything — `$resp.last-activity-at ` — not the total time the request has taken. This is a deliberate divergence from `LLM::Data::Inference::Task`, which bounds total duration: Task generates one JSON document per item and a slow one is a stuck one, while an agent turn legitimately runs for minutes. What is never legitimate is a stream that stops producing tokens and never closes, which is what a dropped connection behind a proxy looks like.

### Mid-stream failure: the framing contract

A backend can fail after streaming four hundred tokens. Those tokens were emitted; a Supply has no undo. So the framing events are the contract:

<table class="pod-table">
<thead><tr>
<th>Event</th> <th>What a consumer must do</th>
</tr></thead>
<tbody>
<tr> <td>AttemptStarted</td> <td>open a fresh token scope</td> </tr> <tr> <td>Token</td> <td>append to the CURRENT scope</td> </tr> <tr> <td>AttemptFailed</td> <td>B&lt;discard&gt; every Token since the last AttemptStarted</td> </tr> <tr> <td>AttemptSucceeded</td> <td>commit the scope; the AssistantMessage that follows is authoritative</td> </tr>
</tbody>
</table>

A consumer that ignores this renders a doubled reply the first time a backend 500s halfway through a sentence. Nothing a failed attempt streamed ever reaches the transcript: only committed messages are written.

Cancellation
------------

`$run.cancel ` is idempotent, safe from any thread, and never throws. It asks; the loop winds down and emits `RunCancelled`.

<table class="pod-table">
<thead><tr>
<th>Situation</th> <th>On cancel</th>
</tr></thead>
<tbody>
<tr> <td>mid-stream</td> <td>backend told to cancel; run ends promptly</td> </tr> <tr> <td>during a retry backoff</td> <td>wait ends within 0.25s; run ends</td> </tr> <tr> <td>between rounds</td> <td>no further round starts</td> </tr> <tr> <td>during a tool call</td> <td>loop stops waiting; that call still finishes</td> </tr> <tr> <td>queued behind that call</td> <td>never dispatched: known B&lt;not&gt; to have run</td> </tr> <tr> <td>blocked on a permission ask</td> <td>nothing happens until the human answers</td> </tr> <tr> <td>after the run finished</td> <td>no-op; the outcome stands</td> </tr>
</tbody>
</table>

The two "nothing happens" rows are honest limitations rather than bugs waiting to be fixed. A tool call has no cancellation to forward, and an `fs_write` already in flight has already happened; the loop drains the result and emits no `ToolResult` for it. An ask is a leaf: the policy holds a non-reentrant lock and is waiting for a human, and a run cannot dismiss a modal something else owns.

What the loop does instead is say two different things about the two halves of an interrupted batch. The call **in flight** becomes `outcome-unknown`: `ToolAbandoned(dispatched => True) ` and a `tool` message saying the run was cancelled before it returned and that whether it took effect is unknown. The calls **behind it** were never dispatched, so they become `abandoned`: `ToolAbandoned(dispatched => False) ` and a message saying, flatly, that they did not run. Both messages exist because an assistant turn carrying `tool_calls` that nothing answers is a conversation every provider rejects, and the transcript has to stay resumable — and neither is an error, because one is unknown and the other did not happen.

Note also that "the backend was told to cancel" is not "the model stopped generating". Among the LLM::Chat backends only KoboldCpp really aborts upstream; the others stop reading, and the tokens you are no longer being shown are still being billed.

The transcript
--------------

One append-only JSONL file, held open on a single flushed handle-mode `JSONL::Writer`, so every line is durable the moment its method returns.

```json
{"id":"6f1c...","payload":{...},"ts":"2026-08-09T13:10:08.542283Z","type":"message","v":1}
```

Six types: `session-meta` (always first, the caller's own hash verbatim), `message`, `grants` (the **whole** snapshot, last one wins), `compaction`, and the two halves of a tool operation — `tool-dispatched` (whose envelope id **is** the operation id) and `tool-settled`. Unknown types are preserved on replay and skipped by the readers, so a file written by a newer LLM::Agent still loads — and so a 0.2 transcript still loads in 0.1.x, minus the operations.

`$session.pending-tool-operations ` is what a resumed run reads to find out what was in flight when the process died, and `$session.resolve-tool-operation($id, outcome => 'outcome-unknown') ` is how it closes one off. An operation may be settled once; a settle naming an operation the transcript does not have is refused before it is written.

```raku
my $session = LLM::Agent::Session.create(
    path => $path, meta => { agent => 'sadna', cwd => $*CWD.Str },
);

# ... later, in another process ...
my $resumed  = LLM::Agent::Session.load(path => $path);
my @messages = $resumed.messages;     # compaction already applied
my @grants   = $resumed.grants;       # feed straight to a Policy
```

Replay tolerates a malformed line **only as the very last line** — which is exactly what a crash mid-write looks like; it is dropped and reported in `.warnings`. A malformed line anywhere else is fatal, because silently skipping it would hand back a conversation with an invisible hole in it.

What is deliberately **not** stored: token deltas, attempt telemetry, the contents of permission questions (only the resulting grants), forwarded server logs, and any opinion about where the file should live.

Compaction
----------

```raku
my $counter   = LLM::Agent::TokenCount::Usage.new;    # shared with the loop
my $compactor = LLM::Agent::Compactor.new(
    backend        => @backends[0],   # a cheap model is a fine summarizer
    counter        => $counter,
    context-budget => 128_000,
);
```

The shape is fixed: the sticky prefix (sysprompt and anything else `Message.is-sticky` agrees with) stays where it is, the last `keep-recent` turns stay verbatim, and everything between is replaced by one summary message. The recent window is extended backwards while it starts on a `tool` result, so an assistant turn and the results answering it are never separated — splitting them is a 400 from every provider.

When the summarizer fails, the failure is classified: an `abort` bucket hard-trims immediately, anything else is retried up to `max-attempts` (3) with backoff, and a still-unreachable summarizer falls back to a pair-aligned **hard trim** with `fallback => True `. That fallback is the whole point of the design — the loop always makes progress, because an agent that stops working when a summarizer is down is worse than an agent that forgot what happened an hour ago.

`LLM::Agent::Session` replays exactly the transformation the compactor applied, so `$session.messages` after a resume equals the array the loop was working with when it stopped. `t/11` pins that end to end.

Counting tokens
---------------

<table class="pod-table">
<thead><tr>
<th>Implementation</th> <th>Needs</th> <th>Accuracy</th> <th></th>
</tr></thead>
<tbody>
<tr> <td>Usage</td> <td>nothing (calibrates itself)</td> <td>exact for the billed prefix, estimated beyond</td> <td></td> </tr> <tr> <td>Heuristic</td> <td>nothing</td> <td>±20% on English prose, worse on code/CJK</td> <td></td> </tr> <tr> <td>Exact</td> <td>a tokenizer</td> <td>a template</td> <td>exact, always</td> </tr>
</tbody>
</table>

`Usage` is the default: it remembers the prompt-token count the provider actually billed for the prefix it has already seen and estimates only the tail beyond it. The loop owns one instance and hands the **same** one to its compactor, so the calibration a run accumulates is not thrown away at the moment it matters most.

The canonical wiring
--------------------

The whole stack, in the order the pieces have to be built. Note the **forward declarations**: the MCP client needs the policy's elicit hook at construction, the policy needs the loop's ask shim, and the loop needs the policy — so two of the three have to be named before they exist.

```raku
use LLM::Agent;
use MCP::Client;
use MCP::Client::Registry;
use MCP::Client::Policy;

my $loop;                       # forward-declared: the shims come from it
my $policy;                     # forward-declared: the client's hook needs it

my $session = LLM::Agent::Session.create(
    path => $path, meta => { agent => 'myagent', cwd => $*CWD.Str },
);

my $fs = MCP::Client.connect-stdio(
    command   => 'raku-mcp',
    args      => ['--pack=FileSystem', '--root=' ~ $*CWD],
    on-elicit => -> %request { $policy.elicit-hook.(%request) },

    # Server logs become Log events on the run's Supply. THE log-level IS
    # LOAD-BEARING: since the 2026-07-28 revision a modern server sends
    # nothing at all without one, and a silent hook looks exactly like a
    # server that had nothing to say.
    on-log    => -> %params { $loop.log-hook.(%params) },
    log-level => 'info',

    # Progress notifications become ToolProgress events, correlated to the
    # call in flight. A note for a call that is not the one running is
    # dropped rather than moving the wrong bar.
    on-progress => -> %params { $loop.progress-hook.(%params) },
);

my $registry = MCP::Client::Registry.new;
$registry.add($fs, prefix => 'fs');

$policy = MCP::Client::Policy.new(
    provider => $registry,
    rules    => [
        |MCP::Client::Policy.default-rules,
        { tool => 'fs_write', decision => 'allow', under => 'scratch' },
    ],
    roots    => { fs => $*CWD.Str },
    grants   => $session.grants,          # last session's "always allow"s
    on-ask   => -> %request { $loop.wrap-ask(&ask-the-human).(%request) },

    # An "always" answer reaches the transcript the moment the policy has
    # recorded it, rather than when the call it was asked inside of ends.
    on-grant => -> | { $loop.grant-hook.() },
);

my $counter   = LLM::Agent::TokenCount::Usage.new;
my $compactor = LLM::Agent::Compactor.new(
    backend => @backends[0], :$counter, context-budget => 128_000,
);

$loop = LLM::Agent::Loop.new(
    :@backends, :$counter, :$session, :$compactor, provider => $policy,
);

my $system = LLM::Agent::Prompt::assemble(
    identity => 'You are a coding assistant working in a checked-out repository.',
    sections => [
        LLM::Agent::Prompt::env-block(extra => { cwd => $*CWD.Str }),
        LLM::Agent::Prompt::tool-docs($policy.tools-for-llm),
        LLM::Agent::Prompt::instructions-from-files(['AGENTS.md']),
    ],
);

my $question = LLM::Chat::Conversation::Message.new(
    role => 'user', content => 'Make the tests pass.',
);

# NOTE what is NOT here: no $session.append-message($question). On a fresh
# session the loop records every message it is handed — system prompt first.
# Pre-appending the user turn puts it in the file BEFORE the system prompt,
# and the loop's position check then refuses the very run that wrote it.
# (On a RESUME the pre-append is correct, because the system prompt is
# already the first line of the transcript — see Resuming below.)

my $run = $loop.run([$system, $question]);
```

`wrap-ask` emits `AskPending`, calls the real asker (which still blocks, and still holds the policy's lock), emits `AskAnswered`, and returns the answer untouched — and times the question against the tool call it is about, which is what stops a deadline firing while somebody is reading a permission prompt. What does **not** work is `on-ask => $loop.wrap-ask(&ask) ` with `$loop` still undefined: that calls a method on a type object at construction time and dies there.

The event taxonomy
------------------

<table class="pod-table">
<thead><tr>
<th>Class</th> <th>kind</th> <th>Payload</th>
</tr></thead>
<tbody>
<tr> <td>RunStarted</td> <td>run-started</td> <td>run-id, message-count</td> </tr> <tr> <td>RoundStarted</td> <td>round-started</td> <td>round, tokens?</td> </tr> <tr> <td>AttemptStarted</td> <td>attempt-started</td> <td>round, attempt, backend-index, model</td> </tr> <tr> <td>Token</td> <td>token</td> <td>text, round?, attempt?</td> </tr> <tr> <td>AttemptFailed</td> <td>attempt-failed</td> <td>round, attempt, backend-index, model?, error, error-class?, error-status?, disposition, backoff?</td> </tr> <tr> <td>AttemptSucceeded</td> <td>attempt-succeeded</td> <td>round, attempt, backend-index, model-used?, finish-reason?, usage, latency-ms?</td> </tr> <tr> <td>AssistantMessage</td> <td>assistant-message</td> <td>message, reasoning?, round?</td> </tr> <tr> <td>TurnCommitted</td> <td>turn-committed</td> <td>message-id?, round?</td> </tr> <tr> <td>ToolCall</td> <td>tool-call</td> <td>id, name, arguments?, round?</td> </tr> <tr> <td>ToolStarted</td> <td>tool-started</td> <td>id, name, round?</td> </tr> <tr> <td>ToolProgress</td> <td>tool-progress</td> <td>id, progress, total?, message?, round?</td> </tr> <tr> <td>ToolResult</td> <td>tool-result</td> <td>id, name?, content, is-error, round?</td> </tr> <tr> <td>ToolAbandoned</td> <td>tool-abandoned</td> <td>id, name, reason, dispatched, round?</td> </tr> <tr> <td>AskPending</td> <td>ask-pending</td> <td>request, tool?</td> </tr> <tr> <td>AskAnswered</td> <td>ask-answered</td> <td>request, answer?</td> </tr> <tr> <td>Log</td> <td>log</td> <td>level, logger?, data</td> </tr> <tr> <td>LimitReached</td> <td>limit-reached</td> <td>limit, count?, max?</td> </tr> <tr> <td>TurnDiscarded</td> <td>turn-discarded</td> <td>reason, round?</td> </tr> <tr> <td>CompactionStarted</td> <td>compaction-started</td> <td>tokens-before?, budget?, message-count?, round?</td> </tr> <tr> <td>CompactionDone</td> <td>compaction-done</td> <td>tokens-before?, tokens-after?, dropped?, summary?, fallback, round?</td> </tr> <tr> <td>RunCompleted</td> <td>run-completed</td> <td>final, rounds?, message-count?</td> </tr> <tr> <td>RunFailed</td> <td>run-failed</td> <td>error, attempts, round?</td> </tr> <tr> <td>RunCancelled</td> <td>run-cancelled</td> <td>stage?, round?</td> </tr>
</tbody>
</table>

A `?` marks a key that is absent from `.to-hash` when it was not supplied. Exactly one terminal event is emitted per run and the Supply is then `done`; it is **never** `quit`, because a failure is data, not an exception thrown at whoever happened to be tapping.

Two pairs in that table are the ones a consumer has to read carefully. `AttemptSucceeded` says the **transport** worked; `TurnCommitted` says the turn is part of the conversation, and carries the transcript id it was written under. **Every `AttemptSucceeded` that is never followed by an `AssistantMessage` in the same round is followed by a `TurnDiscarded`** (`limit`, `failed` or `cancelled`), so streamed text can always be retracted on a signal rather than left on screen. And `ToolAbandoned` is not a failed `ToolResult`: `dispatched => False ` means the call never ran, `dispatched => True ` means it ran and the outcome is unknown.

The Supply is a `Supplier::Preserving`, so a consumer that taps late still sees the whole run from the beginning — **but the buffer is delivered to the first tap only**. Tap once and fan out yourself.

Requirements
------------

[LLM::Chat](https://raku.land/zef:apogee/LLM::Chat) 0.8.0+ (backends, messages, and the shared retry policy), [MCP::Client](https://raku.land/zef:apogee/MCP::Client) 0.2.0+ (only for the tool-provider duck type and the integration tests), [JSONL](https://raku.land/zef:apogee/JSONL) 0.1.3+ (the flushed writer the transcript depends on), `JSON::Fast` and `UUID::V4`.

Testing
-------

```shell
prove6 -Ilib -It/lib -I../LLM-Chat/lib -I../MCP-Client/lib \
       -I../JSONL/lib -I../Template-Jinja2/lib t/
```

The suite needs no network, no model and no API key: `t/lib/AgentTestKit` provides a `ScriptedBackend` that replays a list of steps — including mid-stream failures, stalls, per-attempt usage and structured error classes — and a duck-typed `ScriptedProvider` that never throws, with per-call `latency` and `block-call` knobs so a deadline or a mid-batch cancel can be tested at a moment the test chooses rather than one it hopes for. `t/11` runs the loop over a **real** `MCP::Client::Policy`, a real transcript on a temporary file and a real compactor, and checks that a resumed session replays exactly the conversation the loop ended with.

Author
------

Matt Doughty

License
-------

Artistic-2.0

