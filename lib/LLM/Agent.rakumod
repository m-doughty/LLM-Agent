=begin pod

=head1 NAME

LLM::Agent - a streaming agent loop: tools, retry, fallback, a durable
transcript, and compaction

=head1 SYNOPSIS

=begin code :lang<raku>

use LLM::Agent;          # brings in every LLM::Agent:: module below

my $loop = LLM::Agent::Loop.new(backends => [$primary, $fallback]);

# The conversation is history; what is true today is a run context,
# rendered into the request and never into the transcript.
my $context = LLM::Agent::RunContext.new(
    head-sections => [ identity => 'You are a coding assistant.' ],
    facts         => [ date => Date.today.Str, cwd => $*CWD.Str ],
);

my $run = $loop.run([$user], :$context);

start react whenever $run.events -> $event {
    print $event.text if $event ~~ LLM::Agent::Event::Token;
}

my %outcome = await $run.result;
say %outcome<final>;

=end code

=head1 DESCRIPTION

The engine behind a coding agent, minus the opinions. It takes a
conversation, talks to a model, streams what comes back, runs the tools
the model asks for, feeds the results in, and goes round again — and
around that, everything a long-running agent needs in order to survive a
real afternoon: retry and fallback across backends, an inactivity
timeout, cooperative cancellation, a transcript that is complete after
every line, and compaction when the conversation outgrows the context
window.

What it deliberately does B<not> contain: a permission model (that is
L<MCP::Client::Policy>), a UI, a scheduler, a notion of where files live,
or any idea what your agent is for.

=head2 The modules

=begin table

Module                    | What it is
==========================|=========================================================
L<LLM::Agent::Loop>          | the state machine; everything else serves it
L<LLM::Agent::Run>           | the handle on one run: events, result, cancel
L<LLM::Agent::Event>         | the typed event taxonomy, and the framing contract
L<LLM::Agent::Session>       | the durable JSONL transcript, and resuming from one
L<LLM::Agent::ToolOperation> | one tool call's states: dispatched, settled, unknown
L<LLM::Agent::Compactor>     | summarize the middle before the window fills
L<LLM::Agent::TokenCount>    | how big is this conversation: three answers
L<LLM::Agent::RequestBudget> | what fits this backend, and what this run may spend
L<LLM::Agent::Artifacts>     | one tool result too big to live in the conversation
L<LLM::Agent::RunContext>    | what is true right now, rendered into the request
L<LLM::Agent::Prompt>        | the four pieces a system prompt is made of
L<LLM::Agent::Canonical>     | stable digests: is this the same message, conversation, snapshot?
L<LLM::Agent::Subagents>     | a provider that delegates: the model spawns child runs

=end table

C<use LLM::Agent;> loads all thirteen, which is enough for every B<class>:
C<LLM::Agent::Loop>, C<LLM::Agent::Session> and the rest are global
names and are reachable straight away. The one thing it does not do is
re-export the B<subs> of L<LLM::Agent::Prompt>,
L<LLM::Agent::Canonical> and L<LLM::Agent::Artifacts> — an C<is export>
reaches one scope, not two — so either call them fully qualified
(C<LLM::Agent::Prompt::assemble(...)>, as the recipe below does) or
C<use LLM::Agent::Prompt;> as well for the bare names.

There is nothing else in this file:
no wrapper class, no C<Agent.new>, no convenience C<send>. Composing a
loop out of a backend chain, a provider and a session is four lines, and
those four lines are the ones worth reading in an app. Loading a single
module (C<use LLM::Agent::Loop;>) is equally fine and marginally faster;
this one exists so that a reader who knows only the dist name has
somewhere to start.

=head1 THE CANONICAL WIRING

The whole stack, in the order the pieces have to be built. This is the
recipe an application copies.

=begin code :lang<raku>

use LLM::Agent;
use LLM::Chat::Backend::OpenAICompatible;
use MCP::Client;
use MCP::Client::Registry;
use MCP::Client::Policy;

# --- 1. The loop first, because the shims hang off it. ---------------
#
# It needs the backends and nothing else yet: `provider` and `session`
# can be handed to a second Loop built at the end, or — as here — the
# loop is built once and the policy is wired to it. Either order works
# as long as the shims come from the loop that will run.

my @backends = (
    LLM::Chat::Backend::OpenAICompatible.new(
        api_url => 'https://openrouter.ai/api/v1',
        api_key => %*ENV<OPENROUTER_API_KEY>,
        model   => 'moonshotai/kimi-k2',
    ),
    LLM::Chat::Backend::OpenAICompatible.new(   # the fallback
        api_url => 'http://localhost:5001/v1',
        model   => 'local',
    ),
);

# --- 2. The transcript. ----------------------------------------------

my $path = "$*HOME/.local/state/myagent/{DateTime.now.Str}.jsonl";
my $session = LLM::Agent::Session.create(
    path => $path,
    meta => { agent => 'myagent', cwd => $*CWD.Str, model => @backends[0].model },
);

# --- 3. The tool servers, then a registry over them. ------------------
#
# NOTE THE FORWARD DECLARATION. The client needs the elicitation hook at
# construction and the policy needs the client, so one of the two must be
# named before it exists. This is the idiom MCP::Client::Policy's own Pod
# uses, and it is the only way round the cycle.

my $loop;                       # forward-declared: the shims come from it
my $policy;                     # forward-declared: the client's hook needs it

my $fs = MCP::Client.connect-stdio(
    command   => 'raku-mcp',
    args      => ['--pack=FileSystem', '--root=' ~ $*CWD],

    # A server's own questions go to the same human, through the same
    # lock the permission prompts use.
    on-elicit => -> %request { $policy.elicit-hook.(%request) },

    # Server logs become Log events on the run's Supply. THE log-level IS
    # LOAD-BEARING: since the 2026-07-28 revision a modern server sends
    # nothing at all without one, and a silent hook looks exactly like a
    # server that had nothing to say.
    on-log    => -> %params { $loop.log-hook.(%params) },
    log-level => 'info',
);

my $registry = MCP::Client::Registry.new;
$registry.add($fs, prefix => 'fs');

# --- 4. The policy, over the registry. --------------------------------
#
# Rules name tools AS THIS POLICY SEES THEM. Over a registry that is the
# prefixed name (fs_read); under one it is the bare name (read).
#
# `grants` pre-seeds the "always allow" answers from last time, which is
# what stops a resumed session re-asking every question.

$policy = MCP::Client::Policy.new(
    provider => $registry,
    rules    => [
        |MCP::Client::Policy.default-rules,
        { tool => 'fs_write', decision => 'allow', under => 'scratch' },
    ],
    roots    => { fs => $*CWD.Str },
    grants   => $session.grants,

    # wrap-ask emits AskPending / AskAnswered around the real asker, so a
    # TUI can render "waiting on you" from the same event stream it
    # renders tokens from. The asker still blocks, and still holds the
    # policy's lock: treat it as a leaf.
    #
    # DEFERRED INTO A CLOSURE, like on-elicit above and for the same
    # reason: `$loop.wrap-ask(...)` here would call a method on a type
    # object, because $loop does not exist until step 7.
    on-ask   => -> %request { $loop.wrap-ask(&ask-the-human).(%request) },
);

# --- 5. Delegation, if the model is to have subagents. -----------------
#
# OPTIONAL, and a composer like the two above it: it publishes the
# policy's catalogue plus a `task` tool, and answers a task call with a
# child run's final message. Stacked OVER the policy here, so everything
# a child does still goes through the same permissions.
#
# `loop` is deferred for the same reason on-ask was — and `spawn` is the
# whole of the app's side: build a child however you like, hand back
# something with `.run` and `.session-path`. See LLM::Agent::Subagents.

my $provider = LLM::Agent::Subagents.new(
    inner => $policy,
    types => [
        { name => 'reviewer', description => 'Reviews a diff. Read-only.' },
        { name => 'tester',   description => 'Runs the tests, reports failures.' },
    ],
    spawn   => -> %spec { build-child(%spec) },
    loop    => { $loop },
    session => $session,
);

# --- 6. Compaction. ---------------------------------------------------
#
# The counter is SHARED between the loop and the compactor: the loop's is
# the one calibrated against what the provider actually billed.

my $counter = LLM::Agent::TokenCount::Usage.new;

my $compactor = LLM::Agent::Compactor.new(
    backend        => @backends[0],
    counter        => $counter,
    context-budget => 128_000,
);

# --- 7. And the loop it all hangs off. --------------------------------
#
# `provider` is the TOP of the stack — the subagent composer here, or
# $policy directly when there is no delegation. The loop cannot tell how
# deep it goes.

$loop = LLM::Agent::Loop.new(
    :@backends, :$counter, :$session, :$compactor, :$provider,
);

# --- 8. The run context: what is true RIGHT NOW. -----------------------
#
# Built fresh per run, and NOT baked into a message. Identity and the
# instruction files go in the head (stable across turns, so a backend's
# prefix cache keeps working); the facts and anything volatile go in the
# tail, rendered after the conversation and closest to generation.
#
# Note what is NOT here: the tool catalogue. The API's own `tools`
# parameter is the single source of truth for what can be called, and a
# prose copy of it in the prompt is one more thing to drift.

my $context = LLM::Agent::RunContext.new(
    head-sections => [
        identity     => 'You are a coding assistant working in a checked-out repository.',
        instructions => LLM::Agent::Prompt::instructions-from-files(['AGENTS.md']),
    ],
    facts => [
        platform => "{$*KERNEL.name} ({$*KERNEL.hardware})",
        date     => Date.today.Str,
        cwd      => $*CWD.Str,
        branch   => $branch,          # undefined facts are dropped
    ],
);

# --- 9. Run. ----------------------------------------------------------

my $question = LLM::Chat::Conversation::Message.new(
    role => 'user', content => 'Make the tests pass.',
);

# NOTE what is NOT here: `$session.append-message($question)`. The loop
# writes every message it is handed that the transcript does not already
# have, IN THE ORDER IT IS HANDED THEM. Appending the question here as
# well would put it in the file twice over, and the loop's seed-session
# check would then refuse the very run that wrote it. Let `run` own the
# writing; see the resume recipe below for the one case where an app
# appends a turn itself.
#
# And note what the conversation IS: one user turn. There is no system
# message in it at all — the identity lives in the context now, so it is
# re-rendered every run instead of fossilising at index 0.
my $run = $loop.run([$question], :$context);

=end code

=head2 Why the identity is not a message

Everything an agent is told divides into two halves with different
lifetimes, and the old recipe — one sticky system prompt at index 0 —
put them in the same place:

=begin table

Half                                    | Belongs
========================================|========================================
what happened: turns, tool results      | the conversation, and the transcript
what is true now: date, cwd, AGENTS.md  | the request, rebuilt every run

=end table

The transcript is B<append-only and digest-locked>: the loop refuses a run
whose messages contradict what the session recorded (see L</Resuming>).
That is exactly right for history and exactly wrong for context — a
session resumed in October otherwise replays August's date, August's tool
catalogue and August's project instructions, for as long as the file
lives.

So the identity, the instructions and the facts go into an
L<LLM::Agent::RunContext>, which the loop renders into the B<request>
—  C<< [head, |@conversation, tail] >> — and never into the conversation.
Nothing about it is seed-checked, and a C<run-context> line per run keeps
the audit trail: which facts, which sections, which digest.

=head2 Resuming

A session is the whole of the state. Rebuild from it, build a B<fresh>
context, and carry on:

=begin code :lang<raku>

my $session = LLM::Agent::Session.load(path => $path);

note "dropped a partial final line" if $session.warnings;

my @messages = $session.messages;        # compaction already applied
my $policy   = MCP::Client::Policy.new(  # the human is not asked twice
    :$provider, :&on-ask, grants => $session.grants,
);

# Rebuilt, not replayed: today's date, today's branch, today's AGENTS.md.
my $context = LLM::Agent::RunContext.new(
    head-sections => [ identity => IDENTITY, instructions => $instructions ],
    facts         => [ date => Date.today.Str, cwd => $*CWD.Str, |@git-facts ],
);

# What the LAST run was told, if you want to notice that the world moved.
my %was = $session.last-run-context<facts>.list.map({ .[0] => .[1] }).Hash;
note "the working directory has changed since this session was last run"
    if %was<cwd>.defined && %was<cwd> ne $*CWD.Str;

my $next = LLM::Chat::Conversation::Message.new(role => 'user', content => $more);
$session.append-message($next);

$loop.run([|@messages, $next], :$context);

=end code

The loop appends whatever the session does not already have, and B<dies>
if the conversation it is handed contradicts the transcript rather than
extending it. Starting from C<$session.messages> is what keeps them in
step — and because the context is not part of that conversation, a
completely different context is not a contradiction. That is the whole
point of it.

Appending C<$next> here is safe, and it is the one place it is:
C<@messages> is already the whole transcript, so the appended turn lands
at the end of both the file and the array. On a B<first> run there is no
C<@messages> to be at the end of, which is why step 9 above hands the loop
the question and appends nothing.

A transcript whose last assistant turn asked for tools that nothing
answered — what a C<SIGKILL> between the two leaves behind — is B<not>
repaired by C<load>, and cannot be repaired by dropping the turn either:
this check refuses a conversation shorter than the transcript just as
firmly as one that differs from it. Answer the open calls instead, with
one synthetic C<tool> message each, the way the loop's own cancel path
does; that extends the transcript, which is exactly what the check is
there to permit.

A B<legacy> transcript — one whose index 0 is a fat system prompt written
before any of this existed — resumes without any migration: the stale
prose is still in the conversation, and the context's tail block says, at
the end of the request, that it supersedes anything earlier that
describes the same world.

=head2 The events

One C<Supply>, every kind of event, dispatched on class or on a stable
C<kind> string. The full taxonomy — twenty-four classes, their payloads, and
the B<attempt-framing contract> that makes a mid-stream retry replayable
instead of doubling the model's reply on screen — is in
L<LLM::Agent::Event>. Read that contract before writing a renderer.

Two properties worth knowing up front: the Supply is C<Supplier::Preserving>,
so a consumer that taps late still sees the whole run from the beginning
(but only the B<first> tap does — tap once and fan out yourself); and the
run's C<result> Promise is B<kept, never broken>, even for a failure.

=head2 Cancellation: what is promised

C<< $run.cancel >> is idempotent, safe from any thread, and never throws.
It asks; the loop winds down and emits C<RunCancelled>.

=begin table

Situation                    | On cancel
=============================|=======================================================
mid-stream                   | backend told to cancel; run ends promptly
during a retry backoff       | wait ends within 0.25s; run ends
between rounds               | no further round starts
during a tool batch          | loop stops waiting; the calls still finish
blocked on a permission ask  | nothing happens until the human answers
after the run finished       | nothing happens at all; the outcome stands

=end table

The two "not promised" rows are honest limitations rather than bugs
waiting to be fixed. A tool batch has no cancellation to forward — the
provider bridge does not take one, and an C<fs_write> already in flight
has already happened; the loop drains the result and emits no
C<ToolResult> for it. An ask is a leaf: the policy holds a non-reentrant
lock and is waiting for a human, and a run cannot dismiss a modal that
something else owns.

The last row means it literally: a cancel on a finished run keeps no
Promise and fires no hook, because that run's driver has already let go
of everything a hook would have poked. And when you need to know that the
abandoned tool batch has B<really> finished — before tearing the provider
down, say — the Promise to wait on is C<< $run.drained >>, not
C<< $run.result >>; the whole point of the cancel path is that the second
one does not wait for the first.

Note also that "the backend was told to cancel" is not "the model stopped
generating". Among the LLM::Chat backends only KoboldCpp really aborts
the generation upstream; the others stop reading, and the tokens you are
no longer being shown are still being billed.

=head1 SEE ALSO

L<LLM::Chat> (backends, messages, templates), L<LLM::Chat::Retry> (the
shared retry policy this uses), L<MCP::Client> (tool servers),
L<MCP::Client::Policy> (permissions), L<JSONL> (the transcript format).

=end pod

# Nothing but the loads: this module is the front door and the Pod above
# is its whole content. See the DESCRIPTION for why there is no wrapper
# class here.
use LLM::Agent::Compactor;
use LLM::Agent::Event;
use LLM::Agent::Loop;
use LLM::Agent::Prompt;
use LLM::Agent::Run;
use LLM::Agent::RunContext;
use LLM::Agent::Session;
use LLM::Agent::Subagents;
use LLM::Agent::TokenCount;
use LLM::Agent::ToolOperation;
# Last, and not alphabetically: these declare things UNDER the LLM::Agent
# namespace (a `unit module`, a nested class), and one imported ahead of
# the sibling classes shadows the lexical view of that namespace (the same
# note is in LLM::Agent::Loop, where it bites hardest).
use LLM::Agent::RequestBudget;
use LLM::Agent::Artifacts;
use LLM::Agent::Canonical;

unit module LLM::Agent;
