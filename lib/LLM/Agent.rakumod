=begin pod

=head1 NAME

LLM::Agent - a streaming agent loop: tools, retry, fallback, a durable
transcript, and compaction

=head1 SYNOPSIS

=begin code :lang<raku>

use LLM::Agent;          # brings in every LLM::Agent:: module below

my $loop = LLM::Agent::Loop.new(backends => [$primary, $fallback]);
my $run  = $loop.run([$system, $user]);

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
L<LLM::Agent::Loop>       | the state machine; everything else serves it
L<LLM::Agent::Run>        | the handle on one run: events, result, cancel
L<LLM::Agent::Event>      | the typed event taxonomy, and the framing contract
L<LLM::Agent::Session>    | the durable JSONL transcript, and resuming from one
L<LLM::Agent::Compactor>  | summarize the middle before the window fills
L<LLM::Agent::TokenCount> | how big is this conversation: three answers
L<LLM::Agent::Prompt>     | the four pieces a system prompt is made of

=end table

C<use LLM::Agent;> loads all seven, which is enough for every B<class>:
C<LLM::Agent::Loop>, C<LLM::Agent::Session> and the rest are global
names and are reachable straight away. The one thing it does not do is
re-export L<LLM::Agent::Prompt>'s B<subs> — an C<is export> reaches one
scope, not two — so either call them fully qualified
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
    # object, because $loop does not exist until step 6.
    on-ask   => -> %request { $loop.wrap-ask(&ask-the-human).(%request) },
);

# --- 5. Compaction. ---------------------------------------------------
#
# The counter is SHARED between the loop and the compactor: the loop's is
# the one calibrated against what the provider actually billed.

my $counter = LLM::Agent::TokenCount::Usage.new;

my $compactor = LLM::Agent::Compactor.new(
    backend        => @backends[0],
    counter        => $counter,
    context-budget => 128_000,
);

# --- 6. And the loop it all hangs off. --------------------------------

$loop = LLM::Agent::Loop.new(
    :@backends, :$counter, :$session, :$compactor,
    provider => $policy,
);

# --- 7. Run. ----------------------------------------------------------

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

# NOTE what is NOT here: `$session.append-message($question)`. The loop
# writes every message it is handed that the transcript does not already
# have, IN THE ORDER IT IS HANDED THEM — so this run records the system
# prompt and then the question. Appending the question here as well would
# put it in the file FIRST, and the loop's seed-session check would then
# refuse the very run that wrote it ("message 0 of this run is a 'system'
# but the session recorded a 'user' there"). Let `run` own the writing;
# see the resume recipe below for the one case where an app appends a
# turn itself.
my $run = $loop.run([$system, $question]);

=end code

=head2 Resuming

A session is the whole of the state. Rebuild from it and carry on:

=begin code :lang<raku>

my $session = LLM::Agent::Session.load(path => $path);

note "dropped a partial final line" if $session.warnings;

my @messages = $session.messages;        # compaction already applied
my $policy   = MCP::Client::Policy.new(  # the human is not asked twice
    :$provider, :&on-ask, grants => $session.grants,
);

my $next = LLM::Chat::Conversation::Message.new(role => 'user', content => $more);
$session.append-message($next);

$loop.run([|@messages, $next]);

=end code

The loop appends whatever the session does not already have, and B<dies>
if the conversation it is handed contradicts the transcript rather than
extending it. Starting from C<$session.messages> is what keeps them in
step.

Appending C<$next> here is safe, and it is the one place it is:
C<@messages> is already the whole transcript, so the appended turn lands
at the end of both the file and the array. On a B<first> run there is no
C<@messages> to be at the end of, and the system prompt has not been
written yet — which is why step 7 above hands the loop both messages and
appends neither.

A transcript whose last assistant turn asked for tools that nothing
answered — what a C<SIGKILL> between the two leaves behind — is B<not>
repaired by C<load>, and cannot be repaired by dropping the turn either:
this check refuses a conversation shorter than the transcript just as
firmly as one that differs from it. Answer the open calls instead, with
one synthetic C<tool> message each, the way the loop's own cancel path
does; that extends the transcript, which is exactly what the check is
there to permit.

=head2 The events

One C<Supply>, every kind of event, dispatched on class or on a stable
C<kind> string. The full taxonomy — eighteen classes, their payloads, and
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
after the run finished       | no-op; the outcome stands

=end table

The two "not promised" rows are honest limitations rather than bugs
waiting to be fixed. A tool batch has no cancellation to forward — the
provider bridge does not take one, and an C<fs_write> already in flight
has already happened; the loop drains the result and emits no
C<ToolResult> for it. An ask is a leaf: the policy holds a non-reentrant
lock and is waiting for a human, and a run cannot dismiss a modal that
something else owns.

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
use LLM::Agent::Session;
use LLM::Agent::TokenCount;

unit module LLM::Agent;
