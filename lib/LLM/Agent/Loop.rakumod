=begin pod

=head1 NAME

LLM::Agent::Loop - the streaming agent loop: tools, retry, fallback,
transcript, compaction

=head1 SYNOPSIS

=begin code :lang<raku>

use LLM::Agent::Loop;

my $loop = LLM::Agent::Loop.new(
    backends => [$primary, $fallback],   # tried in order, per round trip
    provider => $policy,                 # any tools-for-llm/execute-tool-calls pair
    session  => $session,                # optional, but this is what makes it resumable
    compactor => $compactor,             # optional, needs a context-budget
);

# The conversation is history. What is true TODAY — the date, the cwd,
# the branch, the instruction files — is a RunContext, rendered into the
# request per run and never into the transcript.
my $run = $loop.run([$user-message], context => $context);

start react whenever $run.events -> $event {
    given $event {
        when LLM::Agent::Event::Token    { print $event.text }
        when LLM::Agent::Event::ToolCall { note "  -> {$event.name}" }
    }
}

my %outcome = await $run.result;
say %outcome<final>;

=end code

=head1 DESCRIPTION

Everything between "here is a conversation" and "here is the answer": ask
the model, stream what it says, run the tools it asks for, feed the
results back, and go round again until it stops asking. Around that, the
things that make it survive contact with reality — retry, fallback,
inactivity timeouts, cancellation, a transcript that is complete after
every line, and compaction when the conversation outgrows the window.

It is a separate class from L<LLM::Chat::ToolLoop> rather than an
extension of it: that loop is streaming-only, has no cancellation, no
retry and no framing between rounds, and bolting those on would change
its behaviour for every existing user. This one keeps a
C<LLM::Chat::Backend> chain, a duck-typed tool provider, and publishes
one C<Supply> of typed events.

=head2 What plugs into it

=begin table

Attribute         | What it is
==================|=================================================================
backends          | C<LLM::Chat::Backend> chain, tried in order per round trip
provider          | anything with tools-for-llm + execute-tool-calls (or nothing)
counter           | an L<LLM::Agent::TokenCount> (default: C<::Usage>)
session           | an L<LLM::Agent::Session> to write the transcript to
compactor         | an L<LLM::Agent::Compactor>; needs context-budget
context-budget    | the window size in tokens
request-budget    | an L<LLM::Agent::RequestBudget>: what fits, and what it may cost
artifact-store    | where oversized tool results go (default: beside the transcript)
tool-deadline     | seconds one tool call may run (default: no deadline)
idempotency-rules | tool-name patterns → C<read-only> / C<idempotent> / C<destructive>

=end table

C<provider> is duck-typed on purpose. An C<MCP::Client>, an
C<MCP::Client::Registry> over several of them, an C<MCP::Client::Policy>
over that, or a hand-rolled object with the two methods — the loop cannot
tell and does not care. B<With no provider the loop is a plain streaming
chat loop>: no tools are declared, and a model that hallucinates a tool
call is answered as if it had not.

The loop stays entirely policy-unaware. It never imports
C<MCP::Client::Policy>, never asks anything, and never decides what is
allowed. What it offers instead is two shims — C<wrap-ask> and
C<log-hook> — that an app wires at construction so that the questions and
the logs a policy or a client produces come out of the same event stream
as everything else. See L</Wiring the shims>.

=head2 One run at a time

C<run> returns a L<LLM::Agent::Run> immediately and does the work behind
it. Calling it again while a run is live B<dies>. That is not a
limitation of the machinery — most of the state is per-run — but a
deliberate refusal to have an opinion about scheduling: how many agents
may talk to one backend at once, whether they queue or run in parallel,
what happens to the second one's tokens, are questions an application (or
a future scheduler) answers. A loop that is one run at a time is a loop
something else can queue.

"Live" means C<< !$run.is-done >>, so the next run is admitted the moment
the previous one's result Promise is kept. That makes the B<order of the
driver's epilogue> load-bearing, and it is: the state machine returns a
finish spec rather than finishing the run itself, and the driver then
releases the stream slot, C<_finish>es the run, and closes its work
section — in that order. By the time C<run> can succeed again, the
previous driver holds nothing.

The little state the loop keeps across a round trip — the backend and
Response a cancel would have to poke — is B<tagged with the run that owns
it>, and every reader checks the tag. So even an old handle that somehow
fires late (a hook captured by an app, a straggler thread) finds a slot
that is either its own or empty, and never the next run's.

Two things follow that are worth knowing when you are queueing runs: a
finished run's C<cancel> does nothing at all (see L<LLM::Agent::Run>),
and C<< $run.drained >> — not C<result> — is what tells you the previous
run has stopped touching the provider, which on a cancelled or deadlined
tool call is strictly later.

=head2 A round, step by step

=item B<Compaction check, at the top.> Before spending a request, not
after: a round that ends with six tool results is exactly the round that
blew the budget, and checking on the way in means the next request is the
one that fits. A conversation over C<compactor.trigger> is compacted, the
working array is swapped, a compaction line goes to the session, and
C<CompactionStarted> / C<CompactionDone> frame it. A compaction that
reports it could B<not> make the next request fit ends the run — see
L</When the context runs out>.

=item B<The round trip.> Per backend: a B<preflight> against that
backend's window (see L</What fits, and what it costs>), and then
C<AttemptStarted> and a streamed completion, with C<Token> events as the
text arrives. Retry and fallback happen B<here>, per round trip — see
L</Failure>.

=item B<Limits, before anything is committed.> If the model asked for
tools and a limit has been hit, C<LimitReached> is emitted, a system
message in C<ToolLoop>'s exact wording is appended, tools are switched
off, and the round starts again so the model can answer with what it has.

=item B<The assistant turn is committed.> C<AssistantMessage> and
C<TurnCommitted>, appended to the working array, written to the session
(with C<reasoning> and C<usage> as replay-visible extras).

=item B<Tools.> One C<ToolCall> per call — the model asked — and then
each call is dispatched, waited for and settled B<on its own>: see
L</One tool call at a time>. Every result is filed under the B<call's>
C<tool_call_id> — the model's C<tool_calls> entry is the only authority
on that id, and a provider that answers with a different one has its
answer corrected and a C<Log> event emitted saying so. Letting it win
would put an id in the transcript that nothing in the conversation asked
for, which is a 400 on the next request and a session nobody can resume.

=item B<Grants.> If the provider C<can('grants')> — a policy does — the
snapshot is written to the session whenever it B<changes>, so a resumed
session does not ask the human again. See L</Grants, and when they are
written>.

No tool calls, or tools switched off: C<RunCompleted>, and the run ends.

=head3 The limit ordering, and the assistant turn it discards

Limits are checked B<before> the assistant turn is committed, and a limit
therefore B<discards> that turn — no C<AssistantMessage>, nothing in the
session. This is C<ToolLoop>'s behaviour and it is not cosmetic: an
assistant message carrying C<tool_calls> that is never followed by the
matching C<tool> messages is a malformed conversation, and every
OpenAI-compatible provider rejects the next request with a 400. The
choice is between losing one sentence of the model's commentary and
losing the run.

=head2 One tool call at a time

A round's tool calls are dispatched B<sequentially>, one at a time, each
through the provider as a batch of one. Per call: a C<tool-dispatched>
envelope, C<ToolStarted>, the provider, and then whichever settle path
the answer (or the absence of one) calls for — the tool message, the
C<tool-settled> envelope, and C<ToolResult> or C<ToolAbandoned>. Only
then does the next call start.

That is a B<behaviour change from 0.1.x>, and it buys three things a
whole-batch dispatch could not have:

=item B<Real boundaries.> Every call has a moment it started and a moment
it settled, both of them durable (L<LLM::Agent::ToolOperation>,
L<LLM::Agent::Session>'s two envelopes). After a C<SIGKILL> the
transcript can say which of "never ran", "was running" and "finished, and
the settle never landed" applies to each call — which is the difference
between a resume that lies to the model and one that does not.

=item B<Bounded blast radius.> A cancel or a deadline reaches the call it
is about. The calls behind it are still C<proposed>, and a call that was
never dispatched can be settled as B<abandoned>: known not to have run,
which is the strongest thing this loop is ever able to say.

=item B<Model order.> Side effects now happen in the order the model
asked for them. C<MCP::Client::Registry>'s per-server grouping degenerates
to singletons, and C<MCP::Client::Policy> no longer decides every call
before any of them runs: the permission questions of the third call are
asked B<after> the first two have run. Both are deliberate. A model that
writes a file and then reads it back is describing a sequence, and a
policy that asked about all three up front was asking about a world that
no longer existed by the time the third one ran.

What it costs is parallelism the loop never had: the previous code sent
one batch to one bridge, and every provider in this ecosystem executed it
sequentially anyway.

=head3 The tool deadline, and the humans it waits for

C<tool-deadline> (undefined by default) bounds one call. When it passes,
the call is B<detached> — the bridge has no cancellation, so it carries on
somewhere — and the operation settles C<outcome-unknown>:

=item no C<ToolResult>, because nothing came back;

=item a C<ToolAbandoned> with C<< reason => 'deadline' >> and
C<< dispatched => True >>;

=item a C<tool> message telling the model, in words, that the call did not
return in time and that B<whether it took effect is unknown>. It is not
C<is-error>, because a local clock knows nothing about a remote side
effect, and a model told that C<fs_write> "failed" will cheerfully write
it again.

The run B<carries on> to the next call and the next round. The detached
call keeps a work section open, so C<< $run.drained >> waits for it even
though C<< $run.result >> did not.

The clock B<pauses while a human is being asked>. Dispatch is sequential,
so an C<AskPending> raised inside a call belongs to that call; C<wrap-ask>
records the span on the operation, and the deadline is measured against
C<< dispatched-at + ask-seconds >> rather than wall clock. Without that, a
30-second deadline would abandon every call whose permission prompt sat on
somebody's screen for a minute — having never let it start.

=head3 The identical-call guard, and what counts as identical

C<max-identical-calls> counts a call's B<name plus its canonicalised
arguments>: the argument JSON is reparsed and re-rendered with sorted
keys, so C<< {"path":"a","mode":"r"} >> and C<< {"mode":"r","path":"a"} >>
are one call made twice. A model going round in circles rarely re-emits a
byte-identical document; it re-emits the same request.

The count spans B<the current batch as well as the run's history>. Three
identical calls in one turn are a loop just as surely as one per turn for
three turns, and a guard that only looked at history would let the whole
batch through and then run it. Only calls that were B<dispatched> count —
a call abandoned to a cancel leaves the tally where it was, so a resumed
run does not find its own limit half spent — and a call whose outcome is
B<unknown> counts, because a call that times out identically for ever
must not be able to evade the guard by never coming back.

=head2 When the context runs out

Compaction is the loop's answer to a conversation that has outgrown its
window, and it is not always enough. One 400KB C<fs_read> in the last
turn is bigger than some windows on its own, and the recent turns are
exactly what a compaction refuses to eat (see L<LLM::Agent::Compactor>).

When the compactor reports that even a hard trim leaves the conversation
over budget, the run B<ends> — C<CompactionDone> first, so the framing is
complete, then C<RunFailed> with C<< reason => 'context-exhausted' >> on
both the event and the result Map. The alternative is what 0.1.0 did:
send the doomed request anyway, fail, compact again, and repeat until
somebody cancels.

Whatever the compaction did manage is kept. The trimmed conversation is
the one in C<< %outcome<messages> >> and the compaction line is in the
session, so the transcript describes what really happened and a resumed
run starts from the smaller conversation rather than the one that could
not be sent.

=head2 What fits, and what it costs

An L<LLM::Agent::RequestBudget> is how a deployment tells the loop three
things it cannot work out for itself: how big each backend's window is,
how much of a tool result is too much, and what this run is allowed to
spend. All three are optional, and a loop without one behaves exactly as
0.1.x did.

C<context-budget> on its own is still enough, and now buys something: a
loop given one and no explicit budget B<synthesizes> a default profile of
exactly that window (no safety margin, no completion reserve — see
L<LLM::Agent::RequestBudget> on why both are zero). A conversation that
does not fit the window then ends the run cleanly instead of being sent
and rejected, which is what C<context-budget> without a compactor used to
do. Both given: they have to agree about the window, or the constructor
says so. A compactor whose budget is above the smallest declared window
is refused for the same kind of reason — every compaction would converge
on a conversation that backend still cannot take.

=head3 The preflight, per attempt and per backend

Before each backend is tried — B<before the retry loop, and before any
C<AttemptStarted>> — the loop asks whether the request fits it:

=begin code :lang<text>

    needed = counted messages + estimated tool declarations
                              + the run context + margin
    it fits when   needed + completion-reserve <= context-window

=end code

Every term is named separately in the C<attempts> record the skip leaves
behind, including a run context of zero, so the sum in the error message
is one a reader can check against the numbers they configured.

Per backend, and not once per round, because B<a prompt that fits the
primary may not fit the fallback>. A chain from a 128k model to an 8k one
is exactly the case the check exists for, and a single check against
"the" window would either wave the doomed request through or refuse a
request the primary would have taken.

A backend that does not fit is B<skipped>: an C<attempts> record saying
what it needed and what it had, one C<Log> event, and the chain moves on.
There is B<no C<AttemptStarted>/C<AttemptFailed> pair>, and that is
deliberate on both halves. Preflight unfitness is arithmetic, so retrying
it would spend C<max-retries> on a sum that cannot come out differently.
And the attempt framing is a contract about B<transport> attempts — a
C<Token> belongs to the C<AttemptStarted> that opened it — so a backend
nothing was sent to must not open a token scope for a consumer to
retract. The record it leaves is the only one in C<attempts> that carries
a C<disposition> of its own, because there is no C<AttemptFailed> beside
it to say what the loop did.

When B<every> backend refuses, nothing has been sent and nothing has been
spent, and one move is left: compact to C<target> — the largest
conversation any of these backends would have taken — and try the chain
B<once> more. Still refused, or no compactor to ask: C<RunFailed> with
C<< reason => 'context-exhausted' >>, the same terminal the compactor
reaches from the other side.

=head3 The 400 that is really a window

Preflight is the defence; this is the seatbelt for the backend nobody
declared. An attempt that fails with B<status 400> whose error text
contains one of a documented set of phrases — C<context length>,
C<context_length>, C<maximum context>, C<too many tokens>, C<prompt is
too long>, matched case-insensitively — is reclassified from C<abort> to
C<advance>, so the chain tries the next backend instead of ending the
run.

It is B<text sniffing>, and it is worth being honest about that: there is
no status, header or error class that distinguishes "your prompt is too
long" from any other 400, providers word it however they like, and a
provider that words it differently gets the old behaviour. What the
reclassification buys is that the fallback — often a model with a bigger
window, or a different tokenizer — gets its turn rather than being
skipped because the primary said 400.

=head3 Caps, and what "spent" means

C<max-cost>, C<max-total-tokens> and C<max-wall-clock> on the budget are
checked at B<the top of every round> and B<between tool operations>,
through one hook. Both are points where B<nothing is in flight>: an
operation that has been dispatched always settles first, because a cap is
a reason to stop starting things and never a reason to stop knowing what
the last one did. The calls behind it settle as C<abandoned> with
C<< reason => 'budget-exhausted' >> — known not to have run — and the run
ends with C<RunFailed> and C<< reason => 'budget-exhausted' >>, naming
the cap, what was spent and what the limit was.

Cost is only counted when a provider B<reported> one (OpenRouter does,
through C<usage.cost>; most do not), and it rides
C<AttemptSucceeded.usage> and the assistant turn's session extras as
well, so a transcript records what each turn cost.

A run with a budget hands back one extra key in its result Map:
C<< spent => { total-tokens, wall-clock, cost? } >>. It is absent without
a budget, because "nobody was counting" and "nothing was spent" are
different answers.

B<Known limitation, and it is deliberate for 0.2:> a B<resumed> run
starts its accumulators at zero. The transcript knows what each turn
cost; adding those up across processes is a runtime store's job rather
than a transcript's, and the loop does not pretend otherwise.

=head2 The artifact path: one huge result, twice

A 400KB C<fs_read> is bigger than some windows on its own, and it does
not go away: it enters the conversation, the transcript and every
subsequent request, and compaction refuses to eat the recent turns it
sits in. So a result over C<< request-budget.max-observation-size >>
characters is B<excerpted> into the conversation and written whole to a
file beside the transcript.

The invariant is one sentence: B<the excerpt is computed once, on the
settle path, before the tool message is built>. So the conversation
content, the session payload, the C<ToolResult> event's C<content> and
the C<result-digest> on the C<tool-settled> envelope are all the same
string, the full bytes are in the artifact file and nowhere else, and a
resumed run replays byte for byte B<without the artifact existing at
all>. Deleting the whole C<.artifacts> directory loses the ability to
read what the tool really said; it cannot break a resume.

The rest of the design — head-weighted excerpt, the marker line, why the
file is named by B<basename> rather than by path, why retention is
B<none>, and how this differs from the compactor's C<tool-result-cap> —
is in L<LLM::Agent::Artifacts>. Two things belong here:

=item A write that fails is B<shielded>. The model still gets an
excerpt, it says the full result could not be stored, the operation still
settles, and the failure comes out as a C<Log> event. A tool call is not
a failure because a scratch file could not be opened.

=item A B<sessionless> run has nowhere durable to put anything, so it
excerpts and says so in the marker. Nothing is written, and no
C<artifact> metadata is claimed.

=head2 Grants, and when they are written

A provider that C<can('grants')> — an C<MCP::Client::Policy> does — is
asked for its snapshot, and a snapshot that has B<changed> is written to
the session as a whole. Two details are load-bearing:

=item B<Changed means different, not bigger.> The comparison is a digest
of the whole snapshot, so a policy that narrows a rule, replaces one, or
drops one is written out exactly as one that added a rule is. A loop that
only noticed growth would resume tomorrow with permissions the human
revoked today.

=item B<An "always" answer is written as soon as it exists,> rather than
when the batch it was asked inside of ends. The gap between those two
moments is a tool call — the slowest and most interruptible part of a
round — and a run that is cancelled or killed inside it would otherwise
lose the answer and ask the same question again after the resume.

"As soon as it exists" is doing some work in that sentence, and it is
worth knowing why. C<wrap-ask> runs B<inside> the ask: a policy calls the
loop's shim, and only records the rule once the shim has returned to it.
So the loop cannot write the new grant from inside the shim — at that
moment there is no new grant. The policy is the only thing that knows
when there is, and so the policy says so: wire C<< on-grant =>
$loop.grant-hook >> and the snapshot is written the moment it changes,
with the tool call the question was about still running.

C<grant-hook> is the whole mechanism. (0.1.x guessed instead: a task that
polled the provider's digest for a couple of seconds after every "always"
answer and wrote whatever it saw. It worked, and it was a poll where a
callback belongs.)

=item B<And, unwired, the loss is bounded to one tool call.> Whether or
not anything calls the hook, the loop compares digests and writes after
B<every> operation settles — so the worst case for a policy with no
C<on-grant> is that a grant answered during a call reaches disk when that
call finishes, rather than when the whole batch does. That is what
per-operation dispatch buys here.

They are also written on the way out of a run that is ending on a
cancelled tool call or on a backend chain that failed, because those are
exits that can happen with an answer given and nothing yet on disk.

B<Every> one of these writes is shielded: a session that cannot take the
line produces a C<Log> event rather than an exception. On the exit paths
that is because the run's terminal has already been decided and a grant
that could not be saved must not relabel it; on the per-operation path it
is because the rest of the batch still has to be closed off, and a
transcript with unanswered C<tool_calls> in it is worth more damage than
a missing grant is. (0.1.x let that one failure take the run down. It was
the only unshielded sync, and it was the one in the worst place.)

=head2 Failure

Every failure is classified by L<LLM::Chat::Retry>'s C<classify-error> —
the same policy L<LLM::Data::Inference::Task> has run in production —
into C<abort>, C<retry-same> or C<advance>:

=begin table

Bucket     | What the loop does
===========|====================================================================
abort      | AttemptFailed, then RunFailed. 4xx will not heal in eight seconds.
retry-same | AttemptFailed with a backoff, sleep, same backend again
advance    | AttemptFailed, next backend in the chain, no wait

=end table

C<max-retries> is the number of B<attempts per backend> (Task's
semantics, not "extra tries"): 3 means one call and two retries before
the chain advances. When the budget runs out, the C<AttemptFailed> says
C<advance>, because C<disposition> reports what the loop B<does> rather
than what the classifier said in the abstract.

When every backend is spent, the run ends with C<RunFailed> carrying the
full C<attempts> list — the same C<< { backend-index, model, error,
raw-text? } >> records C<X::LLM::Chat::Retry::Exhausted> would have
carried, and no C<reason>: there is nothing to say about it beyond what
the attempts already say. The failures that B<do> carry a C<reason> are
the two the loop chose rather than suffered — C<context-exhausted> (it
will not fit, and compaction cannot help) and C<budget-exhausted> (a run
cap was reached), both above.

=head3 Mid-stream failure: what a consumer must do

A backend can fail after streaming four hundred tokens. Those tokens were
emitted; a Supply has no undo. The B<attempt framing> is the contract,
and it is documented in full in L<LLM::Agent::Event> — in short, a
C<Token> belongs to the C<AttemptStarted> that opened it, and an
C<AttemptFailed> B<retracts> every Token since. A consumer that ignores
this renders the model's reply twice.

Nothing a failed attempt streamed reaches the session: only committed
messages are written, so a transcript can never contain half a sentence
the model was in the middle of when a load balancer dropped the
connection.

=head3 The timeout is inactivity, not duration

C<round-trip-timeout> (default 120s) measures the gap since the response
last did B<anything> — C<< $resp.last-activity-at >> — and not the total
time the request has taken.

This is a deliberate divergence from L<LLM::Data::Inference::Task>, which
bounds total duration. Task generates one JSON document per item and a
slow one is a stuck one. An agent turn legitimately runs for minutes: a
reasoning model thinks, a long file is summarised, a big diff is written.
Bounding total time there means killing successful work at the point it
has cost the most. What is never legitimate is a stream that stops
producing tokens and never closes, which is exactly what a dropped
connection behind a proxy looks like, and that is what this catches.

A timeout calls C<< $backend.cancel($resp) >> and is classified as
C<timeout> — which is the C<advance> bucket, so the next backend gets the
turn immediately rather than after a backoff.

=head2 Cancellation

C<< $run.cancel >> is cooperative, and the difference between what is
promised and what is not is worth knowing before you build a UI on it.

B<Promised:>

=item No events after the terminal C<RunCancelled>.

=item The in-flight stream is cancelled at the backend. (Whether that
actually stops the generation upstream is the backend's business — among
the LLM::Chat backends only KoboldCpp really aborts; the others stop
reading.)

=item No further rounds start.

=item A backoff sleep ends within one 0.25s chunk, not at the end of the
backoff.

B<Not promised:>

=item B<Interrupting an in-flight tool call.> The provider bridge has no
cancellation, so the call that is running will finish. The loop stops
waiting for it, drains the result and ignores it: no C<ToolResult> is
emitted, and no result reaches the conversation. The run ends promptly;
the C<fs_write> that was already in flight still happened.

Because calls are dispatched one at a time, a cancel arriving mid-batch
finds the batch in two halves, and the loop says two different things
about them:

=item2 the call B<in flight> settles C<outcome-unknown> — C<ToolAbandoned>
with C<< dispatched => True >>, and a C<tool> message saying the run was
cancelled before it returned and that whether it took effect is unknown;

=item2 the calls B<behind it> settle C<abandoned> — C<ToolAbandoned> with
C<< dispatched => False >>, and a C<tool> message saying they did not run,
which is a thing the loop can promise about a call it never dispatched.

Those synthetic messages are not results. They are what keeps the
transcript B<resumable>: an assistant turn carrying C<tool_calls> that
nothing answers is a conversation every OpenAI-compatible provider rejects
with a 400, so a cancelled run would otherwise leave a session that can
never be continued. Neither is C<is-error>: one is unknown and the other
did not happen, and neither is a failure.

=item B<Interrupting a blocked permission prompt.> An ask is a leaf: the
policy holds a non-reentrant lock and is waiting for a human. Cancelling
the run cannot dismiss a modal that something else owns. The run ends
when the question is answered.

=head3 result ends the run; drained ends the work

The detached tool call is exactly where the two Promises on a Run part
company. C<< $run.result >> is kept as soon as the loop has stopped
waiting — a cancel should not take as long as the C<fs_write> it
interrupted, and neither should a deadline. C<< $run.drained >> is kept
only when that call has actually returned and nothing can emit into the
run any more.

So: C<result> for "the caller has an answer", C<drained> for "it is safe
to tear the provider down". A test that asserts nothing else arrived
should wait for the second one, because "nothing else arrived" is only
worth asserting once nothing else B<can>.

=head2 Wiring the shims

The loop never talks to a policy, so the app connects them at
construction. There are four shims — C<wrap-ask>, C<log-hook>,
C<grant-hook> and C<progress-hook> — and B<all of them are no-ops when no
run is live>: a late answer, a log or a progress note from a server that
had not noticed the run ended is dropped rather than emitted after the
terminal event.

There is a construction cycle to get round: the loop needs the policy (it
is the provider) and the policy needs the loop (the shim comes from it).
B<Forward-declare the loop and defer the shim into a closure> — the same
idiom L<MCP::Client::Policy>'s own Pod uses for its C<elicit-hook>. What
does B<not> work is C<< on-ask => $loop.wrap-ask(&ask) >> with C<$loop>
still undefined: that calls a method on a type object at construction
time and dies there.

=begin code :lang<raku>

my $loop;                                        # named before it exists

# Permission prompts and server elicitations become AskPending /
# AskAnswered events, and still reach the real asker.
my $policy = MCP::Client::Policy.new(
    :$provider,
    on-ask => -> %request { $loop.wrap-ask(&ask-the-human).(%request) },
    # "Always" answers reach the transcript the moment the policy has
    # recorded them, rather than when the tool call ends.
    on-grant => -> | { $loop.grant-hook.() },
);

# Server log notifications become Log events, and progress notifications
# become ToolProgress. NOTE the log-level: a modern MCP server sends
# NOTHING without one.
my $mcp = MCP::Client.connect-stdio(
    command     => 'mcp-filesystem',
    on-log      => -> %params { $loop.log-hook.(%params) },
    on-progress => -> %params { $loop.progress-hook.(%params) },
    log-level   => 'info',
);

$loop = LLM::Agent::Loop.new(:@backends, provider => $policy);

=end code

C<wrap-ask> emits C<AskPending>, calls the real asker (which still
blocks, and still holds the policy's lock), emits C<AskAnswered>, and
returns the answer untouched. An asker that throws is rethrown so the
policy's own handling — refuse this one call, say why — is unchanged;
the C<AskAnswered> is still emitted, so an C<AskPending> is never left
open.

It does one thing more, and it is what makes the tool deadline humane:
the question is B<timed against the operation it is about>. Dispatch is
sequential, so the call in flight when a question is raised is the call
the question is about, and the seconds a human takes are subtracted from
that call's deadline — see L</The tool deadline, and the humans it waits
for>.

What it deliberately does B<not> do is write grants. It runs inside the
ask, where the answer it just carried has not been recorded by anything
yet; C<grant-hook> is how a policy says it has. See L</Grants, and when
they are written>.

=head3 Emitting from above the loop

The three shims above turn something the loop is B<given> into an event.
C<emit-external> is the other direction: a layer sitting on top of the
loop hands it an event it built itself, and the loop publishes it onto
the run in flight — stamped, ordered and mailboxed like the driver's own.

=begin code :lang<raku>

# A subagent composer forwarding a child run's events; see
# LLM::Agent::Subagents, which is the reason this seam exists.
$loop.emit-external(LLM::Agent::Event::Subagent.new(
    agent-id => 'reviewer-1', agent-type => 'reviewer',
    inner    => $child-event.to-hash,
));

=end code

It answers False rather than throwing when there is no live run or the
run has finished, which is what makes it safe to call from a thread that
belongs to something with a longer life than the run — a child that is
still winding down after its parent ended is the ordinary case, not an
error. What it will not do is end a run: a terminal event is refused
loudly, because only C<_finish> can keep the result Promise.

B<Use C<emitter-for> instead when the emitter outlives the run.>
C<emit-external> publishes onto whatever run is live B<at the moment it
is called>, which is right for a hook firing inside the run and wrong
for anything that reports late: a straggler from run A, arriving after
run B has started on the same loop, would be published onto B — a turn
in B's transcript that never happened. C<< $loop.emitter-for($run) >>
hands back a Callable bound to that one run, which answers False for
ever once it ends rather than following the loop to the next one.

=begin code :lang<raku>

# Captured when the work starts...
my &emit = $loop.emitter-for($loop.live-run);

# ...and used for that work's whole life, wherever it ends up running.
start {
    for @late-events -> $event {
        last unless &emit($event);   # False: my run is over. Stop.
    }
}

=end code

=head2 Resuming: what "the same message" means

A run given a C<session> that already holds messages has to B<extend>
that transcript rather than rewrite it, so the messages it was handed are
checked against the ones the session replayed, index by index. The check
is a B<digest> (L<LLM::Agent::Canonical>) over everything that survives
the round trip — role, content, tool calls, tool-call id, sticky,
sysprompt, depth — and not a comparison of role and text.

That matters because the differences that break a resumed conversation
are exactly the ones prose does not show: an assistant turn that has
grown a C<tool_calls> array, a tool result answering a different call
id, a system prompt that is no longer sticky. A run whose prefix does not
match ends B<immediately>, with a C<RunFailed> naming the index it
disagreed at and nothing written to the session; the fix is always to
start from C<< $session.messages >>.

=head2 Runtime context: the half that is not history

C<< run(@messages, context => $context) >> takes an
L<LLM::Agent::RunContext>: today's date, the working directory, the
branch, the project's instruction file — everything that is true B<now>
rather than everything that happened. It is rendered into the B<request>
and nowhere else:

=begin code :lang<text>

    what goes on the wire   [ head, |@conversation, tail ]
    what everything else sees              @conversation

=end code

The wire view is built in exactly one place — the line that calls
C<chat-completion-stream> — and is never stored, counted or compared.
C<@conversation> itself never contains the context, which is what keeps
all of the following true and unchanged:

=item the B<seed check> compares the same messages it always did, so a
run may carry a completely different context from the one the transcript
was written with (that is the point of the whole mechanism);

=item the B<session> records the same message lines, in the same order;

=item the B<compactor> is handed the conversation, never a request;

=item C<< RunStarted.message-count >> and C<< %outcome<messages> >> count
history, not framing.

What B<is> recorded is one C<run-context> envelope per run that had one
(see L<LLM::Agent::Session>), written after the seed check — a run that is
refused leaves no line — and B<shielded>, so a transcript that cannot take
an audit record never fails a run that would have worked.

=head3 What the context costs, and where that number goes

The rendered head and tail are weighed B<once per run>, as text, through
the counter's C<count-text> (L<LLM::Agent::TokenCount>). Deliberately not
by counting the wire view: the counter is shared with the compactor and
calibrated against the bare conversation, so an array with two extra
messages in it is a conversation it does not recognise — C<Usage> would
throw its calibration away every round, and every number downstream would
get worse.

That one figure is then added as its B<own term> in the two places a size
is compared against a limit: the preflight's C<needed> B<and> its
C<usable> (so a forced compaction aims at the room left for the
conversation, rather than compacting to a target the context then
overflows), and the compaction trigger. It is deliberately B<not> passed
to the compactor as a target: C<Compactor>'s no-op path reports
C<exhausted> against the target it was given, and a reduced one would turn
a compaction with nothing to drop into a C<context-exhausted> terminal.

One consequence worth knowing about a heterogeneous chain: a
L<LLM::Agent::RequestBudget> C<Profile> that carries a C<counter> of its
own counts the B<conversation> with it, but the context figure is the
B<loop's> counter's — it is weighed once for the run, before a backend has
been chosen, exactly as the tool declarations are. On a chain whose
tokenizers disagree sharply, treat the per-model profile's
C<input-safety-margin> as where that difference is paid for.

=head3 The calibration, across a context change

A calibration is "P prompt tokens for these N messages", and P was billed
for a request that also carried the context of the run that recorded it.
So a run whose context digest B<differs> from the previous run's calls
C<< counter.invalidate >> before it starts: at most one calibration
dropped per run boundary, none at all when the context is unchanged, and
the very next successful attempt re-calibrates.

=head2 Tool declarations are fetched once

C<tools-for-llm> is called B<once per run>, not once per round. A round
is a network call, and asking an MCP server to re-list its catalogue
before each of them doubles the round trips for a list that changes
approximately never. A server that adds a tool mid-run is not noticed
until the next run.

=head1 SEE ALSO

L<LLM::Agent::Run>, L<LLM::Agent::Event> (especially the attempt-framing
contract), L<LLM::Agent::ToolOperation> (what a tool call's states mean),
L<LLM::Agent::Session>, L<LLM::Agent::Compactor>,
L<LLM::Agent::RunContext> (what a run is told about now),
L<LLM::Agent::RequestBudget> (what fits and what it may cost),
L<LLM::Agent::Artifacts> (the excerpt and the file behind it),
L<LLM::Agent::Subagents> (a provider that spawns child runs, and the
consumer of C<emit-external>), L<LLM::Chat::Retry>,
L<MCP::Client::Policy>.

=end pod

use JSON::Fast;
use UUID::V4;

use LLM::Chat::Conversation::Message;
use LLM::Chat::Retry;

use LLM::Agent::Event;
use LLM::Agent::Run;
use LLM::Agent::RunContext;
use LLM::Agent::TokenCount;
use LLM::Agent::ToolOperation;

# NB: THESE THREE LAST, and out of alphabetical order on purpose. Each of
# them declares something UNDER a name in the LLM::Agent namespace — a
# nested class (RequestBudget::Profile), a `unit module` — and importing
# one BEFORE the sibling classes shadows the lexical view of that
# namespace: LLM::Agent::Run and LLM::Agent::TokenCount then stop
# resolving by name, several hundred lines below, as "Type ... is not
# declared". The fix is the order, so leave them here.
use LLM::Agent::RequestBudget;
use LLM::Agent::Artifacts;
use LLM::Agent::Canonical;

unit class LLM::Agent::Loop;

#|( What the model is told when a limit stops the tools. C<ToolLoop>'s
    wording, verbatim: it is tuned, it is what models in the wild have
    been trained against, and two agent loops in one ecosystem saying
    different things about the same situation helps nobody. )
our constant LIMIT-MESSAGE =
	'Tool call limit reached. Do not call tools again. Answer using the information already available, and state if more tool work would be needed.';

my constant Message = LLM::Chat::Conversation::Message;

#|( What the model is told about a call that was cancelled B<before it was
    dispatched>. The strongest thing the loop can say about a tool call,
    and it is only ever said about one the provider was never handed. )
our constant NEVER-RAN-MESSAGE =
	'The run was cancelled before this tool call was dispatched. It did not run.';

#|( The same, for a call left undispatched because a run cap tripped. )
our constant NO-BUDGET-MESSAGE =
	'The run ran out of budget before this tool call was dispatched. It did not run.';

#|( What the model is told about a call that B<was> dispatched and then
    detached by a cancel. Deliberately the same shape as App::Sadna's
    crash-repair wording: from the model's side, "we stopped waiting" and
    "the process died" are the same situation and deserve the same
    sentence. )
our constant CANCELLED-UNKNOWN-MESSAGE =
	'The run was cancelled before this tool call returned. Whether it took '
	~ 'effect is unknown.';

#| The same, for a call that outlived C<tool-deadline>.
our constant DEADLINE-UNKNOWN-MESSAGE =
	'This tool call did not return within its deadline. Whether it took '
	~ 'effect is unknown.';

#| The fallback chain, tried in order on every round trip.
has @.backends is required;

#|( The tool provider: anything with C<tools-for-llm> and
    C<execute-tool-calls>. Undefined makes this a plain chat loop. )
has $.provider;

#| The counting seam. Shared with the compactor — see its Pod.
has LLM::Agent::TokenCount:D $.counter = LLM::Agent::TokenCount::Usage.new;

#| The context window in tokens. Taken from the compactor when there is
#| one and this is not set. Expands into a C<request-budget> — see
#| L</What fits, and what it costs>.
has Int $.context-budget;

#|( An L<LLM::Agent::RequestBudget>: what fits each backend, what a tool
    result may weigh, and what the run may spend. Synthesized from
    C<context-budget> when that is all there is; undefined leaves the
    loop with no preflight, no artifact path and no caps. )
has LLM::Agent::RequestBudget $.request-budget;

#|( Where oversized tool results are spilled. Defaults to
    C<< <transcript-stem>.artifacts/ >> beside the session's file, and is
    undefined — so nothing is ever spilled — on a sessionless run. )
has LLM::Agent::Artifacts::Store $.artifact-store;

#| Where the transcript goes. Optional; without one nothing is durable.
has $.session;

#| An L<LLM::Agent::Compactor>, or nothing to never compact.
has $.compactor;

#| Tool rounds before the model is told to answer with what it has.
has Int:D $.max-tool-rounds = 1_000;

#| Total tool calls across the run, same treatment.
has Int:D $.max-tool-calls = 10_000;

#|( How often the same call — same name, same arguments, B<key order and
    whitespace ignored> — may be made before it counts as a loop. Counted
    across the run and within the current batch; only B<dispatched> calls
    count, and one whose outcome is unknown counts too. See the Pod. )
has Int:D $.max-identical-calls = 3;

#|( Attempts per backend, including the first. Task's semantics: 3 means
    one call and two retries before the chain advances. )
has Int:D $.max-retries = 3;

#|( Seconds a single tool call may run before the loop stops waiting for
    it. Undefined (the default) means no deadline at all.

    B<A deadline that passes is not a failure.> The call is detached, the
    operation settles C<outcome-unknown>, and the model is told that
    whether it took effect is unknown — because a local clock knows
    nothing about a remote side effect. The run carries on.

    The clock B<pauses while a human is being asked>: see
    L</The tool deadline, and the humans it waits for>. )
has Real $.tool-deadline;

#|( How to classify a tool by name: a list of
    C<< { tool => <pattern>, idempotency => <class> } >> rules, first
    match wins, C<unknown> for anything unmatched.

    C<pattern> is an exact tool name or a trailing-C<*> prefix glob — the
    same shape an C<MCP::Client::Policy> rule uses — and C<class> is one
    of C<read-only>, C<idempotent>, C<destructive>, C<unknown>.

    It is B<configuration>, not discovery: no MCP server publishes
    anything of the sort. What it buys is a repair that can word itself
    honestly about an operation whose outcome is unknown. The loop never
    retries anything on the strength of it. )
has @.idempotency-rules;

#|( Seconds of B<inactivity> — not total duration — before a stream is
    given up on. See the Pod on why this differs from Task. )
has Real:D $.round-trip-timeout = 120;

has Lock:D $!lock .= new;
has LLM::Agent::Run $!run;

#|( The digest of the grant snapshot as it was last written out (or as it
    was when the run started, which is the same thing for a resumed
    session). An attribute rather than a variable in the state machine
    because C<grant-hook> writes grants too — off the asker's thread, the
    moment a policy records a rule — and the driver must not then write
    the same snapshot again when the operation settles.

    Guarded by C<$!grants-lock> rather than by the loop's own lock: a sync
    is read-snapshot-then-write and has to be atomic across all of it, and
    the write is a file append that the loop's lock — which a cancel pokes
    through — has no business waiting behind. )
has Str $!grants-digest;
has Lock:D $!grants-lock .= new;

#|( The digest of the L<LLM::Agent::RunContext> the B<previous> run was
    given, or an undefined Str for a run that was given none. Guarded by
    C<$!lock>, where it is read and replaced in one step at the top of a
    run — see C<run>, and C<LLM::Agent::TokenCount>'s C<invalidate> for
    what it is for. )
has Str $!context-digest;

#|( The in-flight stream, C<< { run-id, backend, response } >>, tagged
    with the run that owns it. The tag is the whole point: a run that has
    ended must not be able to cancel the stream of the run that replaced
    it, and every reader here checks the tag before it touches anything. )
has %!active;

#|( The tool operation currently dispatched, C<< { run-id, op } >>, tagged
    with its run for the same reason C<%!active> is.

    B<Dispatch is sequential>, so there is at most one, and that is what
    makes the two shims able to correlate: an C<AskPending> that arrives
    while an operation is in flight is about B<that> operation (so its ask
    span goes on it, and the deadline pauses), and a progress notification
    is only believed when it names that operation's call.

    Its own lock, not the loop's: a cancel pokes through C<$!lock>, and a
    shim reading this must never be able to sit behind one. )
has %!in-flight;
has Lock:D $!op-lock .= new;

#|( What the run in flight has spent: C<< { run-id, started-at, cost,
    total-tokens, reported-cost } >>. Tagged with its run for the same
    reason C<%!active> is — a stale attempt record arriving from a run
    that has ended must not be added to the next run's bill.

    Its own lock: usage is recorded on whichever thread finished the
    attempt, and the caps are read from the driver's thread between tool
    operations. Neither has any business waiting behind the other, or
    behind a cancel poking C<$!lock>. )
has %!spend;
has Lock:D $!spend-lock .= new;

submethod TWEAK {
	die 'LLM::Agent::Loop: backends cannot be empty — there is nothing to '
		~ 'ask'
		unless @!backends.elems;

	with @!backends.first({
		!($_.defined && $_.can('chat-completion-stream') && $_.can('cancel'))
	}, :k) -> $index {
		die "LLM::Agent::Loop: backend $index is a "
			~ @!backends[$index].^name ~ ', which cannot '
			~ 'chat-completion-stream and cancel — a backend has to be an '
			~ 'LLM::Chat::Backend, or shaped like one';
	}

	die 'LLM::Agent::Loop: a provider must have both tools-for-llm and '
		~ 'execute-tool-calls (an MCP::Client, a Registry, a Policy, or '
		~ 'anything shaped like one); got a ' ~ $!provider.^name
		if $!provider.defined
			&& !($!provider.can('tools-for-llm')
				&& $!provider.can('execute-tool-calls'));

	if $!session.defined {
		die 'LLM::Agent::Loop: a session must be an LLM::Agent::Session (or '
			~ 'something with its append-message / messages / message-ids '
			~ 'methods); got a ' ~ $!session.^name
			unless $!session.can('append-message') && $!session.can('messages')
				&& $!session.can('message-ids');

		# The two conditional halves of the session's surface. A stand-in
		# that can hold messages but not compactions is fine until the
		# first compaction — which is a round or an hour in, with a run
		# half-written. Same die-at-construction rule as everything else
		# here: the wiring is wrong now, so say so now.
		die 'LLM::Agent::Loop: this loop has a compactor, so its session '
			~ 'also needs append-compaction (an LLM::Agent::Session has one); '
			~ 'got a ' ~ $!session.^name
			if $!compactor.defined && !$!session.can('append-compaction');

		die 'LLM::Agent::Loop: this loop has a provider, so its session also '
			~ 'needs append-grants (an LLM::Agent::Session has one) — a '
			~ 'provider that answers permission questions has grants to '
			~ 'write, and a session that cannot take them makes the human '
			~ 'answer them again after every resume; got a ' ~ $!session.^name
			if $!provider.defined && !$!session.can('append-grants');

		# The tool-operation half of the same surface, for the same reason:
		# a session that can hold messages but not operations would be
		# found out at the first tool call, with a run half written and a
		# transcript that cannot say what was in flight when it stopped.
		if $!provider.defined {
			my @missing = <append-tool-dispatched append-tool-settled
				pending-tool-operations>.grep({ !$!session.can($_) });
			die 'LLM::Agent::Loop: this loop has a provider, so its session '
				~ 'also needs ' ~ @missing.join(' / ') ~ ' (an '
				~ 'LLM::Agent::Session has them) — without them a tool call '
				~ 'that a crash interrupts leaves a transcript that cannot '
				~ 'say whether it ran; got a ' ~ $!session.^name
				if @missing.elems;
		}
	}

	if $!compactor.defined {
		die 'LLM::Agent::Loop: a compactor must be an LLM::Agent::Compactor '
			~ '(or something with its trigger / compact / context-budget); '
			~ 'got a ' ~ $!compactor.^name
			unless $!compactor.can('trigger') && $!compactor.can('compact')
				&& $!compactor.can('context-budget');

		# A compactor already knows the budget; carrying it twice only
		# creates a way for the two to disagree.
		$!context-budget //= $!compactor.context-budget;
		die 'LLM::Agent::Loop: context-budget is ' ~ $!context-budget
			~ " but the compactor's is " ~ $!compactor.context-budget
			~ ' — they describe the same window, so set one or make them '
			~ 'agree'
			unless $!context-budget == $!compactor.context-budget;
	}

	# The shorthand, expanded. A context-budget on its own used to be
	# decorative unless a compactor read it; it now describes a window the
	# preflight can refuse a request against, which is what makes a
	# conversation that cannot fit end the run cleanly instead of being
	# sent. See LLM::Agent::RequestBudget on why the synthesized profile
	# carries no margin and no reserve.
	if $!request-budget.defined {
		with $!request-budget.default-profile -> $default {
			die 'LLM::Agent::Loop: context-budget is ' ~ $!context-budget
				~ " but the request budget's default profile has a window of "
				~ $default.context-window ~ ' — they describe the same '
				~ 'window, so set one or make them agree'
				if $!context-budget.defined
					&& $!context-budget != $default.context-window;
		}
	}
	elsif $!context-budget.defined {
		$!request-budget = LLM::Agent::RequestBudget.for-window($!context-budget);
	}

	# A compactor that converges above a backend's ceiling is a loop that
	# compacts, fails the preflight, compacts again and gets nowhere. Said
	# at construction, where the two numbers are in front of somebody.
	if $!compactor.defined && $!request-budget.defined {
		my @windows = $!request-budget.windows;
		if @windows.elems && $!compactor.context-budget > @windows[0] {
			die 'LLM::Agent::Loop: the compactor compacts to a '
				~ $!compactor.context-budget ~ '-token budget, but the '
				~ 'smallest window any profile declares is ' ~ @windows[0]
				~ ' — every compaction would converge on a conversation that '
				~ 'backend still cannot take';
		}
	}

	# Beside the transcript, and only when there is one: a run with no
	# session has nowhere durable to put an artifact, and says so in the
	# excerpt rather than writing a file nothing will ever reference.
	if !$!artifact-store.defined && $!session.defined && $!session.can('path') {
		my $path = $!session.path;
		$!artifact-store = LLM::Agent::Artifacts::Store.new(
			dir => artifact-dir-for($path),
		) if $path.defined;
	}

	die 'LLM::Agent::Loop: round-trip-timeout must be positive'
		unless $!round-trip-timeout > 0;
	die 'LLM::Agent::Loop: max-retries must be at least 1 — it counts '
		~ 'attempts per backend, not extra ones'
		unless $!max-retries >= 1;
	die 'LLM::Agent::Loop: max-identical-calls must be at least 1'
		unless $!max-identical-calls >= 1;
	die 'LLM::Agent::Loop: tool-deadline must be positive — leave it '
		~ 'undefined for no deadline at all'
		if $!tool-deadline.defined && $!tool-deadline <= 0;

	# Validated here rather than at the first tool call: a rule that says
	# 'read-onlyy' is a typo somebody wants to hear about while they are
	# looking at the config, not an hour into a run.
	for @!idempotency-rules.kv -> Int $index, $rule {
		die "LLM::Agent::Loop: idempotency rule $index is a "
			~ $rule.^name ~ ', which is not a { tool => ..., idempotency '
			~ '=> ... } hash'
			unless $rule ~~ Associative;

		my $pattern = $rule<tool>;
		die "LLM::Agent::Loop: idempotency rule $index has no tool pattern — "
			~ "a rule names a tool, as an exact name or a trailing-'*' "
			~ 'prefix glob'
			unless $pattern ~~ Str:D && $pattern.chars;

		my $class = $rule<idempotency>;
		die "LLM::Agent::Loop: idempotency rule $index for '$pattern' is '"
			~ ($class // 'none') ~ "'; a class is one of "
			~ LLM::Agent::ToolOperation::IDEMPOTENCY-CLASSES.keys.sort.join(', ')
			unless $class ~~ Str:D
				&& LLM::Agent::ToolOperation::IDEMPOTENCY-CLASSES{$class};
	}
}

# === The public surface ===

#|( Start a run over C<@messages> and hand back its L<LLM::Agent::Run>
    immediately. The array is copied; the Messages in it are not, and are
    never mutated.

    C<:$context> is an optional L<LLM::Agent::RunContext>: what is true
    B<right now> — the date, the working directory, the branch, the
    project's instruction file. It is rendered into B<the request> and
    never into C<@messages>, so nothing about it is written to the
    transcript as a turn, digest-locked by the seed check, or visible to a
    compaction. See L</Runtime context: the half that is not history>.

    Dies if this loop already has a live run. )
method run(
	@messages where all(@messages) ~~ LLM::Chat::Conversation::Message,
	LLM::Agent::RunContext :$context,
	--> LLM::Agent::Run:D
) {
	die 'LLM::Agent::Loop.run: there is nothing to send — a run starts '
		~ 'from at least one message'
		unless @messages.elems;

	# The id is generated here rather than left to the Run, because the
	# cancel hook has to close over it: a hook that captures no identity
	# pokes whatever slot the loop happens to hold when it fires, which on
	# a run that has already ended is somebody else's stream.
	my Str $run-id = uuid-v4;
	my $run = LLM::Agent::Run.new(
		id => $run-id, on-cancel => { self!poke-cancel($run-id) },
	);

	# Where the grants stood before this run touched anything, so that the
	# first sync writes only what this run actually changed. Read out here
	# rather than under the lock below: `grants` is the provider's code and
	# the loop's lock is never held across somebody else's.
	my Str $grants-digest = self!grant-digest;

	# What this run's context is, against what the last one's was. The
	# comparison is `eqv` rather than `eq` so that "no context at all" is a
	# value like any other: a run that drops a context it used to have has
	# changed the request just as surely as one that changes its date.
	my Str $context-digest = $context.defined ?? $context.digest !! Str;
	my Bool $context-changed = False;

	$!lock.protect: {
		die 'LLM::Agent::Loop: this loop already has a run in flight. One '
			~ 'run at a time — build a second Loop, or queue them above '
			~ 'this layer'
			if $!run.defined && !$!run.is-done;
		$!run = $run;

		$context-changed = !($!context-digest eqv $context-digest);
		$!context-digest = $context-digest;
	};
	$!grants-lock.protect: { $!grants-digest = $grants-digest };

	# Outside the lock, because the counter is somebody else's code and
	# this lock is the one a cancel pokes through. What it fixes: a
	# calibration is "P tokens for these N messages", and P was billed for
	# a request that ALSO carried the previous run's context. With a
	# different context the arithmetic is about a prompt nobody is sending
	# any more, so it is dropped — at most once per run, and never when the
	# context is the one it was calibrated with.
	$!counter.invalidate if $context-changed;

	# The working array: our own, so a caller that keeps mutating theirs
	# cannot change the conversation underneath a live run.
	my @conversation = @messages.List;
	my @attempts;

	# The driver's own work section, opened before the state machine so
	# that `drained` cannot resolve until the epilogue below has run to
	# its last line. A fresh Run never refuses, but the ticket is honoured
	# rather than assumed.
	my Bool $ticket = $run._work-begin;

	start {
		# `!drive` no longer finishes the run: it returns the finish spec
		# and lets the epilogue do it, so that cleanup strictly precedes
		# the moment `is-done` flips and the next run is admitted.
		my %finish;
		{
			CATCH {
				default {
					# A driver that dies without a spec leaves the result
					# Promise Planned forever, and anybody awaiting it
					# hangs. Every exit path produces one.
					my $error = 'LLM::Agent::Loop: the run died: '
						~ (.message.lines.head // .^name);
					%finish = failure-spec($error, @attempts, @conversation);
				}
			}
			%finish = self!drive($run, @conversation, @attempts, $context);
		}

		# Belt and braces for a future edit that returns something which is
		# not a finish spec: `_finish` would die on it, in a start block
		# nobody awaits, and the run would hang Planned forever.
		unless %finish<terminal> ~~ LLM::Agent::Event:D
			&& %finish<terminal>.is-terminal {
			%finish = failure-spec(
				'LLM::Agent::Loop: the run ended without a result',
				@attempts, @conversation,
			);
		}

		# What it cost, on every exit including the one where the driver
		# died: added here rather than in each of the four finish specs,
		# because there is exactly one place every one of them passes
		# through and this is it. Absent — not zero — on a loop with no
		# budget, so "nobody was counting" and "nothing was spent" stay
		# different answers.
		my %outcome = %finish<outcome>.Hash;
		%outcome<spent> = self!spent if $!request-budget.defined;

		# THE EPILOGUE, and the order is the contract. Let go of the
		# stream slot first, because `_finish` is what admits the next
		# run; finish; then close the driver's work section last, so
		# `drained` is only ever visible after this run stopped touching
		# anything. None of the three can throw.
		self!clear-active($run.id);
		$run._finish(%finish<terminal>, |%outcome);
		$run._work-done if $ticket;
	}

	$run;
}

#|( An C<on-ask>-shaped wrapper around C<&on-ask>: it emits C<AskPending>,
    calls the real asker, emits C<AskAnswered>, and returns whatever the
    asker returned. An asker that throws is B<rethrown> so a policy's own
    refusal handling is unchanged — and the C<AskAnswered> is emitted
    anyway, so a pending question is never left open.

        # (the loop is forward-declared — see "Wiring the shims")
        MCP::Client::Policy.new(
            :$provider,
            on-ask => -> %request { $loop.wrap-ask(&ask).(%request) },
        );

    With no live run both events are dropped: an answer that arrives
    after the run ended must not appear after its terminal event. )
method wrap-ask(&on-ask --> Callable:D) {
	-> %request {
		my $run = self!live-run;
		# A ticket the run may refuse (it can close between the line above
		# and this one), and a LEAVE so that the rethrow path below closes
		# the section as reliably as the normal one.
		my Bool $ticket = $run.defined && $run._work-begin;
		LEAVE { $run._work-done if $ticket; }

		# Dispatch is sequential, so a question asked now is a question
		# about the operation in flight — and the seconds a human takes to
		# answer are not seconds that operation spent working. This is what
		# makes `tool-deadline` pause for people.
		my $op = $run.defined
			?? self!in-flight-op($run.id)
			!! LLM::Agent::ToolOperation;
		$op.ask-begin if $op.defined;
		LEAVE { $op.ask-end if $op.defined; }

		my $tool = %request<tool> ~~ Str:D ?? %request<tool>.Str !! Str;

		$run._emit(LLM::Agent::Event::AskPending.new(
			request => %request.Hash, :$tool,
		)) if $run.defined;

		my $answer;
		my $threw;
		{
			CATCH { default { $threw = $_ } }
			$answer = &on-ask(%request);
		}

		$run._emit(LLM::Agent::Event::AskAnswered.new(
			request => %request.Hash,
			answer  => ($threw.defined ?? Nil !! $answer),
		)) if $run.defined;

		# NB: no grant write here. The shim runs INSIDE the ask — the
		# policy only records the rule once this call has returned to it —
		# so there is nothing durable to write yet. The policy tells the
		# loop when there is, through `grant-hook`; see L</Grants, and when
		# they are written>.
		$threw.rethrow if $threw.defined;
		$answer;
	};
}

#|( A C<Callable> for a provider's C<on-grant> hook: whatever it is handed,
    it writes the provider's grant snapshot to the session B<now>.

        MCP::Client::Policy.new(:$provider, :&on-ask, on-grant => $loop.grant-hook);

    It takes no notice of its arguments on purpose. What a policy passes —
    the rule it just recorded, nothing at all — is that policy's business;
    the loop's answer is always the same, and it is the answer that cannot
    go stale: re-read the whole snapshot and write it if its digest has
    moved. That also makes the hook safe to wire to anything with an
    "something changed" callback, whatever shape it calls back with.

    Shielded, and a no-op with no live run: this fires on the asker's
    thread, deep inside somebody else's lock, and a session that could not
    take the line must not surface there as the tool call refusing. The
    failure becomes a C<Log> event and the next sync tries again. )
method grant-hook(--> Callable:D) {
	-> | {
		my $run = self!live-run;
		# `if`, not an early return: this is a Block, and returning from
		# one dies rather than exiting it.
		if $run.defined {
			my Bool $ticket = $run._work-begin;
			LEAVE { $run._work-done if $ticket; }
			self!sync-grants-shielded($run);
		}
	};
}

#|( A C<Callable> for a client's C<on-progress> hook, turning an MCP
    C<notifications/progress> into a C<ToolProgress> event:

        MCP::Client.connect-stdio(..., on-progress => $loop.progress-hook);

    The payload is C<< { tool-call-id, progress, total?, message? } >> —
    what C<MCP::Client> builds after resolving the progress token back to
    the call it was minted for.

    B<Correlated, not trusted.> Dispatch is sequential, so at most one
    operation is in flight, and a notification that names anything else is
    B<dropped>: a straggler from the previous call would otherwise move
    the wrong progress bar, and a token a server invented would create one
    for a call that does not exist. Same shape as C<log-hook> otherwise —
    no live run, no event. )
method progress-hook(--> Callable:D) {
	-> %params {
		my $run = self!live-run;
		if $run.defined {
			my Bool $ticket = $run._work-begin;
			LEAVE { $run._work-done if $ticket; }

			my $op = self!in-flight-op($run.id);
			my Str $id = (%params<tool-call-id> // '').Str;

			if $op.defined && $id.chars && $id eq $op.call-id {
				$run._emit(LLM::Agent::Event::ToolProgress.new(
					:$id,
					progress => numeric-or(%params<progress>, 0e0),
					total    => (%params<total>.defined
						?? numeric-or(%params<total>, 0e0)
						!! Num),
					message  => (%params<message> ~~ Str:D
						?? %params<message>.Str
						!! Str),
					round    => $op.round,
				));
			}
		}
	};
}

#|( An C<on-log>-shaped closure turning a server's C<notifications/message>
    into C<Log> events:

        MCP::Client.new(..., on-log => $loop.log-hook, log-level => 'info');

    B<Set C<log-level>.> Since the 2026-07-28 revision a modern MCP
    server sends no log notifications at all to a request that did not
    carry one, so an C<on-log> hook without a C<log-level> is a hook that
    never fires — and it looks exactly like a server that has nothing to
    say.

    C<data> is passed through when it is text or a structured record and
    stringified otherwise, so a server with an odd idea of a log line
    cannot break the event's type. )
method log-hook(--> Callable:D) {
	-> %params {
		my $run = self!live-run;
		# `if`, not an early return: this is a Block, and returning from
		# one dies rather than exiting it.
		if $run.defined {
			my Bool $ticket = $run._work-begin;
			LEAVE { $run._work-done if $ticket; }

			my $data = %params<data>;
			$data = $data ~~ Associative ?? $data.Hash !! ($data // '').Str;

			$run._emit(LLM::Agent::Event::Log.new(
				level  => (%params<level> // 'info').Str,
				logger => (%params<logger> ~~ Str:D ?? %params<logger>.Str !! Str),
				data   => $data,
			));
		}
	};
}

#|( Publish an event somebody else built onto the run in flight. The seam
    a layer B<above> the loop emits through — a subagent composer
    forwarding a child run's events (L<LLM::Agent::Subagents>), a host
    surfacing something the loop has no opinion about — without that layer
    needing a Run, a vow or the underscore-prefixed driving seam.

        $loop.emit-external(LLM::Agent::Event::Subagent.new(
            agent-id => 'reviewer-1', agent-type => 'reviewer',
            inner    => $child-event.to-hash,
        ));

    The event is stamped with B<this> run's C<run-id> and the next
    C<seq>, exactly as the driver's own events are, and published in the
    order the run's mailbox granted — so an external emitter is ordered
    against the loop's own stream rather than racing it.

    Returns True when the event was accepted and ordered. B<False, and
    nothing else, in every other case>: no run has started, the run in
    flight has finished, or it closed between those two facts and this
    call. It never throws for any of them — an event that arrives one
    moment too late is an ordinary thing for a thread that belongs to
    something the run no longer owns, and "nothing after the terminal"
    matters more than the stray event.

    Safe from any thread. Cannot wedge the run: the work section it opens
    is closed by a C<LEAVE> on every path including a throw, and
    C<_work-begin> refusing (which is what a closed run does) means no
    section was opened and none is closed. C<drained> therefore still
    resolves whatever an emitter does.

    B<Dies> on a terminal event, which is not a race but a category
    error: only the loop may end its own run, because only C<_finish> can
    keep the result Promise, and an outsider that could publish
    C<RunCompleted> could leave a run whose Supply is done and whose
    result never comes. )
method emit-external(LLM::Agent::Event:D $event --> Bool:D) {
	self!publish(self!live-run, $event);
}

#|( A publisher B<bound to one run>: C<< &emit($event) >> publishes onto
    C<$run> and nothing else, for as long as that run accepts events, and
    answers False for ever afterwards.

        my &emit = $loop.emitter-for($run);   # captured when work starts
        ...
        &emit($event);                        # much later, another thread

    This is the seam for anything whose life is B<longer than the run
    that started it> — a subagent still winding down, a detached job, a
    background task that reports late. C<emit-external> asks "what is the
    loop running now?", which is the right question for a hook that fires
    inside the run and the B<wrong> one for a straggler: by the time it
    fires, "now" can be somebody else's run, and an event from run A
    published onto run B is worse than a lost event. It corrupts a
    transcript with a turn that never happened.

    So: capture the emitter when the work starts, use it for that work's
    whole life, and treat False as "my run is over" — drop the event, and
    settle whatever was waiting on it. What it will never do is publish
    into the next run.

    Same rules as C<emit-external> otherwise: stamped and ordered by the
    run's mailbox, safe from any thread, cannot wedge C<drained>, and a
    terminal event is refused loudly because only C<_finish> may end a
    run. )
method emitter-for(LLM::Agent::Run:D $run --> Callable:D) {
	-> LLM::Agent::Event:D $event { self!publish($run, $event) };
}

# The one publication path, shared by both seams. `$run` may be undefined
# (no live run), which is a False rather than a failure.
method !publish($run, LLM::Agent::Event:D $event --> Bool:D) {
	die 'LLM::Agent::Loop: ' ~ $event.kind ~ ' is a terminal event, and a '
		~ 'run is ended only by the loop that drives it — an external '
		~ 'emitter publishes what happened, not that the run is over'
		if $event.is-terminal;

	return False unless $run.defined && !$run.is-done;

	# A ticket the run may refuse: it can close between the line above and
	# this one. False means there is nothing left to attest and the paired
	# _work-done must NOT be called — hence the flag in the LEAVE.
	my Bool $ticket = $run._work-begin;
	return False unless $ticket;
	LEAVE { $run._work-done if $ticket; }

	$run._emit($event);
}

#| The run in flight, or an undefined Run. Poll-friendly and lock-safe.
method live-run(--> LLM::Agent::Run) {
	self!live-run;
}

method !live-run(--> LLM::Agent::Run) {
	my $run = $!lock.protect: { $!run };
	$run.defined && !$run.is-done ?? $run !! LLM::Agent::Run;
}

# === The state machine ===

#|( The state machine. Returns the B<finish spec> the run ends on — it
    never finishes the run itself, because C<run>'s epilogue has cleanup
    to do first. Every exit is a C<return> of one of the three specs. )
method !drive($run, @conversation, @attempts, $context --> Hash:D) {
	$run._emit(LLM::Agent::Event::RunStarted.new(
		run-id => $run.id, message-count => @conversation.elems,
		# The count is of the CONVERSATION, and the digest is the whole of
		# what this event says about the context: a consumer counting
		# messages is counting history, and the context is not history.
		|($context.defined ?? (context-digest => $context.digest) !! ()),
	));

	# The bill starts here, and the clock with it: the caps are about what
	# THIS run spends. A resumed run starts from zero — see the Pod.
	self!spend-begin($run.id);

	my @ids = self!seed-session(@conversation);

	# After the seed check, so a run that was refused leaves no line at
	# all, and shielded, because an audit record must never be the reason
	# a working run fails.
	self!record-context-shielded($run, $context);

	# Once per run: the two rendered messages weigh the same at every
	# round, and this is the number that has to be reserved for wherever
	# the conversation is measured against a window. Counted as TEXT, not
	# through count-messages — see the Pod.
	my Int $context-tokens = self!context-tokens($context);

	my Bool $tools-enabled = $!provider.defined;
	# Once per run, not once per round: see the Pod.
	my @tools = $tools-enabled ?? $!provider.tools-for-llm.list.List !! ();
	$tools-enabled = False unless @tools.elems;

	my Int $round = 0;
	my Int $tool-rounds = 0;
	my Int $total-calls = 0;
	my %call-counts;
	my Str $final = '';

	loop {
		return cancel-spec('start', $round, @conversation)
			if $run.is-cancelled;

		$round++;

		# The caps, at the top of the round: the other half of the check
		# `!run-tool-ops` makes between operations, through the same hook.
		# Here rather than at the bottom of the previous round so that the
		# usage of the round that tripped it has been recorded first.
		my %caps = self!caps-tripped;
		if %caps.elems {
			self!sync-grants-shielded($run);
			return failure-spec(
				caps-error(%caps), @attempts, @conversation, $round,
				reason => 'budget-exhausted',
			);
		}

		# The one thing a compaction can fail at is making the next request
		# fit; when it does, that is the end of the run rather than an
		# exception, and it comes back as a finish spec of its own.
		my %compaction = self!maybe-compact(
			$run, @conversation, @ids, $round, $context-tokens,
		);
		return %compaction if %compaction.elems;

		return cancel-spec('compaction', $round, @conversation)
			if $run.is-cancelled;

		$run._emit(LLM::Agent::Event::RoundStarted.new(
			:$round,
			tokens => (self!budgeted
				?? $!counter.count-messages(@conversation)
				!! Int),
		));

		# The round trip, and — at most once per round — a forced targeted
		# compaction between two of them. `!round-trip` says
		# `context-overflow` when EVERY backend's preflight refused the
		# conversation, which is a different fact from a backend failing:
		# nothing was sent, so nothing has been spent, and the one thing
		# that could still change the answer is making the conversation
		# smaller. Once — a second identical refusal is the end of it.
		my %trip;
		my Bool $recompacted = False;
		loop {
			%trip = self!round-trip(
				$run, @conversation, ($tools-enabled ?? @tools !! ()),
				$round, @attempts, $context, $context-tokens,
			);
			last unless %trip<context-overflow>;
			last if $recompacted;

			my %forced = self!force-compaction(
				$run, @conversation, @ids, $round, %trip<target>,
			);
			return %forced if %forced.elems;
			return cancel-spec('compaction', $round, @conversation)
				if $run.is-cancelled;
			$recompacted = True;
		}

		if %trip<cancelled> {
			# Whatever this round streamed is gone: no assistant message
			# will follow it, and a consumer rendering live tokens has to
			# be told so rather than left with them on screen.
			$run._emit(LLM::Agent::Event::TurnDiscarded.new(
				reason => 'cancelled', :$round,
			));
			return cancel-spec(
				%trip<stage> // 'streaming', $round, @conversation,
			);
		}

		# Still too big for every backend, and there is nothing left to
		# try. No TurnDiscarded: nothing was streamed, because nothing was
		# ever sent — this is the compaction-exhausted terminal reached
		# from the other side, and it carries the same `reason`.
		if %trip<context-overflow> {
			return failure-spec(
				%trip<error>.Str, @attempts, @conversation, $round,
				reason => 'context-exhausted',
			);
		}

		unless %trip<ok> {
			$run._emit(LLM::Agent::Event::TurnDiscarded.new(
				reason => 'failed', :$round,
			));
			# The run is over either way; what a human answered during it
			# is still worth keeping, and this is the last chance to write
			# it. Shielded: a session that cannot take the grants must not
			# turn "every backend failed" into a different error.
			self!sync-grants-shielded($run);
			return failure-spec(
				%trip<error>.Str, @attempts, @conversation, $round,
			);
		}

		my $resp = %trip<response>;
		my @tool-calls = ($tools-enabled ?? $resp.tool-calls.list !! ()).List;

		# Limits BEFORE the turn is committed. See the Pod: an assistant
		# message carrying tool_calls with no matching tool messages is a
		# conversation every provider rejects.
		if @tool-calls.elems {
			my %limit = self!limit-reason(
				@tool-calls, $tool-rounds, $total-calls, %call-counts,
			);
			if %limit.elems {
				$run._emit(LLM::Agent::Event::LimitReached.new(|%limit));
				# The turn that asked for the tools is thrown away whole —
				# see the Pod on why. Its tokens are already out, so the
				# discard has to be said out loud.
				$run._emit(LLM::Agent::Event::TurnDiscarded.new(
					reason => 'limit', :$round,
				));
				my $notice = Message.new(
					role => 'system', content => LIMIT-MESSAGE,
				);
				@conversation.push: $notice;
				@ids.push: self!record($notice);
				$tools-enabled = False;
				next;
			}
		}

		my $assistant = Message.new(
			role       => 'assistant',
			content    => ($resp.msg // '').Str,
			|(@tool-calls.elems ?? (tool-calls => @tool-calls) !! ()),
		);
		@conversation.push: $assistant;
		@ids.push: self!record($assistant, extra => assistant-extras($resp));
		$final = $assistant.content;

		$run._emit(LLM::Agent::Event::AssistantMessage.new(
			message   => $assistant,
			reasoning => $resp.reasoning-text,
			:$round,
		));
		# The identity half of the same fact, carrying the envelope id that
		# joins this turn to the tool operations it is about to ask for.
		# Undefined — and absent — on a sessionless run.
		$run._emit(LLM::Agent::Event::TurnCommitted.new(
			message-id => @ids.tail, :$round,
		));

		return finish-spec(
			LLM::Agent::Event::RunCompleted.new(
				final         => $final,
				rounds        => $round,
				message-count => @conversation.elems,
			),
			final => $final, messages => @conversation.List,
		) unless @tool-calls.elems;

		# One operation per call, all proposed, none dispatched: the model
		# has asked for all of them, and that is a different fact from any
		# of them having started.
		my @ops = @tool-calls.map(-> $call {
			$run._emit(LLM::Agent::Event::ToolCall.new(
				id        => call-id($call),
				name      => call-name($call),
				arguments => call-arguments($call),
				:$round,
			));

			LLM::Agent::ToolOperation.new(
				run-id      => $run.id,
				:$round,
				call-id     => call-id($call),
				tool        => call-name($call),
				arguments   => canonical-arguments(call-arguments($call)),
				idempotency => self!idempotency-of(call-name($call)),
			);
		}).List;

		my %tools = self!run-tool-ops(
			$run, @ops, @tool-calls, @conversation, @ids, $round,
			%call-counts,
		);
		return %tools<finish> if %tools<finish>.defined;

		# Counted as each operation settled, not at the bottom of a batch:
		# an abandoned call never reaches the counter (which is what the
		# Pod means by "only executed calls count"), and one whose outcome
		# is unknown does — a deadline-looping identical call must not
		# evade the guard by never coming back.
		$total-calls += %tools<settled>;
		$tool-rounds++;
	}
}

#|( One round trip's worth of preflight, retry and fallback. Returns
    C<< { ok, response } >>, C<< { ok => False, error } >> or
    C<< { cancelled, stage } >> — plus one variant of the second:
    C<< { ok => False, 'context-overflow' => True, error, target } >>,
    when B<every> backend's preflight refused the conversation and the
    caller's remaining move is to make it smaller. )
method !round-trip(
	$run, @conversation, @tools, Int:D $round, @attempts, $context,
	Int:D $context-tokens,
	--> Hash:D
) {
	my Int $attempt = 0;
	# Once per round trip rather than once per backend: the declarations
	# are the same for all of them, and rendering a thirty-tool catalogue
	# to JSON per backend per round is real work for no new information.
	my Int $tool-tokens = tool-token-estimate(@tools);

	my Int $unfit = 0;
	my Int $best-target = 0;

	for @!backends.kv -> Int $backend-index, $backend {
		my Str $model = model-of($backend);

		# BEFORE the retry loop, and before any AttemptStarted. Preflight
		# unfitness is deterministic — the same conversation will not fit
		# the same window a second time, so burning max-retries on it is
		# spending the retry budget on arithmetic. And the attempt framing
		# describes TRANSPORT attempts (a Token belongs to the
		# AttemptStarted that opened it), so a backend that was skipped
		# without a byte going anywhere must not open a token scope.
		my %fit = self!preflight(
			$backend, $model, @conversation, $tool-tokens, $context-tokens,
		);
		unless %fit<ok> {
			$unfit++;
			$best-target = max($best-target, %fit<usable>);

			my %record = attempt-record(
				:$backend-index, :$model, error => %fit<error>,
			);
			# The one attempt record that carries a disposition: there is
			# no AttemptFailed beside it to say what the loop did, so the
			# record says it itself.
			%record<disposition> = 'advance';
			@attempts.push: %record;

			$run._emit(LLM::Agent::Event::Log.new(
				level  => 'info',
				logger => 'llm-agent.loop',
				data   => %(
					message         => 'backend skipped: the request does '
						~ 'not fit its context window',
					'backend-index' => $backend-index,
					model           => $model,
					needed          => %fit<needed>,
					window          => %fit<window>,
				),
			));
			next;
		}

		# Task's semantics: max-retries counts ATTEMPTS on this backend,
		# so the retry budget is one less than that.
		my Int $retries-left = $!max-retries > 0 ?? $!max-retries - 1 !! 0;

		loop {
			return %( cancelled => True, stage => 'streaming' )
				if $run.is-cancelled;

			$attempt++;
			$run._emit(LLM::Agent::Event::AttemptStarted.new(
				:$round, :$attempt, :$backend-index, :$model,
			));

			my $started = now;
			my %stream = self!stream(
				$run, $backend, @conversation, @tools, $round, $attempt,
				$context,
			);
			my $resp = %stream<response>;

			return %( cancelled => True, stage => 'streaming' )
				if $run.is-cancelled;

			if $resp.is-success {
				# The digest and the model are what make the calibration
				# checkable: "812 tokens for 14 messages" is only usable
				# again if the next 14 messages are THESE 14, asked of the
				# same model. Computed once, here, rather than per message
				# inside the counter.
				$!counter.record-usage(
					prompt-tokens     => $resp.prompt-tokens,
					completion-tokens => $resp.completion-tokens,
					message-count     => @conversation.elems,
					prefix-digest     => messages-digest(@conversation),
					backend           => $model,
				);
				my %usage = usage-of($resp);
				# The bill, before the event: a consumer that reacts to
				# AttemptSucceeded by reading the run's spend finds this
				# attempt already in it.
				self!spend-record($run.id, %usage);

				$run._emit(LLM::Agent::Event::AttemptSucceeded.new(
					:$round, :$attempt, :$backend-index,
					model-used    => $resp.model-used,
					finish-reason => $resp.finish-reason,
					usage         => %usage,
					latency-ms    => ((now - $started) * 1000).Int,
				));
				return %( ok => True, response => $resp );
			}

			my Bool $timed-out = ?%stream<timed-out>;
			my Str $error = "[backend $backend-index] " ~ ($timed-out
				?? "no activity for {$!round-trip-timeout}s"
				!! ($resp.err // 'the completion stream failed').Str);
			my Str $error-class  = $timed-out ?? 'timeout' !! $resp.error-class;
			my Int $error-status = $timed-out ?? Int !! $resp.error-status;

			@attempts.push: attempt-record(
				:$backend-index, :$model, :$error,
				# Only when there is something worth keeping: an empty
				# raw-text would make a connection failure look like a
				# model that answered with nothing.
				|($resp.latest.chars ?? (raw-text => $resp.latest) !! ()),
			);

			my Str $disposition = classify-error(:$error-class, :$error-status);

			# The seatbelt under the preflight (see the Pod): a 400 whose
			# text is one of the documented context-length complaints is
			# an ADVANCE, not an abort. A conversation the primary cannot
			# take is very often one the fallback can, and aborting the
			# chain on it throws away the backend that would have worked.
			$disposition = 'advance'
				if $disposition eq 'abort' && $error-status.defined
					&& $error-status == 400 && context-overflow-text($error);

			if $disposition eq 'abort' {
				$run._emit(LLM::Agent::Event::AttemptFailed.new(
					:$round, :$attempt, :$backend-index, :$model,
					:$error, :$error-class, :$error-status,
					disposition => 'abort',
				));
				return %( ok => False, error => $error );
			}

			if $disposition eq 'retry-same' && $retries-left > 0 {
				my Int $retry-n = $!max-retries - $retries-left;
				my Num $backoff = retry-backoff($retry-n);
				$retries-left--;

				$run._emit(LLM::Agent::Event::AttemptFailed.new(
					:$round, :$attempt, :$backend-index, :$model,
					:$error, :$error-class, :$error-status,
					disposition => 'retry-same', :$backoff,
				));

				return %( cancelled => True, stage => 'backoff' )
					unless sleep-with-cancel(
						$backoff, cancelled => { $run.is-cancelled },
					);
				next;
			}

			# Either the bucket said advance, or the retry budget for this
			# backend is spent. `disposition` reports what the loop DOES.
			$run._emit(LLM::Agent::Event::AttemptFailed.new(
				:$round, :$attempt, :$backend-index, :$model,
				:$error, :$error-class, :$error-status,
				disposition => 'advance',
			));
			last;
		}
	}

	# Every backend refused the conversation before anything was sent.
	# That is not "every backend failed" — nothing was tried, nothing was
	# spent, and the caller has one move left that this method does not:
	# compacting to `target`, the largest conversation any of these
	# backends would have taken.
	return %(
		ok                 => False,
		'context-overflow' => True,
		target             => $best-target,
		error              => 'LLM::Agent::Loop: the request does not fit any '
			~ 'backend in the chain — ' ~ @attempts.tail(@!backends.elems)
				.map({ $_<error> }).join('; '),
	) if $unfit == @!backends.elems;

	%(
		ok    => False,
		error => 'every backend failed: '
			~ @attempts.map({ $_<error> }).join('; '),
	);
}

#|( Will this conversation fit C<$backend>? Answered from the
    C<request-budget> profile that describes it, B<before> an attempt is
    opened.

    Returns C<< { ok => True } >> — including for a backend nothing
    describes, because an unknown window is not a small one and refusing
    a request nobody said anything about would be worse than sending it —
    or C<< { ok => False, error, needed, window, usable } >>, where
    C<usable> is the biggest conversation this backend would have taken
    (window less the reserve, the margin, the tool declarations and the
    run context) and is what a forced compaction aims at. )
method !preflight(
	$backend, Str:D $model, @conversation, Int:D $tool-tokens,
	Int:D $context-tokens,
	--> Hash:D
) {
	return %( ok => True ) unless $!request-budget.defined;

	my $profile = $!request-budget.profile-for($model);
	return %( ok => True ) unless $profile.defined;

	my $counter = $profile.counter // $!counter;
	my Int $messages = $counter.count-messages(@conversation);
	my Int $margin   = $profile.input-safety-margin;
	my Int $reserve  = $!request-budget.reserve-for($profile, $backend);
	my Int $window   = $profile.context-window;

	my Int $needed = $messages + $tool-tokens + $context-tokens + $margin;
	return %( ok => True ) if $needed + $reserve <= $window;

	%(
		ok     => False,
		needed => $needed + $reserve,
		window => $window,
		# Never negative: a window smaller than its own reserve has no
		# room for a conversation of any size, and "compact to -300
		# tokens" is not an instruction.
		#
		# The context comes off it for the same reason the tools do: what
		# a forced compaction has to fit under is the room left for the
		# CONVERSATION, and the context goes out with every request
		# whatever the compactor does about the messages.
		usable => max(0, $window - $reserve - $margin - $tool-tokens
			- $context-tokens),
		error  => "preflight: needs ~{$needed + $reserve} (messages "
			~ "$messages + tools $tool-tokens + context $context-tokens "
			~ "+ margin $margin + reserve $reserve), window $window",
	);
}

# One streamed attempt, tapped for Tokens and watched for inactivity.
# Returns { response, timed-out }; the response is always settled.
method !stream(
	$run, $backend, @conversation, @tools, Int:D $round, Int:D $attempt,
	$context,
	--> Hash:D
) {
	# The tap below emits from the Supply's thread, and the catch-up emit
	# after it runs on this one. Both are inside this section, which ends
	# only when the method does — including when it dies.
	my Bool $ticket = $run._work-begin;
	LEAVE { $run._work-done if $ticket; }

	# THE ONE PLACE the run context becomes part of a request. Everything
	# else in this class — the seed check, the session appends, the
	# compactor, the parallel id array, the result Map — works from
	# @conversation, which never contains it.
	my @wire = wire-view(@conversation, $context);

	my $resp = @tools.elems
		?? $backend.chat-completion-stream(@wire, tools => @tools)
		!! $backend.chat-completion-stream(@wire);

	self!set-active($run.id, $backend, $resp);

	my Int $emitted = 0;
	my $settled = Promise.new;
	my $vow = $settled.vow;
	my &wake = { $vow.keep(True) if $settled.status ~~ Planned };

	my $tap = $resp.supply.tap(
		-> $chunk {
			my Str $text = ($chunk // '').Str;

			# Catch-up. This tap is installed after the Response's own
			# (which BUILD wires to accumulate `.latest`), so a fragment
			# emitted in the moment between the backend handing the
			# Response back and this tap existing reached `.latest` and
			# nothing else. On the first fragment we DO see, `.latest` is
			# exactly (lost prefix ~ this fragment) — the Response's tap
			# ran first — so the prefix is recoverable, once, in order.
			# Without this, "concatenating the Tokens of a committed
			# attempt reproduces the assistant's text" would be a promise
			# the Event Pod makes and a race quietly breaks.
			if $emitted == 0 {
				my Str $seen = $resp.latest;
				if $seen.chars > $text.chars {
					my Str $prefix =
						$seen.substr(0, $seen.chars - $text.chars);
					$run._emit(LLM::Agent::Event::Token.new(
						text => $prefix, :$round, :$attempt,
					));
					$emitted += $prefix.chars;
				}
			}

			if $text.chars {
				$run._emit(LLM::Agent::Event::Token.new(
					text => $text, :$round, :$attempt,
				));
				$emitted += $text.chars;
			}
		},
		done => &wake,
		quit => -> $ { wake() },
	);

	# Wake often enough to notice a cancel or a stall promptly, and never
	# so often that a two-minute timeout is a busy loop.
	my Num $poll = max(0.005e0, min(0.05e0, ($!round-trip-timeout / 20).Num));
	my Bool $timed-out = False;

	until $resp.is-done {
		await Promise.anyof($settled, $run.cancellation, Promise.in($poll));
		last if $resp.is-done;

		if $run.is-cancelled {
			try $backend.cancel($resp);
			last;
		}

		if (now - $resp.last-activity-at) > $!round-trip-timeout {
			$timed-out = True;
			try $backend.cancel($resp);
			last;
		}
	}

	$tap.close;
	self!clear-active($run.id);

	# The whole stream can land before the tap exists, in which case the
	# catch-up above never ran at all.
	if $emitted == 0 && $resp.latest.chars {
		$run._emit(LLM::Agent::Event::Token.new(
			text => $resp.latest, :$round, :$attempt,
		));
	}

	%( response => $resp, 'timed-out' => $timed-out );
}

#|( The tool section, B<one operation at a time>: dispatch, wait, settle,
    then the next.

    Returns C<< { settled } >> — how many operations reached an outcome,
    which is what the call counters count — plus a C<finish> spec when the
    run ends here rather than going round again.

    Everything that can end a run mid-batch is checked at the B<boundary
    between operations>, never inside one: an operation that has been
    dispatched is always allowed to settle first, because a cancel (or a
    cap) is a reason to stop starting things, not a reason to stop knowing
    what the last one did. )
method !run-tool-ops(
	$run, @ops, @tool-calls, @conversation, @ids, Int:D $round, %call-counts,
	--> Hash:D
) {
	my Int $settled = 0;

	for @ops.kv -> Int $index, $op {
		# The run caps, at the boundary between two operations —
		# `!caps-tripped` answers with an empty Hash when there is no
		# budget to answer from. The check is HERE, and not inside
		# `!execute-op`, precisely so a tripped cap can never abandon an
		# operation that is already running: what is behind this one has
		# not been dispatched, and can be settled as known not to have run.
		my %caps = self!caps-tripped;
		if %caps.elems {
			self!abandon-ops(
				$run, @ops[$index ..^ @ops.elems], @conversation, @ids,
				$round, 'budget-exhausted',
			);
			self!sync-grants-shielded($run);
			return %(
				settled => $settled,
				finish  => failure-spec(
					caps-error(%caps), (), @conversation, $round,
					reason => 'budget-exhausted',
				),
			);
		}

		if $run.is-cancelled {
			# Nothing here has been dispatched, so this is the one case the
			# loop can be certain about: these calls did not run.
			self!abandon-ops(
				$run, @ops[$index ..^ @ops.elems], @conversation, @ids,
				$round, 'cancelled',
			);
			self!sync-grants-shielded($run);
			return %(
				settled => $settled,
				finish  => cancel-spec('tools', $round, @conversation),
			);
		}

		my %op-outcome = self!dispatch-op(
			$run, $op, @tool-calls[$index], @conversation, @ids, $round,
		);

		# Completed, failed and outcome-unknown all count; abandoned never
		# gets here. An unknown outcome counting is deliberate: a call that
		# times out identically for ever must still trip the guard.
		%call-counts{$op.signature}++;
		$settled++;

		# Belt and braces for the grant hook. Even with nothing wired, a
		# human's "always" answer is on disk before the NEXT call is
		# dispatched — per-operation dispatch bounds the staleness to one
		# tool's runtime. Shielded: a session that cannot take the grants
		# must not leave the rest of this batch unanswered in the
		# transcript.
		self!sync-grants-shielded($run);

		if %op-outcome<cancelled> {
			self!abandon-ops(
				$run, @ops[$index + 1 ..^ @ops.elems], @conversation, @ids,
				$round, 'cancelled',
			);
			return %(
				settled => $settled,
				finish  => cancel-spec('tools', $round, @conversation),
			);
		}
	}

	%( settled => $settled );
}

#|( One operation: the C<tool-dispatched> envelope, C<ToolStarted>, the
    provider, and whichever settle path the answer (or the lack of one)
    calls for. Returns C<< { cancelled } >>, True only when the run is
    ending on this operation.

    The write order on every settle path is the same, and it is
    load-bearing: B<the tool message first, the C<tool-settled> envelope
    second>. A crash between the two leaves a dispatched-unsettled
    operation whose call already has a C<tool> message, which is the
    signature of "it completed and the settle never landed" — and the
    only thing that distinguishes it from "it was still running". )
method !dispatch-op(
	$run, $op, $call, @conversation, @ids, Int:D $round,
	--> Hash:D
) {
	# The durable record comes first, and its envelope id becomes the
	# operation's own: with a session, an operation IS its dispatch line.
	my Str $op-id = self!record-dispatch($op);
	$op.dispatch(:$op-id);

	# Visible to the shims for exactly as long as it is running: an ask
	# arriving now is about this call, and so is a progress notification.
	self!set-in-flight($run.id, $op);
	LEAVE { self!clear-in-flight($run.id, $op) }

	$run._emit(LLM::Agent::Event::ToolStarted.new(
		id => $op.call-id, name => $op.tool, :$round,
	));

	my %answer = self!execute-op($run, $op, $call);

	if %answer<result>:exists {
		my %result = %answer<result>;
		my Bool $is-error = ?%result<is_error>;
		# THE ARTIFACT SEAM. Every byte of tool output the conversation,
		# the transcript and the ToolResult event will ever see passes
		# through here, before the message is built — which is what makes
		# an oversized result reach all three as the SAME excerpt, with
		# the full bytes spilled to a file beside the transcript.
		my %observed = self!observe-result(
			$run, $op, (%result<content> // '').Str,
		);
		my Str $content = %observed<content>;
		my %artifact = %observed<artifact>;

		my $message = Message.new(
			role => 'tool', :$content, tool-call-id => $op.call-id,
		);
		@conversation.push: $message;
		@ids.push: self!record(
			$message, extra => ($is-error ?? %( 'is-error' => True ) !! %()),
		);

		$op.settle(
			outcome       => ($is-error ?? 'failed' !! 'completed'),
			# Over the excerpt, deliberately: this digest describes the
			# tool MESSAGE, which is what a resume replays and what the
			# next request carries. The full result's own digest is on the
			# artifact record beside it.
			result-digest => data-digest($content),
			:%artifact,
			|($is-error ?? (error-text => error-summary($content)) !! ()),
		);
		self!record-settle($op);

		$run._emit(LLM::Agent::Event::ToolResult.new(
			id => $op.call-id, name => $op.tool, :$content, :$is-error, :$round,
			:%artifact,
		));

		return %( cancelled => False );
	}

	# No answer, and none coming: the call is detached and still running
	# somewhere. What it did is unknown — never failed. See the Pod.
	my Bool $deadline = ?%answer<deadline>;
	my Str $reason = $deadline ?? 'deadline' !! 'cancelled';
	my Str $content = $deadline
		?? DEADLINE-UNKNOWN-MESSAGE
		!! CANCELLED-UNKNOWN-MESSAGE;

	my $message = Message.new(
		role => 'tool', :$content, tool-call-id => $op.call-id,
	);
	@conversation.push: $message;
	@ids.push: self!record($message, extra => %(
		'outcome-unknown' => True,
		# `cancelled` as well, on that path only: it is the key a transcript
		# reader has looked for since 0.1.0, and dropping it would break
		# every consumer that tells a cancelled tail from a normal one.
		|($deadline ?? () !! (cancelled => True)),
	));

	$op.settle(outcome => 'outcome-unknown', :$reason);
	self!record-settle($op);

	$run._emit(LLM::Agent::Event::ToolAbandoned.new(
		id => $op.call-id, name => $op.tool, :$reason, dispatched => True,
		:$round,
	));

	%( cancelled => !$deadline );
}

#|( Hand one call to the provider and wait for it, in its own C<start> so
    that a cancel does not have to wait for it and a deadline can give up
    on it. Returns C<< { result } >> with the one normalised result,
    C<< { deadline => True } >> or C<< { cancelled => True } >>.

    A batch of one through an unchanged provider contract: C<Registry>'s
    per-server grouping degenerates to singletons, which is the price of
    real per-operation dispatch and settle boundaries — and, incidentally,
    makes side effects happen in the order the model asked for them. )
method !execute-op($run, $op, $call --> Hash:D) {
	# The call outlives this method on both give-up paths, so its work
	# section is closed by the call itself rather than by a LEAVE here:
	# `.then` fires exactly once, whichever way it ends and whether or not
	# anybody is still waiting — which is what keeps `drained` honest.
	my @batch-of-one = ($call,);
	my Bool $ticket = $run._work-begin;
	# `.list.eager`, and it is not decoration: a provider that hands back a
	# LAZY list has not done the work yet, and reifying it where the old
	# code did — on the driver's thread, after the wait — would run the
	# tool at the one moment nothing is watching the clock. A deadline
	# would never fire and a cancel would wait for the very call it was
	# cancelling. Forcing it here keeps the work inside the section this
	# method can give up on.
	my $batch = start { $!provider.execute-tool-calls(@batch-of-one).list.eager };
	$batch.then({ try $run._work-done }) if $ticket;

	# The adaptive poll of `!stream`, for the same reason: a fixed
	# `Promise.in($!tool-deadline)` cannot pause while a human is being
	# asked, and the deadline has to. Frequent enough to notice a
	# sub-second deadline, never so frequent that a minute-long tool is a
	# busy loop.
	my Num $poll = $!tool-deadline.defined
		?? max(0.002e0, min(0.05e0, ($!tool-deadline / 20).Num))
		!! 0.05e0;

	my Bool $expired = False;
	until $batch.status !~~ Planned {
		await Promise.anyof($batch, $run.cancellation, Promise.in($poll));
		# The order matters: an operation that answered in the same
		# instant it was cancelled ANSWERED, and recording it as unknown
		# would throw away a fact we have.
		last if $batch.status !~~ Planned;
		last if $run.is-cancelled;

		if $!tool-deadline.defined && $op.working-seconds > $!tool-deadline {
			$expired = True;
			last;
		}
	}

	if $batch.status ~~ Planned {
		# Detached. The bridge has no cancellation, so it will finish on
		# its own; we stop waiting and consume the outcome so a failure
		# inside it is not reported as an unhandled broken Promise minutes
		# later, in a run that has already ended.
		$batch.then({ try { $_.result }; True });
		return $expired ?? %( deadline => True ) !! %( cancelled => True );
	}

	my @answers;
	my $threw;
	{
		CATCH { default { $threw = $_ } }
		@answers = $batch.result.list;
	}

	# ToolLoop's belt and braces. A well-behaved provider never throws;
	# one that does becomes an is_error result rather than an exception
	# that takes the run down.
	return %( result => %(
		role         => 'tool',
		tool_call_id => $op.call-id,
		content      => 'The tool provider failed: '
			~ ($threw.message.lines.head // $threw.^name),
		is_error     => True,
	) ) if $threw.defined;

	my @mismatches;
	my @results = normalize-results(@batch-of-one, @answers, @mismatches);

	# Said out loud rather than obeyed. A provider filing a result under an
	# id the model never used is a bug in that provider, and the loop has
	# just corrected it — but silently correcting it is how a broken bridge
	# stays undiagnosed for a month.
	for @mismatches -> %mismatch {
		$run._emit(LLM::Agent::Event::Log.new(
			level  => 'warning',
			logger => 'llm-agent.loop',
			data   => %(
				message => 'the tool provider answered with a tool_call_id '
					~ 'the model never asked for; the call id was used '
					~ 'instead, because a result filed under anything else '
					~ 'makes the next request invalid',
				tool          => %mismatch<name>,
				'call-index'  => %mismatch<index>,
				'call-id'     => %mismatch<expected>,
				'provider-id' => %mismatch<provided>,
			),
		));
	}

	%( result => @results[0] );
}

#|( Settle every operation in C<@ops> as C<abandoned> — never dispatched,
    known not to have run — and answer each of their calls with a
    synthetic C<tool> message saying exactly that.

    The message is B<not> an error and B<not> a result: it is what keeps
    the transcript resumable, because an assistant turn carrying
    C<tool_calls> that nothing answers is a conversation every
    OpenAI-compatible provider rejects with a 400. The C<ToolAbandoned>
    event is the machine-readable half; C<dispatched => False> is the part
    a consumer cares about.

    No C<tool-dispatched> / C<tool-settled> envelopes are written: there
    is no operation to record. Nothing happened. )
method !abandon-ops(
	$run, @ops, @conversation, @ids, Int:D $round, Str:D $reason,
	--> Nil
) {
	for @ops -> $op {
		$op.abandon(:$reason);

		my $message = Message.new(
			role         => 'tool',
			content      => ($reason eq 'budget-exhausted'
				?? NO-BUDGET-MESSAGE
				!! NEVER-RAN-MESSAGE),
			tool-call-id => $op.call-id,
		);
		@conversation.push: $message;
		@ids.push: self!record($message, extra => %( abandoned => True ));

		$run._emit(LLM::Agent::Event::ToolAbandoned.new(
			id => $op.call-id, name => $op.tool, :$reason,
			dispatched => False, :$round,
		));
	}
	Nil;
}

# === The tool-operation seams ===

#|( Every byte of tool output that reaches the conversation, the
    transcript or a C<ToolResult> passes through here, on the settle
    path, B<before the C<tool> message is built>. Returns
    C<< { content, artifact } >>: what everything downstream will carry,
    and the metadata of the file the rest of it went to (empty when there
    is no rest of it).

    That single call site is the artifact invariant. An oversized result
    is excerpted B<once>, and the excerpt is what the conversation holds,
    what the session records, what the C<ToolResult> event carries and
    what the settle envelope's C<result-digest> is over. The full bytes
    are in the artifact file and nowhere else — so a resumed run replays
    byte for byte B<without the artifact existing at all>. See
    L<LLM::Agent::Artifacts>.

    Three things have to be true in order, and are: the size is measured,
    the file is written and closed, and only then is the marker — which
    names that file — built into the excerpt. A write that fails is
    B<shielded>: the model still gets an excerpt, it says the full result
    was not stored, the operation still settles, and the failure comes
    out as a C<Log> event. A tool call is not a failure because a
    scratch file could not be opened. )
method !observe-result($run, $op, Str:D $content --> Hash:D) {
	my Int $limit = $!request-budget.defined
		?? $!request-budget.max-observation-size
		!! Int;
	return %( content => $content, artifact => %() )
		unless $limit.defined && $content.chars > $limit;

	my Int $elided = elided-chars($content.chars, $limit);

	my %stored;
	my $threw;
	if $!artifact-store.defined {
		CATCH { default { $threw = $_ } }
		%stored = $!artifact-store.store($op.op-id, $content);
	}

	if $threw.defined {
		$run._emit(LLM::Agent::Event::Log.new(
			level  => 'warning',
			logger => 'llm-agent.loop',
			data   => %(
				message   => 'the full tool result could not be written to '
					~ 'an artifact file; the model was given the excerpt '
					~ 'anyway, and the rest of the output is gone',
				'op-id'   => $op.op-id,
				tool      => $op.tool,
				error     => ($threw.message.lines.head // $threw.^name),
			),
		));
	}

	# The byte count and the digest of the WHOLE result: free from the
	# store when it wrote the file, and worth computing when it did not —
	# a marker that says how much is missing and what its digest is stays
	# useful even when the bytes themselves are gone.
	my Str $marker = %stored.elems
		?? stored-marker($elided, %stored)
		!! unstored-marker(
			$elided, $content.encode('utf-8').bytes, content-digest($content),
			$threw.defined
				?? 'could not be stored'
				!! 'was not stored (this run has nowhere to put it)',
		);

	%(
		content  => excerpt($content, $limit, :$marker),
		artifact => (%stored.elems
			?? %( |%stored, 'elided-chars' => $elided )
			!! %()),
	);
}

#|( The run caps — cost, total tokens, wall clock — as they stand, or an
    empty Hash when nothing has tripped.

    Called at the top of every round and at the boundary between tool
    operations, so that a tripped cap ends the run cleanly at a point
    where B<nothing is in flight>: an operation that has been dispatched
    is always allowed to settle first, because a cap is a reason to stop
    starting things and never a reason to stop knowing what the last one
    did. The shape is C<< { cap, spent, max } >>; empty when there is no
    budget, or none of its caps is set. )
method !caps-tripped(--> Hash:D) {
	return %() unless $!request-budget.defined && $!request-budget.has-caps;
	$!request-budget.cap-tripped(self!spent);
}

# === The bill ===

# Start this run's accumulators. One run at a time, but tagged anyway:
# a straggler from the previous run must not be added to this one's.
method !spend-begin(Str:D $run-id --> Nil) {
	$!spend-lock.protect: {
		%!spend =
			'run-id'        => $run-id,
			'started-at'    => now,
			cost            => 0e0,
			'reported-cost' => False,
			'total-tokens'  => 0,
		;
	};
	Nil;
}

#|( Add one successful attempt's usage to the bill. C<cost> is only ever
    added when a provider reported one — a run whose backends price
    nothing spends nothing, which is honest, rather than counting an
    unreported cost as zero and calling that a measurement. )
method !spend-record(Str:D $run-id, %usage --> Nil) {
	$!spend-lock.protect: {
		if (%!spend<run-id> // '') eq $run-id {
			if %usage<cost>.defined {
				%!spend<cost> += %usage<cost>.Num;
				%!spend<reported-cost> = True;
			}

			# The provider's own total when it gave one, and the two halves
			# added up when it did not: an attempt that reported only
			# prompt and completion tokens still counts against a token cap.
			my $total = %usage<total-tokens>;
			$total = (%usage<prompt-tokens> // 0) + (%usage<completion-tokens> // 0)
				unless $total.defined;
			%!spend<total-tokens> += $total.Int if $total > 0;
		}
	};
	Nil;
}

#|( What this run has spent so far: C<< { cost, total-tokens,
    wall-clock } >>, with C<cost> present only when something reported
    one. The Map a finished run hands back carries exactly this. )
method !spent(--> Hash:D) {
	$!spend-lock.protect: {
		my %spent =
			'total-tokens' => (%!spend<total-tokens> // 0),
			'wall-clock'   => (%!spend<started-at>.defined
				?? ((now - %!spend<started-at>) * 1000).round / 1000
				!! 0),
		;
		%spent<cost> = %!spend<cost> if %!spend<reported-cost>;
		%spent;
	};
}

#|( The idempotency class of C<$tool>, from C<@!idempotency-rules>: first
    match wins, C<unknown> for anything unmatched (which is every tool
    until an application says otherwise — nothing in MCP publishes this). )
method !idempotency-of(Str:D $tool --> Str:D) {
	with @!idempotency-rules.first({ match-tool-pattern($_<tool>, $tool) }) {
		return .<idempotency>.Str;
	}
	'unknown';
}

# The dispatch envelope, and with it the operation's durable id. An
# undefined Str for a sessionless run — which leaves the operation with
# the uuid it was born with.
method !record-dispatch($op --> Str) {
	return Str unless $!session.defined;

	$!session.append-tool-dispatched(
		call-id          => $op.call-id,
		tool             => $op.tool,
		arguments        => $op.arguments,
		arguments-digest => $op.arguments-digest,
		idempotency      => $op.idempotency,
		run-id           => $op.run-id,
		round            => $op.round,
	);
}

# The settle envelope. Written AFTER the tool message on every path — see
# `!dispatch-op` for why that ordering is the whole recovery story.
method !record-settle($op --> Str) {
	return Str unless $!session.defined;

	my %named = op-id => $op.op-id, outcome => $op.outcome;
	%named<reason>        = $op.reason if $op.reason.defined;
	%named<duration>      = $op.duration if $op.duration.defined;
	%named<result-digest> = $op.result-digest if $op.result-digest.defined;
	%named<error>         = $op.error-text if $op.error-text.defined;
	%named<artifact>      = $op.artifact if $op.artifact.elems;

	$!session.append-tool-settled(|%named);
}

# Remember the operation a shim may be asked about, under its run's name.
method !set-in-flight(Str:D $run-id, $op --> Nil) {
	$!op-lock.protect: { %!in-flight = run-id => $run-id, op => $op };
	Nil;
}

# Drop it, but only if this run still owns it AND it is still this
# operation: same reasoning as `!clear-active`, one level down.
method !clear-in-flight(Str:D $run-id, $op --> Nil) {
	$!op-lock.protect: {
		%!in-flight = ()
			if (%!in-flight<run-id> // '') eq $run-id
				&& (%!in-flight<op> // Nil) === $op;
	};
	Nil;
}

# The operation this run has in flight, or an undefined one.
method !in-flight-op(Str:D $run-id --> LLM::Agent::ToolOperation) {
	$!op-lock.protect: {
		(%!in-flight<run-id> // '') eq $run-id
			?? (%!in-flight<op> // LLM::Agent::ToolOperation)
			!! LLM::Agent::ToolOperation;
	};
}

# === Limits ===

method !limit-reason(
	@tool-calls, Int:D $tool-rounds, Int:D $total-calls, %call-counts,
	--> Hash:D
) {
	return %(
		limit => 'tool-rounds', count => $tool-rounds, max => $!max-tool-rounds,
	) if $tool-rounds >= $!max-tool-rounds;

	return %(
		limit => 'tool-calls',
		count => $total-calls + @tool-calls.elems,
		max   => $!max-tool-calls,
	) if $total-calls + @tool-calls.elems > $!max-tool-calls;

	# The batch counts against itself as well as against history. A model
	# that asks for the same call three times in ONE turn has looped just
	# as surely as one that asks for it once per turn for three turns, and
	# checking only what previous rounds executed would let the whole
	# batch through — and then execute it.
	my %batch-counts;
	for @tool-calls -> $call {
		my $signature = tool-call-signature($call);
		my Int $count = (%call-counts{$signature} // 0) + ++%batch-counts{$signature};
		return %(
			limit => 'identical-calls',
			count => $count,
			max   => $!max-identical-calls,
		) if $count > $!max-identical-calls;
	}

	%();
}

# === Compaction ===

method !budgeted(--> Bool:D) {
	$!compactor.defined || $!context-budget.defined || $!request-budget.defined;
}

#|( Compact C<@conversation> in place if it has outgrown the trigger.

    Returns an empty Hash when the round may go ahead, and a B<finish
    spec> — the C<context-exhausted> C<RunFailed> — when the compactor
    reports that it cannot make the next request fit. The conversation is
    still updated in that case: whatever the compaction managed is real,
    it has already been written to the session, and the transcript this
    run leaves behind has to describe it. )
method !maybe-compact(
	$run, @conversation, @ids, Int:D $round, Int:D $context-tokens,
	--> Hash:D
) {
	return %() unless $!compactor.defined;

	my Int $tokens = $!counter.count-messages(@conversation);
	# The context counts towards the TRIGGER, because it is real weight on
	# every request — but it is not passed on as a target. The compactor
	# works on the conversation, `!unchanged` reports `exhausted` against
	# the target it was given, and handing it a reduced one would turn a
	# compaction that had nothing to drop into a `context-exhausted`
	# terminal. The preflight is where a conversation that genuinely will
	# not fit is caught, and its `usable` already has the context taken
	# off it.
	return %() unless $tokens + $context-tokens > $!compactor.trigger;

	self!run-compaction($run, @conversation, @ids, $round, $tokens);
}

#|( The compaction a failed B<preflight> forces, aimed at a number the
    compactor does not own: C<$target>, the largest conversation any
    backend in the chain would have taken.

    Returns an empty Hash when the round should be tried again — the
    conversation is smaller now — and a B<finish spec> when it should
    not. There are two of those, and both are C<context-exhausted>: no
    compactor at all (the honest end of a run whose conversation does not
    fit anything), and a compaction that ran and still could not get
    under the target.

    This is what stops C<context-budget> being decorative. Before it, a
    loop with a budget and no compactor sent the doomed request anyway
    and let the provider explain. )
method !force-compaction(
	$run, @conversation, @ids, Int:D $round, Int:D $target,
	--> Hash:D
) {
	return failure-spec(
		'LLM::Agent::Loop: the request does not fit any backend in the '
			~ 'chain and there is no compactor to make it smaller — the '
			~ 'conversation needs to be under ' ~ $target ~ ' tokens for the '
			~ 'roomiest backend configured',
		(), @conversation, $round, reason => 'context-exhausted',
	) unless $!compactor.defined;

	my Int $tokens = $!counter.count-messages(@conversation);
	self!run-compaction($run, @conversation, @ids, $round, $tokens, $target);
}

# One compaction, framed and applied: the events, the session line, the
# parallel id array, and the swap. Shared by the trigger-driven check at
# the top of a round and by the preflight-driven one between two round
# trips, so the two can never disagree about what a compaction does.
method !run-compaction(
	$run, @conversation, @ids, Int:D $round, Int:D $tokens, Int $target?,
	--> Hash:D
) {
	$run._emit(LLM::Agent::Event::CompactionStarted.new(
		tokens-before => $tokens,
		budget        => $!context-budget,
		message-count => @conversation.elems,
		:$round,
	));

	my %result = $!compactor.compact(
		@conversation, cancelled => { $run.is-cancelled },
		|($target.defined ?? (:$target) !! ()),
	);

	if %result<dropped> == 0 {
		# Nothing between the sticky prefix and the recent window. Said
		# out loud rather than silently, because it means the budget is
		# too small for keep-recent and somebody should know.
		$run._emit(LLM::Agent::Event::CompactionDone.new(
			tokens-before => %result<tokens-before>,
			tokens-after  => %result<tokens-after>,
			dropped       => 0,
			fallback      => ?%result<fallback>,
			:$round,
		));
		return exhausted-spec(%result, @conversation, $round)
			if %result<exhausted>;
		return %();
	}

	my Int $cut = %result<cut-index>;

	# The ids only exist when there is a session to have written them, and
	# so does everything that checks them. A sessionless run's @ids holds
	# an undefined entry per message (that is what `!record` returns with
	# nothing to append to) and NOTHING reads it — so rebuilding it here
	# would be arithmetic over placeholders, and the equivalence check
	# below would fail a run that has done nothing wrong.
	with $!session {
		# NB the unquoted key: a QUOTED fat-arrow key in an argument list
		# is a positional Pair, not a named argument, and the call fails
		# with "too many positionals" several frames from here.
		my Str $summary-id = .append-compaction(
			summary             => %result<summary>,
			replaces-through-id => @ids[$cut],
			tokens-before       => %result<tokens-before>,
			tokens-after        => %result<tokens-after>,
			fallback            => ?%result<fallback>,
		);

		# The same transformation the compactor applied, over the parallel
		# id array. If these two ever disagree, a resumed session would
		# replay a different conversation than the one the run was working
		# with — so they are checked rather than trusted.
		my @new-ids = (0 .. $cut)
			.grep({ @conversation[$_].is-sticky })
			.map({ @ids[$_] });
		@new-ids.push: $summary-id;
		@new-ids.append: @ids[$cut + 1 .. *-1] if $cut + 1 < @ids.elems;

		die 'LLM::Agent::Loop: the compaction produced '
			~ %result<messages>.elems ~ ' messages but ' ~ @new-ids.elems
			~ ' ids — LLM::Agent::Compactor and LLM::Agent::Loop disagree '
			~ 'about what a compaction keeps, and a resumed session would '
			~ 'replay a different conversation'
			unless @new-ids.elems == %result<messages>.elems;

		@ids.splice(0, @ids.elems);
		@ids.append: @new-ids;
	}

	@conversation.splice(0, @conversation.elems);
	@conversation.append: %result<messages>.list;

	$run._emit(LLM::Agent::Event::CompactionDone.new(
		tokens-before => %result<tokens-before>,
		tokens-after  => %result<tokens-after>,
		dropped       => %result<dropped>,
		summary       => %result<summary>,
		fallback      => ?%result<fallback>,
		:$round,
	));

	%result<exhausted>
		?? exhausted-spec(%result, @conversation, $round)
		!! %();
}

#|( The finish spec of a run that has nowhere left to go: the compactor
    did everything it could and the conversation still will not fit the
    window. A terminal, not an exception — the caller gets a kept result
    with a C<reason> it can branch on, and a transcript that ends on the
    compaction rather than on half a request. )
my sub exhausted-spec(%result, @conversation, Int:D $round --> Hash:D) {
	failure-spec(
		'LLM::Agent::Loop: the conversation does not fit the context '
			~ 'budget even after compaction — ' ~ %result<tokens-after>
			~ ' tokens after compacting ' ~ %result<tokens-before>
			~ ', and everything that could be dropped has been. The sticky '
			~ 'prefix plus the recent window is bigger than the window: '
			~ 'either a single message is enormous, or keep-recent is too '
			~ 'large for this budget',
		(), @conversation, $round, reason => 'context-exhausted',
	);
}

# === Session ===

# The ids of @conversation, appending whatever the session does not have.
method !seed-session(@conversation --> Array) {
	my @ids;
	return @ids unless $!session.defined;

	my @known = $!session.messages.list;
	my @known-ids = $!session.message-ids.list;

	die 'LLM::Agent::Loop: the session already holds ' ~ @known.elems
		~ ' messages but this run was given ' ~ @conversation.elems
		~ ' — a session is a transcript, so a run has to extend it rather '
		~ 'than rewrite it. Start from $session.messages'
		if @conversation.elems < @known.elems;

	# Compared by DIGEST, not by prose. Role and content are the two things
	# a rewritten history is most likely to keep: an assistant turn that
	# has grown a tool call, a system prompt that has quietly become
	# sticky, a tool message answering a different call — all of them
	# survive the session round trip, all of them change what the next
	# request means, and all of them read identically.
	for @known.kv -> Int $index, $known {
		my $mine = @conversation[$index];
		die "LLM::Agent::Loop: message $index of this run is not the one "
			~ "the session recorded there (this run has a '" ~ $mine.role
			~ "', the transcript a '" ~ $known.role ~ "') — a run extends "
			~ "its session's transcript, it does not rewrite it. Start from "
			~ '$session.messages'
			unless message-digest($mine) eq message-digest($known);
		@ids.push: @known-ids[$index];
	}

	for @conversation[@known.elems .. *-1] -> $message {
		@ids.push: $!session.append-message($message);
	}

	@ids;
}

method !record($message, :%extra --> Str) {
	$!session.defined
		?? $!session.append-message($message, :%extra)
		!! Str;
}

#|( What the rendered run context weighs, once per run.

    Counted as B<text> rather than by handing the two messages to
    C<count-messages>, and that is the whole trick: the counter is shared
    with the compactor and calibrated against the bare conversation, so an
    array with two extra messages in it would be a different conversation
    as far as it is concerned — L<LLM::Agent::TokenCount>'s C<Usage>
    would see a prefix it does not recognise and throw its calibration
    away, every round.

    Shielded, because a counter is somebody else's code on a path where
    the answer is an optimisation: a counter that dies here would take
    down a run that could have gone out. Nothing to count is zero. )
method !context-tokens($context --> Int:D) {
	return 0 without $context;

	my @texts = ($context.head-message, $context.tail-message)
		.grep({ $_.defined })
		.map({ ($_.content // '').Str })
		.grep({ .chars });
	return 0 unless @texts.elems;

	my Int $tokens = 0;
	{
		CATCH { default { $tokens = 0 } }
		$tokens = [+] @texts.map({ $!counter.count-text($_) });
	}
	max(0, $tokens);
}

#|( Write the run context to the session, on a path that must not fail
    because of it.

    An audit record is not worth a run: a session that cannot take the
    line (an older stand-in with no C<append-run-context>, a disk that
    filled up) becomes a C<Log> event and nothing else. Same posture as
    C<!sync-grants-shielded>. Called after C<!seed-session>, so a run the
    seed check refuses leaves no context line behind either. )
method !record-context-shielded($run, $context --> Nil) {
	return unless $!session.defined && $context.defined;

	my $threw;
	{
		CATCH { default { $threw = $_ } }
		$!session.append-run-context(
			run-id   => $run.id,
			digest   => $context.digest,
			facts    => $context.facts,
			sections => $context.sections,
		);
	}

	$run._emit(LLM::Agent::Event::Log.new(
		level  => 'error',
		logger => 'llm-agent.loop',
		data   => 'the run context could not be written to the session: '
			~ ($threw.message.lines.head // $threw.^name),
	)) if $threw.defined && $run.defined;

	Nil;
}

# === Grants ===

# The digest of the grants as they stand, or an undefined Str when there
# are none to be had.
method !grant-digest(--> Str) {
	my $snapshot = self!grant-snapshot;
	$snapshot.defined ?? data-digest($snapshot.List) !! Str;
}

#|( Write the grant snapshot to the session if it has changed since the
    last time this run wrote one.

    B<Content>, not count: a policy that narrows a grant, replaces one
    with a tighter rule, or swaps two of them leaves the count exactly
    where it was, and a run that only noticed new grants would resume
    tomorrow with permissions the human revoked today. The digest is over
    the canonical rendering of the whole snapshot, so any change at all is
    a change.

    The digest is only advanced once the line is on disk. A write that
    fails leaves the loop believing it still has grants to write, which is
    what makes the next call — the next operation to settle, or the way
    out of the run — try again. )
method !sync-grants(--> Nil) {
	$!grants-lock.protect: {
		my $snapshot = self!grant-snapshot;
		if $snapshot.defined {
			my Str $digest = data-digest($snapshot.List);
			unless $!grants-digest eqv $digest {
				.append-grants($snapshot.List) with $!session;
				# After the write, never before it: see the Pod above.
				$!grants-digest = $digest;
			}
		}
	};
	Nil;
}

#|( C<!sync-grants> on a path that must not fail because of it: the
    asker's thread (where a die would surface as the tool call refusing
    rather than as a session problem) and the two exits that have already
    decided what the run's terminal is. The failure becomes a Log event —
    the one place it can still be seen — and the digest is left alone, so
    the next sync tries again on a path where a failure can be reported
    properly. )
method !sync-grants-shielded($run --> Nil) {
	my $threw;
	{
		CATCH { default { $threw = $_ } }
		self!sync-grants;
	}

	$run._emit(LLM::Agent::Event::Log.new(
		level  => 'error',
		logger => 'llm-agent.loop',
		data   => 'the grant snapshot could not be written to the session: '
			~ ($threw.message.lines.head // $threw.^name),
	)) if $threw.defined && $run.defined;

	Nil;
}

# The provider's grants, or an undefined Array when it has none to give
# (no provider, no `grants` method, or one that threw — a policy that
# cannot report its grants must not take the run down).
#
# NB the scalar at every call site: `my @a = <an undefined Array>` is an
# ARRAY OF ONE containing the type object, and `@a.defined` is True
# whatever is in it, so the "nothing to report" answer only survives in a
# $ container.
method !grant-snapshot(--> Array) {
	return Array unless $!provider.defined && $!provider.can('grants');

	my @grants;
	my $threw;
	{
		CATCH { default { $threw = $_ } }
		@grants = $!provider.grants.list;
	}
	$threw.defined ?? Array !! @grants;
}

# === Cancellation ===

# The finish spec of a cancelled run. A spec, not a finish: see !drive.
my sub cancel-spec(Str:D $stage, Int:D $round, @conversation --> Hash:D) {
	finish-spec(
		LLM::Agent::Event::RunCancelled.new(
			:$stage, round => ($round > 0 ?? $round !! Int),
		),
		messages => @conversation.List,
	);
}

# Remember the stream a run is waiting on, under that run's name.
method !set-active(Str:D $run-id, $backend, $resp --> Nil) {
	$!lock.protect: {
		%!active = run-id => $run-id, backend => $backend, response => $resp;
	};
	Nil;
}

#|( The Run's on-cancel hook: poke the in-flight stream so a cancel does
    not wait out a poll interval (and, on a backend that really aborts,
    stops the generation upstream).

    The owner check is what makes a stale hook harmless. C<cancel> on a
    finished run does not call its hook at all, but a hook that fires
    concurrently with the end of its own run still finds a slot that is
    either its own or empty — never the next run's, because that run
    claimed the slot under its own id. The C<cancel> itself happens
    B<outside> the loop's lock: it is a backend's code, and it can block. )
method !poke-cancel(Str:D $run-id --> Nil) {
	my ($backend, $resp) = $!lock.protect: {
		(%!active<run-id> // '') eq $run-id
			?? (%!active<backend>, %!active<response>)
			!! (Nil, Nil);
	};
	try $backend.cancel($resp) if $backend.defined && $resp.defined;
	Nil;
}

# Drop the slot, but only if this run still owns it. An old driver
# clearing on its way out must not wipe the slot of the run that took its
# place.
method !clear-active(Str:D $run-id --> Nil) {
	$!lock.protect: {
		%!active = () if (%!active<run-id> // '') eq $run-id;
	};
	Nil;
}

# === Plain helpers ===

#|( A finish spec: the terminal event, and the C<%outcome> keys that go
    with it. The state machine builds one and returns it; C<run>'s
    epilogue is the only thing that calls C<_finish>. )
my sub finish-spec(LLM::Agent::Event:D $terminal, *%outcome --> Hash:D) {
	%( terminal => $terminal, outcome => %outcome.Hash );
}

# The spec a failed run ends on. Built in four places (the classifier gave
# up, the compaction ran out of room, the driver died, the driver returned
# nothing), always with the same keys. `reason` is the machine-readable
# half — set only where the loop has something better to say than "it
# failed".
my sub failure-spec(Str:D $error, @attempts, @conversation, Int $round?,
	Str :$reason,
	--> Hash:D
) {
	finish-spec(
		LLM::Agent::Event::RunFailed.new(
			:$error, attempts => @attempts.List, :$round, :$reason,
		),
		:$error,
		:$reason,
		attempts => @attempts.List,
		messages => @conversation.List,
	);
}

#|( C<ToolLoop>'s signature scheme, tightened: name, a NUL, and the
    arguments B<canonicalised>. The NUL is what keeps C<< read("a\0b") >>
    from colliding with C<< read\0("a", "b") >>; no tool name or JSON
    document contains one.

    The canonicalisation is what makes the identical-call guard mean
    anything. Two calls that differ only in key order or whitespace are
    the same call to every tool that will ever run them, and a model
    stuck in a loop rarely re-emits a byte-identical document — it
    re-emits the same request. Arguments that are not JSON at all are
    their own signature, verbatim. )
my sub tool-call-signature($call --> Str:D) {
	my $function = $call ~~ Associative ?? $call<function> !! Any;
	my $name = $function ~~ Associative ?? ($function<name> // '') !! '';
	my $arguments = $function ~~ Associative ?? $function<arguments> !! Str;
	$name ~ "\0" ~ canonical-arguments($arguments);
}

#|( Does a tool-name pattern — an exact name, or one ending in C<*> —
    match a tool name? The same shape C<MCP::Client::Policy>'s rules use,
    spelled out here rather than imported: the loop is B<policy-unaware>
    and does not load that module for anything. )
my sub match-tool-pattern($pattern, Str:D $name --> Bool:D) {
	return False unless $pattern ~~ Str:D && $pattern.chars;
	return $name.starts-with($pattern.substr(0, *-1))
		if $pattern.ends-with('*');
	$pattern eq $name;
}

#|( The one line of an error result worth keeping on the settle envelope.
    The whole thing is already in the tool message; this is the version a
    resume, a log or a UI reads without pulling the conversation apart. )
my constant ERROR-SUMMARY-CHARS = 200;
my sub error-summary(Str:D $content --> Str:D) {
	my Str $line = ($content.lines.first({ .trim.chars }) // '').trim;
	$line.chars > ERROR-SUMMARY-CHARS
		?? $line.substr(0, ERROR-SUMMARY-CHARS) ~ '…'
		!! $line;
}

# What a tripped run cap says for itself. See `!caps-tripped`.
my sub caps-error(%caps --> Str:D) {
	'LLM::Agent::Loop: the run is over its ' ~ (%caps<cap> // 'budget')
		~ ' cap — ' ~ (%caps<spent> // '?') ~ ' of ' ~ (%caps<max> // '?')
		~ '. Every tool call that had been dispatched was allowed to settle '
		~ 'first; nothing after that point was started';
}

#|( What the tool declarations are worth, in tokens, for the preflight:
    four characters to a token over their JSON rendering.

    Estimated rather than counted on purpose. They are a schema, not
    prose, so a tokenizer calibrated on a conversation has nothing to say
    about them; and they are counted at all because a catalogue of thirty
    tools is thousands of tokens on every single request — and because
    they B<vanish> the moment a limit switches tools off, which is
    exactly the case where a conversation that did not fit suddenly does. )
my sub tool-token-estimate(@tools --> Int:D) {
	return 0 unless @tools.elems;
	ceiling(to-json(@tools.List, :!pretty).chars / 4);
}

#|( The messages a request really carries: the run context's head message
    (when it has one), the conversation, and the context's tail message
    (when it has one).

    B<This is a view, and it is built here and used in exactly one place.>
    The conversation is what the loop, the session and the compactor all
    reason about; the wire view exists for the length of one
    C<chat-completion-stream> call and is never stored, counted or
    compared. Without a context it B<is> the conversation. )
my sub wire-view(@conversation, $context --> List:D) {
	return @conversation.List without $context;

	my $head = $context.head-message;
	my $tail = $context.tail-message;
	return @conversation.List unless $head.defined || $tail.defined;

	(
		|($head.defined ?? ($head,) !! ()),
		|@conversation,
		|($tail.defined ?? ($tail,) !! ()),
	).List;
}

#|( The complaints a provider makes when the prompt is too long, as
    substrings, matched case-insensitively.

    This is B<text sniffing>, and it is documented as such: there is no
    status code, header or error class that distinguishes "your prompt
    does not fit" from any other 400, and the patterns below are what the
    providers in this ecosystem actually say. The preflight is the real
    defence; this is the seatbelt for the window nobody declared. )
my constant OVERFLOW-PATTERNS = (
	'context length',
	'context_length',
	'maximum context',
	'too many tokens',
	'prompt is too long',
);

my sub context-overflow-text(Str:D $error --> Bool:D) {
	my Str $lower = $error.lc;
	so OVERFLOW-PATTERNS.first({ $lower.contains($_) });
}

# A number from a payload the loop did not build, or the default. A
# server that reports its progress as "17 files" must not be able to take
# a run down with a coercion failure.
my sub numeric-or($value, Num:D $default --> Num:D) {
	return $default without $value;
	my $number = try { $value.Num };
	($number.defined && $number ~~ Num) ?? $number !! $default;
}

my sub call-id($call --> Str:D) {
	(($call ~~ Associative ?? $call<id> !! Str) // '').Str;
}

my sub call-name($call --> Str:D) {
	my $function = $call ~~ Associative ?? $call<function> !! Any;
	(($function ~~ Associative ?? $function<name> !! Str) // '').Str;
}

my sub call-arguments($call) {
	my $function = $call ~~ Associative ?? $call<function> !! Any;
	my $arguments = $function ~~ Associative ?? $function<arguments> !! Nil;
	$arguments ~~ Associative ?? $arguments.Hash
		!! ($arguments.defined ?? $arguments.Str !! Str);
}

# What a backend calls itself. Duck-typed: `.model` is a convention among
# the LLM::Chat backends rather than part of the base class.
my sub model-of($backend --> Str:D) {
	((try $backend.model) // 'unknown').Str;
}

#|( What an attempt was billed, as far as the provider said.
    C<prompt-tokens> / C<completion-tokens> / C<total-tokens> from the
    OpenAI-spec usage block, plus C<cost> / C<generation-id> /
    C<provider-name> where a provider's Response subclass carries them
    (OpenRouter's does).

    Probed with C<.?>, the telemetry-payload idiom: a Response that never
    heard of C<cost> contributes no such key, and a test double needs
    only the accessors it cares to expose. Absent means "not reported",
    which is B<not> the same as zero — a run whose backends price nothing
    has no cost, rather than a cost of nothing. )
my sub usage-of($resp --> Hash:D) {
	my %usage;
	%usage<prompt-tokens>     = $resp.prompt-tokens     if $resp.prompt-tokens.defined;
	%usage<completion-tokens> = $resp.completion-tokens if $resp.completion-tokens.defined;
	%usage<total-tokens>      = $resp.total-tokens      if $resp.total-tokens.defined;

	my $cost = $resp.?cost;
	%usage<cost> = $cost.Num if $cost.defined;
	my $generation = $resp.?generation-id;
	%usage<generation-id> = $generation.Str if $generation.defined;
	my $provider = $resp.?provider-name;
	%usage<provider-name> = $provider.Str if $provider.defined;

	%usage;
}

# The replay-visible extras of a committed assistant turn: what it was
# thinking, and what it cost.
my sub assistant-extras($resp --> Hash:D) {
	my %extra;
	%extra<reasoning> = $resp.reasoning-text if $resp.reasoning-text.defined;
	my %usage = usage-of($resp);
	%extra<usage> = %usage if %usage.elems;
	%extra;
}

#|( Exactly one well-formed result per call, in the caller's order. A
    provider that came up short (or answered with a bare string) is
    normalised the way MCP::Client::Registry and MCP::Client::Policy
    normalise theirs, so the conversation always has a C<tool> message for
    every C<tool_calls> entry — which is what keeps the NEXT request valid.

    C<tool_call_id> is B<forced> to the id of the call this result answers,
    whatever the provider put there. The model's own C<tool_calls> entry is
    the only authority on that id: a result filed under anything else is a
    conversation the next request is rejected for, and a transcript nobody
    can resume. A provider that supplied a different one is not silently
    right and not silently wrong — the mismatch is pushed onto
    C<@mismatches> so the caller can say so out loud. )
my sub normalize-results(@tool-calls, @answers, @mismatches --> List) {
	@tool-calls.kv.map(-> Int $index, $call {
		my $answer = @answers[$index];

		with $answer {
			my %result = $answer ~~ Associative
				?? $answer.Hash
				!! %( content => $answer.Str );
			%result<role> = 'tool' unless %result<role>:exists;

			my Str $expected = call-id($call);
			my $provided = %result<tool_call_id>;
			@mismatches.push: %(
				index    => $index,
				name     => call-name($call),
				expected => $expected,
				provided => $provided.Str,
			) if $provided.defined && $provided.Str ne $expected;
			%result<tool_call_id> = $expected;

			%result<content> = (%result<content> // '').Str;
			%result<is_error> = ?%result<is_error>;
			%result;
		}
		else {
			%(
				role         => 'tool',
				tool_call_id => call-id($call),
				content      => 'The tool provider returned no result for '
					~ 'this call',
				is_error     => True,
			);
		}
	}).List;
}
