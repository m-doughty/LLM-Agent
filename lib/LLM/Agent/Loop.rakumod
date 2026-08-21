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
concurrent-tools  | tool-name patterns whose neighbouring calls go down as one batch
identical-call-exempt | tool-name patterns the identical-call guard does not count at all
steer-source      | a thunk answering user messages to inject between rounds
completion-bus    | an L<LLM::Agent::CompletionBus>: the work a run will not end without

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

The admission boundary is C<$run.drained>, not C<$run.result>. A cancelled
or deadlined run can have an answer while a detached provider call is still
producing or mutating; admitting another run over it would let callbacks and
side effects cross owners. The state machine therefore finishes the result,
closes every work section, and only then does C<run> accept another call.

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

=item B<Completions, first of all.> If the loop was given a
C<completion-bus>, everything background work reported since the last
round is drained off it and appended as framed user turns. Nothing at all
happens here without a bus. See L</Background operations: the run that
does not end yet>.

=item B<Steering, second.> If the loop was given a C<steer-source>, it is
asked whether the user has said anything since the last round, and
whatever it answers is appended as ordinary user turns — before the caps
are checked, before a compaction, and before the request is built, so
every one of them sees the new turns. Nothing at all happens here without
a C<steer-source>. See L</Steering: a user turn between rounds>.

B<Completions before steers, and it is not arbitrary>: a steer arriving
at the same boundary is very often the user reacting to a completion they
have just watched arrive, and putting the reaction before the thing
reacted to is a conversation that does not read.

=item B<Compaction check, at the top.> Before spending a request, not
after: a round that ends with six tool results is exactly the round that
blew the budget, and checking on the way in means the next request is the
one that fits. The compactor is asked C<needs-compaction> — B<its>
decision, not this class's, and it answers for every reason there is to
make a pass: the conversation is over C<compactor.trigger>, or it is
carrying an epoch's worth of stale tool results that can be elided far
more cheaply than the window can be summarized (see
L<LLM::Agent::Compactor>'s observation aging). Either way the pass runs,
the working array is swapped, the session gets a line for what it did — a
C<compaction>, an C<elision>, or both — and C<CompactionStarted> /
C<CompactionDone> frame it. A pass that reports it could B<not> make the
next request fit ends the run — see L</When the context runs out>.

The conversation's own count is what the compactor works on, but the
number compared against the trigger includes the B<rendered run context>:
it is real weight on every request, and a trigger that ignored it would
let a conversation sail past the window by the size of an C<AGENTS.md>.

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
each call is dispatched, waited for and settled B<on its own> unless its
tool opted into a concurrency group: see L</One tool call at a time>.
Every result is filed under the B<call's>
C<tool_call_id> — the model's C<tool_calls> entry is the only authority
on that id, and a provider that answers with a different one has its
answer corrected and a C<Log> event emitted saying so. Letting it win
would put an id in the transcript that nothing in the conversation asked
for, which is a 400 on the next request and a session nobody can resume.

=item B<Grants.> If the provider C<can('grants')> — a policy does — the
snapshot is written to the session whenever it B<changes>, so a resumed
session does not ask the human again. See L</Grants, and when they are
written>.

No tool calls, or tools switched off: C<RunCompleted>, and the run ends —
B<unless> there is background work outstanding, in which case the run
parks instead of ending. See L</Background operations: the run that does
not end yet>.

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

What it costs is parallelism — which is free for every tool whose runtime
is a syscall, and B<not> free for one whose runtime is another agent. See
L</Concurrency groups, and the tools that qualify>.

=head3 Concurrency groups, and the tools that qualify

C<concurrent-tools> is a list of tool-name patterns — the same shape
C<idempotency-rules> matches with, an exact name or a trailing-C<*>
prefix glob — and it is B<empty by default>, which is the whole of the
section above unchanged. Name a tool in it and the loop is allowed to put
that tool's calls down together:

=begin code :lang<raku>

    LLM::Agent::Loop.new(
        :@backends, :$provider,
        concurrent-tools => ['task'],   # subagents may run side by side
    );

=end code

B<Consecutive runs only, and model order is never rearranged.> The batch
is walked in the order the model emitted it and a run of neighbouring
calls whose tools all match becomes one group; the first call that does
not match B<ends> that group and is dispatched on its own. So
C<task, task, fs_read, task> is three groups — C<[task, task]>,
C<[fs_read]>, C<[task]> — and the C<fs_read> still happens after the
first two subagents have answered and before the third one starts.
Grouping only ever merges B<neighbours>, because model order is the
contract the section above buys and gathering the two C<task> calls
around an C<fs_write> into one group would reorder side effects the model
described as a sequence.

A group of one B<is> a single dispatch: same envelopes, same events, same
code path. Nothing about a loop with no matching tools in its batch
differs from one built without the option at all.

What a group does with its calls is what the whole batch used to get: N
C<tool-dispatched> envelopes and N C<ToolStarted> events B<before>
anything runs, one C<execute-tool-calls> carrying all N calls, and then
one settle per call — its own tool message, its own C<tool-settled>
envelope, its own C<ToolResult> — in model order, indexed by position in
the call list.

B<What a group trades away> is the per-call granularity of the three
things above, and it is worth being precise about which:

=item B<Crash granularity is per group, not per call.> A C<SIGKILL> in
the middle of a group of three leaves B<three> dispatched-unsettled
operations, and a resume can only say "these three were in flight" —
where an ungrouped batch would have said "this one was running, and those
two never started". Coarser, still honest: every one of the three really
had been handed to the provider.

=item B<A cancel or a deadline takes the whole group.> The group is one
wait; when it is given up on, every call in it settles
C<outcome-unknown> with the same reason. Calls B<after> the group are
untouched and still settle as C<abandoned> — known not to have run.

=item B<The policy decides the group before any of it runs.> A
C<MCP::Client::Policy> in front of a grouped batch asks its permission
questions for all N calls up front, which is exactly what per-operation
dispatch was introduced to stop. For a delegation tool that is the
desired UX (the human answers for the whole fan-out once); for anything
that mutates shared state it is the old bug.

B<So which tools qualify?> The argument that carries is C<task>'s: a call
whose side effects are confined to B<its own> resources and whose result
is a B<report> rather than a change to the world this conversation is
reasoning about. A subagent runs in its own transcript, spends its own
budget, and hands back prose. Two of them side by side cannot see each
other's half-written state, so "what the world looked like when call
three was decided" is not a question with a wrong answer.

A tool that reads or writes anything the next call in the batch might
touch does B<not> qualify, however tempting the wall clock is. C<fs_read>
looks harmless until the model writes a file and reads it back in one
turn; C<sh_run> is whatever somebody typed. Left out of
C<concurrent-tools>, both keep the ordering guarantee they have always
had.

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

No later call in that assistant batch is dispatched: each is settled as
known not to have run, and the run carries on to a fresh model round. The
detached call keeps a work section open, so C<< $run.drained >> waits for
it even though C<< $run.result >> did not.

A concurrency group is bounded the same way and B<as a whole>: the clock
is the longest-running operation in it, and a deadline that passes
detaches the batch and settles every call in it C<outcome-unknown>.

The clock B<pauses while a human is being asked>. At most one group is
ever in flight, so an C<AskPending> raised inside a call belongs to
B<that group>; C<wrap-ask> records the span on every operation in it, and
the deadline is measured against C<< dispatched-at + ask-seconds >>
rather than wall clock. Without that, a 30-second deadline would abandon
every call whose permission prompt sat on somebody's screen for a minute
— having never let it start. (For an ungrouped call — every call, until
something opts in — "that group" and "that call" are the same thing, and
the span is the one this paragraph always described.)

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

B<The number is 30, and it used to be 3.> Three could not tell a loop
from patience. A great many perfectly healthy flows make the same call
with the same arguments several times over, on purpose and by design: an
agent contending for a file lease retries the B<same> C<lock_acquire>
until the holder gives it back; an agent that has just written a file
reads it back to check, and reads it back again after the next edit; a
poll is a poll. At 3 the guard fired on the fourth honest repeat, the
loop disabled tools, the agent reported half a job, and whatever was
supervising it started the whole thing again — which is the failure the
guard exists to prevent, arrived at by the guard. A model that really is
going round in circles will do it thirty times just as happily as four,
and thirty repeats cost some tokens where a false positive costs the
task.

=head3 Tools the guard does not count

C<identical-call-exempt> is a list of tool-name patterns — an exact name
or a trailing-C<*> prefix glob, the same shape C<concurrent-tools> and
C<idempotency-rules> take, and B<empty by default>. A call whose tool
matches is skipped by the identical-call check B<entirely>: it is not
counted, and it cannot trip the limit. The skip happens before the
counting rather than after it, so an exempt call repeated forty times in
one batch does not walk the batch's own tally up to somewhere a later,
non-exempt call would fall off — and everything else in the batch is
counted exactly as it was.

=begin code :lang<raku>

    LLM::Agent::Loop.new(
        :@backends, :$provider,
        identical-call-exempt => ['lock_acquire', 'lock_release'],
    );

=end code

B<What qualifies> is a tool whose repetition is a B<protocol> rather than
a loop. Taking a lease is the argument's shape: "ask, be told somebody
else has it, ask again" is the designed way to use it, the arguments
cannot vary (they name the path), and the thing that ends the repetition
is the other agent finishing — nothing the model could think its way out
of. The same goes for the release beside it, and for any other tool whose
contract is "call me until the answer changes".

Nothing that B<does> work qualifies. C<fs_edit> with the same arguments
twice is either a no-op or a fight with somebody, C<sh_run> is whatever
the model typed, and an exemption on either is the guard turned off for
the calls it was written for. The other limits — C<max-tool-rounds> and
C<max-tool-calls> — still bound an exempt tool, so an exemption is not a
licence for an unbounded run; it only says B<this> tool's repeats are not
by themselves the evidence of a loop.

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

Three things reach that terminal, and they are the same fact arriving from
three directions: the compactor running out of things to drop (above), a
preflight that no backend passes (L</The preflight, per attempt and per
backend>), and a provider that B<truncated the answer> because the prompt
had already filled the window (L</The length that is really a window>).
The last of those is the one that costs money to discover, which is why it
is never discovered twice for the same conversation.

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

=head3 The C<length> that is really a window

The expensive way for a window to run out. The provider B<accepts> the
prompt, generates until it reaches the edge of the window, cuts the answer
off and reports C<finish_reason: 'length'> — which L<LLM::Chat> surfaces as
a quit with an error class of C<response>, which C<classify-error> buckets
as C<advance>, which on a single-backend chain degrades into a
C<retry-same>. The result was a 200k-token request sent three to seven
times, at a full prompt each, to be truncated identically every time.

So a C<length> is intercepted B<before> the retry buckets get it, read off
C<< $resp.finish-reason >> — structured, not sniffed, because L<LLM::Chat>
stamps the reason before it quits — and split into the two failures it
really is:

=begin table

Verdict        | What it means                        | What the loop does
===============|======================================|===================================
near-window    | the prompt filled the window         | a window refusal: advance, and one compaction for the whole chain
completion-cap | a small prompt, a small max_tokens    | RunFailed, reason 'completion-truncated'

=end table

A B<near-window> length is the preflight's refusal arriving from the other
side, and it goes exactly where that one goes: it counts as this backend's
window refusal, it is the second B<advance that does not degrade> into a
retry, and when every backend in the chain has refused, the loop compacts
B<once> and tries again — C<context-exhausted> if that does not help. The
one difference from a preflight refusal is what it cost to find out, which
is why the C<Log> event beside it is a C<warning> rather than an C<info>.

The judgement leans towards C<near-window> B<deliberately>, and the reason
is worth stating plainly: the counter is the thing that let this request
through. A C<length> arriving where the budget thought there was room is
evidence that the count was low, and the provider is the one who actually
tokenized the prompt. So the counted sum has to clear the window by more
than a B<quarter of itself> — a tokenizer disagrees with a counter by a few
percent, not by 25% — before the cheerful reading is believed. A truncated
response that carried C<usage> needs no tolerance at all: those are the
provider's own numbers, and C<prompt + completion> reaching the window is
the window saying so in its own words.

The compaction target is B<not> the preflight's "window less the reserve":
aiming a compaction at a number the counter has just been proved wrong
about would ask the compactor to drop nothing, and turn one compaction into
an instant C<context-exhausted>. It aims at the counted size that would
still fit B<if the counter were as wrong as it is allowed to be> — or as
wrong as the provider's own C<prompt-tokens> says it was — so the one retry
is always a genuinely smaller request.

A B<completion-cap> length is the other cap: a 12-token conversation whose
answer outgrew C<max_tokens>. Compaction cannot help, a different backend
truncates the same answer just as flatly, and there is nothing to retry —
so the round ends with C<RunFailed> and C<< reason =>
'completion-truncated' >>, and an C<error> naming the cap that bound and
what to raise. A backend B<nothing describes> lands here too, for the same
reason the preflight waves it through: an undeclared window is not evidence
of a full one, there is no target to compact to, and the terminal names
both possibilities so a deployment can declare a profile if the other one
was true.

=head3 The C<length> the provider does not report

The same cut, without the confession. A provider that decodes tool call
arguments under a grammar can reach C<max_tokens> with the JSON B<closed>
— every brace balanced, every string terminated — and report a finish
reason of C<tool_calls> rather than C<length>. What arrives is a
syntactically perfect call missing whatever the model had not written
yet: a task brief that stops mid-sentence, arguments railroaded into
whatever key the grammar could still close, and a loop that dispatches it
because nothing about the response looks wrong.

There is one witness left, and it is the provider's own: C<usage>. A
completion billed at the backend's C<max_tokens> B<was> stopped by
C<max_tokens>, whatever the finish reason says. So every successful
streamed turn — prose as much as tool calls — is checked against the cap
the backend declares, and a completion of

=begin code :lang<text>

    completion-tokens >= the backend's max_tokens

=end code

is treated as the truncation it is: B<no C<AttemptSucceeded>>, and the
failure path from there is exactly the one a reported C<length> takes —
the same C<!length-verdict>, so a clip on a request near the window
compacts once and a clip on a small one ends the run with
C<'completion-truncated'>, and the same refusal to re-send identical
bytes. One C<Log> at C<warning> names the disagreement (the reason the
provider gave, the tokens it billed, the cap they met); there is
deliberately no event class of its own, because the round did not fail in
a new way, it merely failed while claiming not to.

C<< >= >> rather than C<==> because usage that includes reasoning tokens
overshoots the cap on models that bill thinking, and there is no
tolerance in the other direction: a completion that stopped B<short> of
the cap stopped because it was finished. The false positive this admits
is an answer that happens to end on exactly its last permitted token, and
it costs a compaction or a named terminal — never a silently truncated
brief.

It is B<best-effort>, and the honest path stays primary: a provider that
reports no usage at all leaves nothing to check, and the gate is simply
inert. Asking for usage on a stream (C<stream_options.include_usage>)
would close that gap and is deliberately B<not> requested — it hangs
OpenRouter in the header phase, which is a worse failure than the one it
would catch. Providers that report usage without being asked (most do)
are covered; the rest keep the C<finish_reason: 'length'> gate above,
which is the one that catches an honest provider every time.

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
C<< spent => { total-tokens, wall-clock, cost?, prompt-tokens?,
completion-tokens?, cached-prompt-tokens?, parked-seconds? } >>. It is
absent without a budget, because "nobody was counting" and "nothing was
spent" are different answers.

C<wall-clock> is B<the time the run spent working>, which on a loop with
a C<completion-bus> is elapsed time B<less> every second it spent parked
on background work; C<parked-seconds> is that difference, present only
when the run actually parked. See L</The caps, and what "wall clock" now
means>.

The four optional keys follow the same rule one level down: each appears
only when B<some> attempt in the run reported that number, and carries
the sum over the attempts that did. A backend that reports only a total
leaves the C<prompt-tokens> / C<completion-tokens> split absent rather
than zero, so a caller can tell "this run was 8k in and 2k out" apart
from "this run was 10k, and nobody said which way". C<cached-prompt-tokens>
is a cache-hit SUBSET of C<prompt-tokens> — never its own addition to
C<total-tokens> — present only when a provider reported one.

B<Known limitation, and it is deliberate for 0.2:> a B<resumed> run
starts its accumulators at zero. The transcript knows what each turn
cost; adding those up across processes is a runtime store's job rather
than a transcript's, and the loop does not pretend otherwise.

=head3 Spend that happened somewhere else

The other half of that limitation is a run that pays for work it did not
do itself: a L<LLM::Agent::Subagents> child is a whole agent run of its
own, with its own loop, its own attempts and its own bill, and none of it
touches the accumulators of the parent that asked for it. A parent
C<max-cost> therefore used to cap the parent's own turns and nothing
else, which for an agent whose entire job is delegating is a cap on the
cheapest part of what it spends.

C<absorb-spend> closes that: it adds an already-settled spend record —
another run's, in exactly the shape this one hands back — into this run's
accumulators, so every cap sees it. The composer calls it as each child
settles (see L<LLM::Agent::Subagents>), which makes a parent's budget the
budget of its B<whole subtree>, recursively: a grandchild's spend is in
the child's record by the time the child settles into the parent's.

Two things about it are deliberate:

=item B<It is the same money, not a second kind.> An absorbed record adds
to C<cost> and to the token counts exactly as an attempt of this run
would, and the cap check that follows is the ordinary one at the next
round or operation boundary. There is no separate "subtree cap" and no
separate refusal — a run that goes over because of what its children
spent ends with the same C<RunFailed> and C<budget-exhausted> reason as
one that went over on its own.

=item B<C<wall-clock> is never absorbed.> This run's elapsed time is
measured from when it started, and children run B<inside> that window
(often several at once); adding their seconds to it would count the same
minute several times over and trip C<max-wall-clock> for a run that has
been going thirty seconds.

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
advance    | ...but with nowhere to go, it waits and tries again instead

=end table

C<max-retries> is the number of B<attempts per backend> (Task's
semantics, not "extra tries"): 3 means one call and two retries before
the chain advances. When the budget runs out, the C<AttemptFailed> says
C<advance>, because C<disposition> reports what the loop B<does> rather
than what the classifier said in the abstract.

C<backoff-cap> (default 30 s) is the ceiling on one wait;
C<LLM::Chat::Retry>'s exponential is C<< min(2 ** (n - 1) + jitter,
cap) >>.

=head3 Advance, with nowhere to go

C<advance> means "this failure is a property of B<this> backend, so ask
a different one". On the B<last link of the chain> — very often the
only link — there is no different one, and the literal reading of the
bucket is "give up". The loop does not take it: it degrades that
advance to a C<retry-same>, waits out the normal backoff, and asks the
same backend again, spending the same per-backend budget a
C<retry-same> would have.

The arithmetic is one-sided. If the retry fails the chain is over
exactly as it would have been, one backoff later; if it succeeds, a run
that was about to die on a transient hiccup did not. A single-backend
config used to end on one flaky connect having made B<one> call, which
is what this exists to stop.

The C<AttemptFailed> says C<retry-same> with its C<backoff>, because
that is what the loop is doing. When the budget is spent the next
failure says C<advance> and the chain ends, unchanged.

B<The advances that do not degrade> are the two context-overflow
seatbelts above: a 400 saying the conversation does not fit, and a
provider-reported C<length> on a request at the edge of the window. Both
are deterministic refusals of B<this conversation by this backend> —
re-sending identical bytes buys an identical refusal and a wait on top of
it, and in the C<length> case a second full prompt's worth of tokens to
learn nothing. Those two still end the backend's turn.

When every backend is spent, the run ends with C<RunFailed> carrying the
full C<attempts> list — the same C<< { backend-index, model, error,
raw-text? } >> records C<X::LLM::Chat::Retry::Exhausted> would have
carried, and no C<reason>: there is nothing to say about it beyond what
the attempts already say. The failures that B<do> carry a C<reason> are
the three the loop chose rather than suffered:

=begin table

reason               | Why the loop stopped
=====================|====================================================
context-exhausted    | it will not fit, and compaction cannot help
budget-exhausted     | a run cap (cost, tokens, wall clock) was reached
completion-truncated | max_tokens cut the answer off, and no smaller conversation changes that

=end table

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
turn immediately rather than after a backoff. On a chain with no next
backend it becomes a wait and another try, like every other advance
with nowhere to go.

This is I<not> the same thing as an HTTP client timeout that expired
while still trying to B<connect>. Those never reach a backend at all,
and L<LLM::Chat::Backend::OpenAICommon> classifies them C<connection> —
the C<retry-same> bucket — precisely because they say nothing about the
endpoint beyond "the network was unwell".

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

=head2 Steering: a user turn between rounds

A long run is a conversation the user is locked out of: the model works
for ten rounds, and everything the user thinks of in the meantime has to
wait for the run to end. C<steer-source> is the way in. It is a thunk —
B<no arguments> — answering a list of C<Str>, and the loop calls it at the
top of every round and appends each answer as an ordinary user message.

=begin code :lang<raku>

# The app's queue, and the app's lock: the UI thread pushes onto it and
# the loop's thread drains it.
my @steers;
my $steer-lock = Lock.new;

my $loop = LLM::Agent::Loop.new(
    :@backends, :$provider, :$session,
    # DRAINED, not peeked: what this hands back is gone from the queue,
    # because the loop has no way of handing it back.
    steer-source => {
        $steer-lock.protect: { my @taken = @steers; @steers = (); @taken }
    },
);

# ...from the UI, while the run is in flight:
$steer-lock.protect: { @steers.push: 'leave the tests alone for now' };

=end code

What the placement buys is that a steer is B<never a surprise>:

=item B<At a round boundary, never mid-batch.> The thunk is called with
nothing in flight — no stream open, no tool call dispatched, no group half
settled. A steer can therefore never land between an assistant turn
carrying C<tool_calls> and the C<tool> messages that answer them, which is
the malformed conversation every provider rejects (see L</The limit
ordering, and the assistant turn it discards> for the other half of the
same rule).

=item B<Before everything that reads the conversation.> The caps and the
preflight weigh the steer, a compaction can move it, C<RoundStarted>'s
token figure counts it, and the request carries it. A steer is not a
sidecar on the request — it is history, and the transcript records it as
one more user turn with nothing to mark it out.

=item B<On the round the limit path restarts, too.> When a tool limit
switches tools off and the loop goes round again for a final answer, that
round asks for steers like any other. It is the same round boundary.

=item B<Including the first round,> before the model has said anything.
The queue is normally empty there — the run was started from the user's
question a moment ago — and an app with something in it at that point gets
what it asked for: a second user turn after the first.

=item B<And while the run is parked,> once per C<park-poll>. A run waiting
on background work may be waiting for minutes, and a user locked out of it
for the duration would be locked out of exactly the situation they most
want a word in. A pull that comes back with something B<ends the park> and
starts a round, and what it took is carried into that round: the pull is
destructive, so a park that dropped it would swallow what the user typed.
Nothing about the placement rules above changes — a parked run has nothing
in flight by definition.

Three things are the B<app's> job, and the loop does not help with any of
them:

=item B<The queue's thread safety.> The thunk is only ever called on the
driving thread, at a quiescent point, one call at a time — but whatever it
reads is shared with whatever the UI pushes onto, and that is the app's
lock (or Channel) to get right.

=item B<Coalescing.> The loop records B<exactly> what it is handed: three
answers are three user messages, in order. An app that would rather send
one paragraph joins them itself.

=item B<Noticing delivery.> There is no C<Steered> event and no
acknowledgement, because the thunk already is one: the loop asked, and
what the app handed over is on its way. Rendering it is the ordinary
C<< $session.messages >> / C<AssistantMessage> path.

A thunk that B<throws> is shielded: the failure becomes a C<Log> event
(level C<error>, logger C<llm-agent.loop>), the round carries on with no
steers, and the next round asks again. An entry that is not a defined
C<Str> is dropped the same way. A broken queue cannot take a run down.

=head2 Background operations: the run that does not end yet

A tool call that answers immediately and does the work afterwards is the
difference between an agent that delegates and one that waits. The catch
is that the loop's terminal condition — B<the model stopped asking for
tools> — is exactly wrong for it: the model stopped asking because it was
told the answer would arrive later, and a run that ended there would end
before the answer it promised.

C<completion-bus> is the fix, and it is the whole of the fix.
L<LLM::Agent::CompletionBus> holds two things: the operations that have
been acknowledged and not yet reported, and the reports themselves. The
loop asks it one question at the terminal and one at every round
boundary.

=begin code :lang<raku>

    my $bus  = LLM::Agent::CompletionBus.new;
    my $loop = LLM::Agent::Loop.new(
        :@backends,
        provider       => $subagents,   # given the same bus: see its Pod
        completion-bus => $bus,
    );

=end code

B<Without a bus none of this exists.> No park, no drain, no events, no
behaviour change of any kind — which is what makes the option safe to add
to a loop that has always worked one way.

=head3 The two moments

=item B<At the top of every round,> whatever is on the bus is drained and
appended as user turns, before the caps, the compaction and the request —
the same placement a steer gets, and for the same reason. Completions go
in B<before> steers; see L</A round, step by step>.

=item B<At the no-tool-calls terminal,> the bus is asked whether it is
C<quiet>: nothing outstanding B<and> nothing queued, read as one snapshot.
Quiet means the run really is over, and it ends exactly as it always did.
Not quiet means it B<parks>.

=head3 What a park is

A park is the run waiting, with nothing in flight, on a bare timer. It
emits C<RunParked> with the inventory of what it is waiting for, fires
C<on-park>, and then looks at four things every C<park-poll> seconds:

=begin table

What it finds              | What it does
===========================|=========================================
something queued           | resumes; the next round delivers it
nothing outstanding either | ends the run: RunCompleted, as the terminal would have
the run was cancelled      | closes every outstanding op, then RunCancelled
a steer                    | resumes, carrying the steer into the round
nothing, for park-idle-timeout | the safety valve — see below

=end table

Every exit closes the park's span, fires C<on-unpark>, and emits
C<RunResumed> with the reason and how long it waited. Those two hooks are
B<balanced on every path>, including a throw, because a host that lends a
concurrency slot for the duration of a park needs it back.

B<A bare timer, not a wait.> Every poll in this class is written that way
to keep C<Promise.anyof> from accumulating continuations (see the note in
C<!stream>), and a park gets something more out of it: there is no
lost-wakeup race to lose, because there is no wakeup. A completion that
lands between two passes is found by the second one.

=head3 The turns a completion arrives as

An injected turn is an ordinary B<user> message with an extraordinary
first line. It says, in words, that it is an automated event and not the
user speaking, and it names the operation it is about — because a
conversation is compacted, and a turn that only made sense next to the
acknowledgement it answers becomes an orphan the first time that
acknowledgement is summarised away.

Its B<content> goes through the observation excerpt seam before the
message is built — the same seam a tool result goes through, the same
C<< request-budget.max-observation-size >>, the same artifact file beside
the transcript. A child that answers with a megabyte cannot land whole in
a user turn; what lands is an excerpt, and the full bytes are in the
artifact the marker names. The framing itself is never excerpted: it is
what makes the turn readable as an event rather than as a person.

The transcript line carries B<extras> — C<< injected => <kind> >>, the
operation's id, and whatever the producer added (C<completion-of>, the
originating call id) — and those extras are the durable B<delivery
marker>: a resume can tell a completion that was delivered from one that
is still owed without replaying a thing.

=head3 The caps, and what "wall clock" now means

C<max-wall-clock> bounds B<the time the run spent working>, which is
elapsed time B<less every second it spent parked>. A run that delegated
three children and waited twenty minutes for them did not work for twenty
minutes, and a cap that said it did would kill runs for being patient —
which, for an agent whose whole job is delegating, caps the one thing it
is for. The result Map reports C<parked-seconds> beside C<wall-clock>
whenever a run parked at all, so the two can be added back up.

B<C<park-idle-timeout> is the real-time bound>, and it is the safety
valve rather than a deadline: half an hour, by default, in which not one
thing arrived. Every arrival resets it. When it fires, the run closes
every outstanding operation, ends with C<RunFailed> and
C<< reason => 'park-idle' >>, and B<names the operations that never
answered> — because "whether they took effect is unknown" is the honest
thing to say about work whose producer went away, and the one thing
somebody reading that failure needs to know is which piece it was.

=head3 What a park does not do

=item B<It does not increment C<max-tool-rounds>.> A round that was woken
by a completion and asks for no tools is not a tool round, and a run that
spent its round budget on notifications would run out of them for reasons
that have nothing to do with tools.

=item B<It does not re-enter itself.> A wake round is an ordinary round:
cancel check, drain, steers, caps, compaction, request. If the model goes
quiet again with work still outstanding, it parks again — a fresh
C<RunParked>, a fresh inventory, a fresh idle clock.

=item B<It does not produce the work.> The loop opens nothing and settles
nothing; it reads the bus and drains it. Who acknowledges an operation and
who reports it are the composer's business (L<LLM::Agent::Subagents>) or
the host's.

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

The rendered head and tail are weighed once through the loop counter for the
ordinary proactive-compaction trigger. Every B<preflight and provider-length
verdict>, however, calls the selected profile counter's C<count-request>
(L<LLM::Agent::TokenCount>) over conversation, context and tool catalogue
together. An Exact counter can therefore render the model's real request
template; an older counter safely composes its conversation and text counts.

The proactive figure travels to the compaction consult as
C<< needs-compaction(@conversation, :$tokens) >>, so the compactor weighs
the trigger against the whole request while still working on the
conversation alone. It is deliberately B<not> passed
to the compactor as a target: C<Compactor>'s no-op path reports
C<exhausted> against the target it was given, and a reduced one would turn
a compaction with nothing to drop into a C<context-exhausted> terminal.

For forced compaction, the selected profile's complete request count is split
into conversation and non-history weight in that same counter's units. Its
usable conversation target travels with the counter that produced it, and
the compactor uses the override for every before/after, summary and trim
check. Targets in different tokenizers are never compared as raw integers;
fallback then re-preflights normally in its own units.

=head3 The calibration, across a context change

A calibration is "P prompt tokens for these N messages", and P was billed
for a complete request to one model. Before preflight the loop compares the
selected counter's model, context digest and canonical tool catalogue with
the shape it previously described. A change calls C<counter.invalidate>;
rewritten history is detected by Usage's prefix digest, while an unchanged
prefix extended with new turns keeps the calibration. The next usage-bearing
attempt re-calibrates the selected profile only.

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
L<LLM::Agent::CompletionBus> (the work a parked run is waiting for),
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

# A compactor works on candidate conversations, but a forced target is a
# statement about the COMPLETE request that one selected backend would take.
# This invocation-only adapter keeps the model counter and immutable framing
# together, so every candidate is re-counted with the same context and tools.
# In particular, Usage can fall back after the candidate rewrites its
# calibrated history without silently dropping the framing from later counts.
my class CompleteRequestCounter does LLM::Agent::TokenCount {
	has LLM::Agent::TokenCount:D $.counter is required;
	has @.tools;
	has Str $.context-head;
	has Str $.context-tail;

	method count-messages(@messages --> Int) {
		$!counter.count-request(
			@messages, tools => @!tools,
			|($!context-head.defined ?? (context-head => $!context-head) !! ()),
			|($!context-tail.defined ?? (context-tail => $!context-tail) !! ()),
		).Int;
	}
}

#|( How wrong the counter is allowed to be before a provider-reported
    C<finish_reason: 'length'> is read as a completion cap rather than as a
    full window — a B<quarter> of the request it measured.

    The number is a statement about tokenizers, not a tuning knob. A
    counter and a provider disagree by a few percent over template
    framing, tool scaffolding and the odd multi-byte grapheme; a quarter is
    several times that, so a request the counter puts more than 25% clear
    of the window really did have room, and a C<length> on it really was
    the completion cap. Below that margin the counter is not trusted
    against the provider — it is the thing that let the doomed request
    through in the first place. See C<!length-verdict>. )
my constant LENGTH-COUNTER-TOLERANCE = 0.25;

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

#| What later calls in the same assistant batch are told after one call's
#| deadline made the state of the world unknowable. They were never handed to
#| the provider, so this is stronger than C<DEADLINE-UNKNOWN-MESSAGE>.
our constant AFTER-DEADLINE-MESSAGE =
	'An earlier tool call exceeded its deadline, so this later call was not '
	~ 'dispatched. It did not run.';

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
    count, and one whose outcome is unknown counts too.

    B<Thirty, not three.> Three cannot tell a loop from patience: lease
    contention and verification re-reads are identical calls B<by
    design>. See the Pod's C<The identical-call guard>. )
has Int:D $.max-identical-calls = 30;

#|( Attempts per backend, including the first. Task's semantics: 3 means
    one call and two retries before the chain advances.

    It is also the budget the B<last> backend spends when its failure
    said "advance" and there is nowhere to advance to — see
    L</Failure>. )
has Int:D $.max-retries = 3;

#|( The ceiling on one backoff, in seconds. C<LLM::Chat::Retry>'s
    exponential is C<< min(2 ** (n - 1) + jitter, cap) >>, so this is
    what stops a long chain from sleeping for hours — and, at the other
    end, what lets a test drive the retry path without sitting out real
    seconds. The default is C<LLM::Chat::Retry::retry-backoff>'s own. )
has Real:D $.backoff-cap = 30;

#|( Seconds a single tool call may run before the loop stops waiting for
    it. Undefined (the default) means no deadline at all.

    B<A deadline that passes is not a failure.> The call is detached, the
    operation settles C<outcome-unknown>, and the model is told that
    whether it took effect is unknown — because a local clock knows
    nothing about a remote side effect. Later calls from that assistant
    batch are not dispatched; the run carries on with a fresh model round.

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

#|( The tools whose B<neighbouring> calls may go down as one batch: a list
    of tool-name patterns, each an exact name or a trailing-C<*> prefix
    glob — the same shape C<idempotency-rules> matches with.

    B<Empty by default, and an empty one changes nothing.> Every call is
    dispatched, waited for and settled on its own, exactly as it was
    before this option existed.

    A tool qualifies when its side effects are confined to B<its own>
    resources and its result is a report rather than a change to the world
    this conversation is reasoning about — C<task> is the argument's
    shape. See L</Concurrency groups, and the tools that qualify> for what
    a group trades away, which is real: crash granularity, the blast
    radius of a cancel, and a policy that decides every call in the group
    before any of it runs. )
has @.concurrent-tools;

#|( The tools the identical-call guard does not count: a list of tool-name
    patterns, each an exact name or a trailing-C<*> prefix glob, the same
    shape C<concurrent-tools> takes.

    B<Empty by default.> A matching call is skipped by the check
    altogether — it cannot trip C<max-identical-calls> and it is not added
    to the batch's own tally, so it cannot walk a neighbouring call's
    counting up either.

    A tool qualifies when its repetition is a B<protocol> rather than a
    loop: C<lock_acquire> against a contended lease is the argument's
    shape. See L</Tools the guard does not count>. )
has @.identical-call-exempt;

#|( Seconds of B<inactivity> — not total duration — before a stream is
    given up on. See the Pod on why this differs from Task. )
has Real:D $.round-trip-timeout = 120;

#|( Where a mid-run user turn comes from: a C<Callable> taking B<no
    arguments> and answering a (possibly empty) list of C<Str>, each of
    which becomes one ordinary user message. Undefined — the default — is
    a loop that never asks.

    Called at the B<top of every round>, on the driving thread, with
    nothing in flight; never mid-batch, and never between a tool call and
    its result. The queue behind it belongs to the app, and so does
    deciding whether three queued lines are three messages or one. See
    L</Steering: a user turn between rounds>. )
has &.steer-source;

#|( Where background work reports back: an L<LLM::Agent::CompletionBus>,
    or anything with its C<state> / C<quiet> / C<drain> / C<close-all> /
    C<outstanding-ops> surface. Undefined — the default — is a loop that
    never parks, and behaves in every particular as it did before this
    option existed.

    Given one, two things change and nothing else does. Whatever is on
    the bus at a round boundary becomes framed user turns at the top of
    that round, and a model that stops asking for tools with work still
    outstanding B<parks> rather than ending the run. See
    L</Background operations: the run that does not end yet>.

    B<Session-scoped, not run-scoped.> The bus belongs to the
    conversation: a child that settles after its parent run was cancelled
    has still done the work, and the next run of the same conversation is
    who should hear it. )
has $.completion-bus;

#|( Seconds a park may go without a single arrival before the run gives
    up on the work it is waiting for: C<close-all> on the bus, and a
    C<RunFailed> with C<< reason => 'park-idle' >> naming what never
    answered.

    Half an hour by default, which is a B<safety valve> and not a
    deadline. It exists because "the run ends only when the work is
    finished" is a promise about work that can finish, and an operation
    whose producer died takes it with them. Nothing legitimate should
    ever reach it: a child that runs for forty minutes reports something
    long before then, and every arrival resets the clock. )
has Real:D $.park-idle-timeout = 1800e0;

#|( How often a park looks at the world: the bus, a cancel, the steer
    source and the idle clock. A bare timer rather than a wait on any of
    them — the same anti-C<anyof> discipline C<!stream> and
    C<!execute-ops> are written with, and here it does something more:
    there is no lost-wakeup race to lose, because there is no wakeup. )
has Real:D $.park-poll = 0.1e0;

#|( Called with C<< { round, outstanding, ops } >> when a run B<starts>
    waiting on background work, and its counterpart with
    C<< { round, reason, parked-seconds } >> when it stops.

    B<Balanced on every exit path>, including a cancel, the idle valve
    and a throw, and both are B<shielded>: a host callback that dies is a
    bug in the host and never a reason for a run to fail.

    They exist for a host's own accounting, and one use is load-bearing
    rather than decorative: a parent parked on its children is doing
    nothing, so a host with a concurrency budget can lend its slot to
    somebody else for the duration. Without that, a host whose budget is
    one slot deadlocks — the parent holds the slot, the child queues for
    it, and the park waits for the child. )
has &.on-park;
has &.on-unpark;

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
# The last request framing each selected counter described. A provider's
# prompt-token report includes the runtime context and tool catalogue as
# well as the conversation, so a calibration may survive appended history
# only while all three non-history inputs (model, context and tools) stay
# the same. Keyed by counter identity because profile counters are allowed
# to be shared deliberately.
has %!counter-request-shapes;

#|( The in-flight stream, C<< { run-id, backend, response } >>, tagged
    with the run that owns it. The tag is the whole point: a run that has
    ended must not be able to cancel the stream of the run that replaced
    it, and every reader here checks the tag before it touches anything. )
has %!active;

#|( The tool operations currently dispatched, C<< { run-id, ops } >>,
    tagged with their run for the same reason C<%!active> is.

    B<One group is dispatched at a time> — and a group is one call unless
    its tool opted into C<concurrent-tools> — which is what makes the two
    shims able to correlate: an C<AskPending> that arrives while a group
    is in flight is about B<that group> (so its ask span goes on every
    operation in it, and the deadline pauses), and a progress notification
    is only believed when it names one of their calls.

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

		# ...and the same argument one step further in: a compactor that
		# ELIDES has a second kind of line to write, and a session that
		# cannot take it would leave a transcript replaying a conversation
		# the run never had. Asked of the compactor with `.?` so a
		# duck-typed one that has never heard of aging simply answers Nil.
		die 'LLM::Agent::Loop: this compactor ages observations, so its '
			~ 'session also needs append-elision (an LLM::Agent::Session has '
			~ 'one) — without it a resumed transcript would replay the tool '
			~ 'results that were elided, not the stubs the model was shown; '
			~ 'got a ' ~ $!session.^name
			if $!compactor.defined && $!compactor.?age-observations
				&& !$!session.can('append-elision');

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
			~ '(or something with its trigger / needs-compaction / compact / '
			~ 'context-budget); got a ' ~ $!compactor.^name
			unless $!compactor.can('trigger') && $!compactor.can('compact')
				&& $!compactor.can('needs-compaction')
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
		my $primary = $!request-budget.profile-for(model-of(@!backends[0]));
		my Int $primary-window = $primary.defined
			?? $primary.context-window
			!! Int;
		if $primary-window.defined
			&& $!compactor.context-budget > $primary-window {
			die 'LLM::Agent::Loop: the compactor compacts to a '
				~ $!compactor.context-budget ~ '-token budget, but the '
				~ 'primary/default backend window is ' ~ $primary-window
				~ ' — ordinary compaction targets the primary backend; smaller '
				~ 'fallback windows are handled by forced compaction';
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
	die 'LLM::Agent::Loop: backoff-cap must be positive — it is the '
		~ 'ceiling on one backoff, not a switch for turning them off'
		unless $!backoff-cap > 0;
	die 'LLM::Agent::Loop: tool-deadline must be positive — leave it '
		~ 'undefined for no deadline at all'
		if $!tool-deadline.defined && $!tool-deadline <= 0;

	# Structurally, the way a provider is: the bus is duck-typed on
	# purpose (a host may have its own), and a stand-in that is missing
	# half the surface must be found out here rather than at the first
	# round boundary, with a run half written and background work already
	# acknowledged to the model.
	if $!completion-bus.defined {
		my @missing = <state quiet drain close-all outstanding-ops>
			.grep({ !$!completion-bus.can($_) });
		die 'LLM::Agent::Loop: a completion-bus must have '
			~ @missing.join(' / ') ~ ' (an LLM::Agent::CompletionBus has '
			~ 'them, and so does anything shaped like one); got a '
			~ $!completion-bus.^name
			if @missing.elems;
	}

	die 'LLM::Agent::Loop: park-idle-timeout must be positive — it is the '
		~ 'safety valve on a park, not a switch for turning one off'
		unless $!park-idle-timeout > 0;
	die 'LLM::Agent::Loop: park-poll must be positive'
		unless $!park-poll > 0;

	# Same reasoning as the steer-source arity check below, and the same
	# mistake: a callback declared `-> { }` is one that would throw on
	# every park, be shielded, and become a Log event nobody is reading.
	for (on-park => &!on-park, on-unpark => &!on-unpark) -> $hook {
		die 'LLM::Agent::Loop: ' ~ $hook.key ~ ' is called with one Hash, '
			~ 'and this one cannot be — it wants ' ~ $hook.value.arity
			~ ' arguments. It is ' ~ $hook.key
			~ ' => -> %info { ... }'
			if $hook.value.defined && !$hook.value.cando(\(%()));
	}

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

	# Same reasoning, and the same moment: a pattern of the wrong shape is
	# a config mistake whose only symptom would otherwise be a tool that
	# quietly never groups — which looks exactly like a loop that ignored
	# the option. A rule HASH here is the likeliest slip of all, because
	# the option next to it takes them.
	for @!concurrent-tools.kv -> Int $index, $pattern {
		die "LLM::Agent::Loop: concurrent-tools entry $index is a "
			~ $pattern.^name ~ ', which is not a tool-name pattern — this '
			~ 'option is a plain list of names (or trailing-* prefix globs), '
			~ "not a list of rule hashes: concurrent-tools => ['task']"
			unless $pattern ~~ Str:D && $pattern.trim.chars;
	}

	# Same shape, same moment, same reasoning: an exemption that matches
	# nothing looks exactly like an exemption that was ignored, and the
	# symptom — a limit tripping on a tool somebody thought was exempt —
	# arrives an hour into a run rather than while the config is on screen.
	for @!identical-call-exempt.kv -> Int $index, $pattern {
		die "LLM::Agent::Loop: identical-call-exempt entry $index is a "
			~ $pattern.^name ~ ', which is not a tool-name pattern — this '
			~ 'option is a plain list of names (or trailing-* prefix globs), '
			~ "not a list of rule hashes: identical-call-exempt => "
			~ "['lock_acquire']"
			unless $pattern ~~ Str:D && $pattern.trim.chars;
	}

	# The steer source is called with no arguments, so one that cannot be
	# is a thunk that would throw on the first round of every run — and be
	# shielded, and become a Log event nobody is reading. Said here, where
	# the closure is on screen. `-> $x { }` is the whole of the mistake.
	die 'LLM::Agent::Loop: steer-source is called with no arguments, and '
		~ 'this one cannot be — it wants ' ~ &!steer-source.arity
		~ '. It is a thunk answering a list of Str: '
		~ 'steer-source => { $queue.take-all }'
		if &!steer-source.defined && !&!steer-source.cando(\());
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
	$!lock.protect: {
		die 'LLM::Agent::Loop: this loop already has a run in flight. One '
			~ 'run at a time — build a second Loop, or queue them above '
			~ 'this layer'
		if $!run.defined && $!run.drained.status ~~ Planned;
		$!run = $run;

	};
	$!grants-lock.protect: { $!grants-digest = $grants-digest };

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
		# and lets the epilogue close the driver's final work section, which
		# is the drained boundary that admits the next run.
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
		# stream slot first; finish the result; then close the driver's work
		# section last, which is what admits the next run, so
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
		my %flight = self!in-flight-context;
		my $run = %flight<run>;
		# A ticket the run may refuse (it can close between the line above
		# and this one), and a LEAVE so that the rethrow path below closes
		# the section as reliably as the normal one.
		my Bool $ticket = $run.defined && $run._work-begin;
		LEAVE { $run._work-done if $ticket; }

		# One group is in flight at a time, so a question asked now is a
		# question about that group — and the seconds a human takes to
		# answer are not seconds it spent working. This is what makes
		# `tool-deadline` pause for people. The span goes on EVERY
		# operation in the group: which of them the question is really
		# about is a thing the loop does not know (a policy asks about a
		# call, not about a batch), and charging the others for it would be
		# the one direction a deadline must not be wrong in. For a group of
		# one — every group, until something opts in — this is the single
		# operation it always was.
		my @asked = (%flight<ops> // ()).list;
		.ask-begin for @asked;
		LEAVE { .ask-end for @asked; }

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
		my %flight = self!in-flight-context;
		my $run = %flight<run>;
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

    B<Correlated, not trusted.> One group is in flight at a time — one
    call, unless a tool opted into C<concurrent-tools> — and a
    notification that names anything but a call in it is B<dropped>: a
    straggler from the previous call would otherwise move the wrong
    progress bar, and a token a server invented would create one for a
    call that does not exist. Same shape as C<log-hook> otherwise — no
    live run, no event. )
method progress-hook(--> Callable:D) {
	-> %params {
		my %flight = self!in-flight-context;
		my $run = %flight<run>;
		if $run.defined {
			my Bool $ticket = $run._work-begin;
			LEAVE { $run._work-done if $ticket; }

			my Str $id = (%params<tool-call-id> // '').Str;
			my $op = $id.chars
				?? (%flight<ops> // ()).list.first({ .call-id eq $id })
				!! LLM::Agent::ToolOperation;

			if $op.defined {
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
		my %flight = self!in-flight-context;
		my $run = %flight<run>;
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

#|( Add spend that happened B<somewhere else> to this run's bill, so the
    budget's caps see it. Answers True when it was counted.

    C<%spent> is another run's settled record, in exactly the shape a
    finished run hands back: C<< { cost?, total-tokens?, prompt-tokens?,
    completion-tokens?, cached-prompt-tokens? } >>. Every key is optional
    and an absent one adds nothing — "nobody counted" is not "zero", here
    as everywhere else in this class — and C<wall-clock> is B<ignored> if
    it is there, because this run's elapsed time is its own and a child
    ran inside it (see L<#Spend that happened somewhere else>).
    C<cached-prompt-tokens> absorbs the same way as the token halves —
    added to the parent's own, with the parent's C<reported-cached> flag
    set only when the child's record actually carried the key — and it
    still never feeds C<total-tokens>: a child's cache hits are a subset
    of a child's C<prompt-tokens>, already counted through that key.

    C<:$run-id> is the run the spend is meant for, and passing it is how a
    caller says "if that run is over, drop this on the floor": a child
    settling after its parent has finished must not be billed to whatever
    run comes next. Leaving it out absorbs into whichever run the
    accumulators are on, which is what a caller with no run handle in
    reach can honestly ask for.

    Safe from any thread — it takes the same lock every attempt's own
    record does — and it never emits, never checks a cap and never ends a
    run. The next round or operation boundary does the checking, exactly
    as it does for spend this run made itself. )
method absorb-spend(%spent, Str :$run-id --> Bool:D) {
	$!spend-lock.protect: {
		# An empty accumulator (no run has started yet) has no `run-id`, so
		# this one test covers both "that run is over" and "there is
		# nothing to absorb into". `if`, not an early return: `return` from
		# inside a block handed to `protect` is a trick that only works
		# while it stays in the method's dynamic scope, and this block is
		# one edit away from not being.
		my Str $current = (%!spend<run-id> // '').Str;
		my Bool $mine = so $current.chars
			&& !($run-id.defined && $run-id ne $current);

		if $mine {
			%!spend<complete> = False
				if %spent<complete>:exists && !%spent<complete>;
			if %spent<cost>.defined {
				%!spend<cost> += %spent<cost>.Num;
				%!spend<reported-cost> = True;
			}
			if %spent<prompt-tokens>.defined {
				%!spend<prompt-tokens> += %spent<prompt-tokens>.Int;
				%!spend<reported-prompt> = True;
			}
			if %spent<completion-tokens>.defined {
				%!spend<completion-tokens> += %spent<completion-tokens>.Int;
				%!spend<reported-completion> = True;
			}
			if %spent<cached-prompt-tokens>.defined {
				%!spend<cached-prompt-tokens> += %spent<cached-prompt-tokens>.Int;
				%!spend<reported-cached> = True;
			}

			# The record's own total when it gave one, and the two halves
			# added up when it did not — the same derivation
			# `!spend-record` makes, so an absorbed record counts against a
			# token cap however the run it came from was measured.
			my $total = %spent<total-tokens>;
			$total = (%spent<prompt-tokens> // 0)
				+ (%spent<completion-tokens> // 0)
				unless $total.defined;
			%!spend<total-tokens> += $total.Int if $total.Int > 0;
		}

		$mine;
	};
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

	# The steers a PARK pulled. The pull is destructive — the app's queue
	# hands them over rather than lending them — so a park that woke on one
	# has to carry it into the round it woke for. See
	# `!park-for-completions`.
	my @stashed-steers;

	loop {
		return cancel-spec('start', $round, @conversation)
			if $run.is-cancelled;

		# COMPLETIONS FIRST, and the order of the next few lines is the
		# contract.
		#
		# What background work reported while the model was quiet becomes
		# framed user turns HERE, before anything this round reads the
		# conversation: the caps and the preflight weigh them, a compaction
		# can move them, RoundStarted counts them, and the request carries
		# them. Exactly what a steer gets, and for exactly the reason a
		# steer gets it.
		#
		# Before the steers, deliberately. A steer arriving at the same
		# boundary is very often the user reacting to a completion they
		# have just watched arrive, so it belongs AFTER it in the
		# conversation; the other order puts the reaction before the thing
		# reacted to.
		#
		# Before the caps too, and that is what makes a cost cap that trips
		# on the wake round land the paid-for results in the transcript
		# before the terminal rather than losing them with it. The park's
		# span is already closed — its LEAVE does that on every exit path,
		# ahead of the `next` that re-enters here — so `!caps-tripped`
		# below measures the time this run spent WORKING and not the time
		# it spent waiting for somebody else's.
		self!drain-completions($run, @conversation, @ids, $round);

		# Whatever the app has queued for the model goes in HERE, before
		# anything this round reads the conversation: the caps and the
		# preflight weigh it, a compaction sees it, RoundStarted counts it,
		# and the request carries it. A steer arriving between two rounds is
		# a user turn like any other — see the Pod's `Steering`. And note
		# where this is: after the cancel check, and on the path the limit's
		# `next` re-enters, which is a round boundary too.
		#
		# The park's stash goes first: those came off the same queue at an
		# earlier instant, and a queue is FIFO whether or not a park
		# happened between two pulls of it.
		my @steers = (|@stashed-steers, |self!pull-steers($run));
		@stashed-steers = ();
		for @steers -> Str $steer {
			my $message = Message.new(role => 'user', content => $steer);
			@conversation.push: $message;
			@ids.push: self!record($message);
		}

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
			$run, @conversation, @ids, @attempts, $round, $context-tokens,
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
		# `context-overflow` when EVERY backend refused the conversation on
		# its SIZE: a preflight that would not send it, or a provider that
		# truncated the answer at the edge of the window. Either way that
		# is a different fact from a backend failing — the one thing that
		# could still change the answer is making the conversation smaller.
		# Once — a second refusal of a conversation that has already been
		# trimmed is the end of it.
		my %trip;
		my Bool $recompacted = False;
		loop {
			%trip = self!round-trip(
				$run, @conversation, ($tools-enabled ?? @tools !! ()),
				$round, @attempts, $context,
			);
			last unless %trip<context-overflow>;
			last if $recompacted;

			my %forced = self!force-compaction(
				$run, @conversation, @ids, @attempts, $round, %trip<target>,
				%trip<target-counter>, %trip<target-model>,
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
		# try. This is the compaction-exhausted terminal reached from the
		# other side, and it carries the same `reason`.
		#
		# No TurnDiscarded. A chain of preflight refusals streamed nothing
		# because it sent nothing; a provider-length may have streamed the
		# fragment it got as far as, and that fragment was already
		# retracted by the AttemptFailed that reported it — which is the
		# attempt-framing contract (see LLM::Agent::Event), and is why no
		# AttemptSucceeded ever went unanswered here.
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
			# `reason` only when the round trip had something to name — a
			# completion cap the loop refused to keep paying for. The
			# ordinary "every backend failed" carries none, because the
			# attempts already say everything there is to say.
			return failure-spec(
				%trip<error>.Str, @attempts, @conversation, $round,
				|(%trip<reason>.defined
					?? (reason => %trip<reason>.Str)
					!! ()),
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

		# NO TOOL CALLS: the model has said what it had to say, and that is
		# normally the end of the run.
		#
		# It is NOT the end of one that has background work outstanding.
		# Something told the model "its answer will arrive later in this
		# conversation", and a run that ended here would make that a lie —
		# so the run PARKS instead, and the answer, when it comes, starts a
		# fresh round. See L</Background operations: the run that does not
		# end yet>.
		unless @tool-calls.elems {
			my %bus = self!bus-state($run);

			unless %bus<quiet> {
				# Something is already deliverable, so there is nothing to
				# wait for: no park, no RunParked, just another round —
				# whose drain, at the top, puts it in front of the model.
				next if %bus<queued>;

				my %parked = self!park-for-completions(
					$run, @conversation, @attempts, @stashed-steers,
					$round, $final,
				);
				return %parked<finish> if %parked<finish>.defined;
				next;
			}

			return finish-spec(
				LLM::Agent::Event::RunCompleted.new(
					final         => $final,
					rounds        => $round,
					message-count => @conversation.elems,
				),
				final => $final, messages => @conversation.List,
			);
		}

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
			%call-counts, @attempts,
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

#|( What C<steer-source> has to say this round, as a list of C<Str>, on a
    path that must not fail because of it.

    The thunk is B<the app's code>, called from the middle of a run: a
    queue whose lock is held by a thread that has died, a closure over a
    database handle that has closed, an app that answers a Hash. None of
    that is worth a run that is otherwise going fine, so a thunk that
    throws becomes a C<Log> event and this round gets no steers — the next
    round asks again, because the fault may well have been transient.

    Same posture as C<!record-context-shielded>, and for the same reason.
    An entry that is not a defined C<Str> is B<skipped and said out loud>
    rather than stringified: whatever C<.Str> made of a Message or a Hash
    would go into the transcript as something a user never typed. )
method !pull-steers($run --> List) {
	return () unless &!steer-source.defined;

	my $threw;
	my @items;
	{
		CATCH { default { $threw = $_ } }
		# Drained INSIDE the shield, and that is not tidiness: what a thunk
		# answers may be a lazy Seq whose generator throws on the first pull
		# (a `gather` reading the queue is the obvious way to write one), and
		# the throw would then arrive at the assignment rather than at the
		# call. `.list` on Nil, on Empty and on an empty Array is all the
		# same nothing; on a lone Str answered instead of a list of one it is
		# that one steer, which is what it looks like it means.
		@items = &!steer-source.().list;
	}

	# A pull that threw is a pull that did not happen, however far through
	# the list it got: half a queue delivered is worse than none of it.
	if $threw.defined {
		$run._emit(LLM::Agent::Event::Log.new(
			level  => 'error',
			logger => 'llm-agent.loop',
			data   => 'the steer source threw, so this round carries no '
				~ 'steering messages: '
				~ ($threw.message.lines.head // $threw.^name),
		)) if $run.defined;
		return ();
	}

	my @steers = @items.grep({ $_ ~~ Str:D });

	if @steers.elems != @items.elems {
		my @bad = @items.grep({ $_ !~~ Str:D }).map({ .^name });
		$run._emit(LLM::Agent::Event::Log.new(
			level  => 'error',
			logger => 'llm-agent.loop',
			data   => 'the steer source answered ' ~ @bad.elems
				~ ' entries that are not defined Str (' ~ @bad.join(', ')
				~ '), which were dropped — a steer is the text of one user '
				~ 'message',
		)) if $run.defined;
	}

	@steers.List;
}

# === Background operations, and the park ===

#|( Everything the bus has to report, turned into framed user turns at the
    top of a round. Answers how many it delivered.

    Three things happen per deliverable, in this order, and the order is
    the same invariant the artifact path has everywhere else in this
    class: the B<body> goes through the observation excerpt seam
    (C<!observe-result>) B<before the Message is built>, the framing is
    wrapped round the excerpt, and only then is the turn appended and
    recorded. So a child that answered with a megabyte lands in the
    conversation as an excerpt with the full bytes in an artifact file —
    exactly as a megabyte of C<fs_read> does — rather than as an
    unelidable user turn nothing can compact.

    B<Head and tail are never excerpted.> They are what says this is an
    automated event and not the user, and which operation it is about; a
    frame that got cut along with the content would leave a turn the model
    reads as somebody talking to it.

    The extras are the B<durable delivery marker>: C<injected> names the
    kind, C<op-id> names the operation, and whatever the producer put in
    C<extras> (C<completion-of>, the call id) travels with them. A resume
    can therefore tell a delivered completion from one still owed without
    replaying anything. )
method !drain-completions(
	$run, @conversation, @ids, Int:D $round,
	--> Int:D
) {
	my @items = self!bus-drain($run);
	return 0 unless @items.elems;

	# The round these turns belong to is the one about to START, not the
	# one that has just gone quiet: this runs before `$round++`.
	my Int $for-round = $round + 1;

	for @items -> %item {
		my Str $kind = (%item<kind> // 'background').Str;

		# THE OBSERVATION EXCERPT SEAM — the same one every tool result
		# passes through, called with an op id of this loop's own making
		# because a deliverable is not a tool operation and has none. The
		# run id is in it so that two runs of the same conversation cannot
		# write over each other's artifacts.
		my %observed = self!observe-result(
			$run,
			'background-' ~ $run.id ~ '-' ~ (%item<seq> // 0),
			$kind,
			(%item<body> // '').Str,
		);

		my Str $content = (
			(%item<head> // '').Str,
			%observed<content>,
			(%item<tail> // '').Str,
		).grep({ .chars }).join("\n\n");

		# Nothing at all to say is not a turn. The bus refuses an empty
		# deliverable, so this is belt and braces against a producer whose
		# whole content was whitespace.
		next unless $content.chars;

		my $message = Message.new(role => 'user', content => $content);
		@conversation.push: $message;

		my %extra = %item<extras> ~~ Associative ?? %item<extras>.Hash !! %();
		%extra<injected> = $kind;
		%extra<op-id>    = %item<op-id> if %item<op-id>.defined;
		%extra<artifact> = %observed<artifact> if %observed<artifact>.elems;

		my Str $message-id = self!record($message, :%extra);
		@ids.push: $message-id;

		# NB the unquoted keys: a QUOTED fat-arrow key in an argument list
		# is a positional Pair, not a named argument, and the constructor
		# refuses it several frames from here.
		$run._emit(LLM::Agent::Event::BackgroundOpDelivered.new(
			op-kind    => $kind,
			op-id      => (%item<op-id> ~~ Str:D ?? %item<op-id>.Str !! Str),
			message-id => $message-id,
			round      => $for-round,
		));
	}

	@items.elems;
}

#|( Wait for background work, rather than ending the run without it.

    Returns an empty Hash when the caller should go round again — a
    completion landed, or the user steered — and a B<finish spec> when the
    run ends here: everything settled with nothing left to say
    (C<RunCompleted>), a cancel (C<RunCancelled>), or the idle valve
    (C<RunFailed>, C<< reason => 'park-idle' >>).

    B<A bare timer, and deliberately not a wait on anything.> Every other
    poll in this class is written this way to keep C<Promise.anyof> from
    accumulating continuations on a promise that may never settle (see
    C<!stream>), and here it buys something else as well: there is no
    lost-wakeup race to lose, because there is no wakeup. A completion
    that lands one microsecond before this pass reads the bus is found by
    this pass; one that lands one microsecond after is found by the next.

    The order of the four checks is the contract:

    =item B<the bus first>, because that is what the run is here for — and
    C<state> is one atomic snapshot, so "something is deliverable" and
    "nothing is outstanding and nothing is queued" are read of the same
    instant. Split into two reads they describe two different worlds, and
    the operation that settled between them is an answer nobody hears;

    =item B<the cancel next, and before the steer pull>, which is a
    deliberate departure from the round top's order. Pulling steers is
    B<destructive> — the app's queue hands them over — and a cancelled run
    that pulled would swallow what the user typed and then end without
    saying it. Nothing is lost by checking the bus first: reading it is
    not draining it, and what is on it stays on it for the next run;

    =item B<the steer pull>, which is how a user gets a word in while a
    fleet of children works. What it takes goes into the caller's stash;

    =item B<the idle valve last>, because it is the only one of the four
    that is a guess. )
method !park-for-completions(
	$run, @conversation, @attempts, @stashed, Int:D $round, Str:D $final,
	--> Hash:D
) {
	my @inventory = self!bus-inventory($run);

	$run._emit(LLM::Agent::Event::RunParked.new(
		outstanding => @inventory.elems, ops => @inventory, :$round,
	));
	self!fire-park-hook($run, 'on-park', &!on-park, %(
		:$round, outstanding => @inventory.elems, ops => @inventory,
	));
	self!park-begin;

	# 'idle' until something better is known: the LEAVE below fires
	# whatever happens — including a throw out of the poll — and a park
	# that died still stopped being a park. The hooks are what a host
	# lends a concurrency slot on, so an unbalanced one is a host counting
	# this run as parked for ever.
	my Str $reason = 'idle';
	LEAVE {
		my Real $parked = self!park-end;
		self!fire-park-hook($run, 'on-unpark', &!on-unpark, %(
			:$round, :$reason, 'parked-seconds' => $parked.Num,
		));
		$run._emit(LLM::Agent::Event::RunResumed.new(
			:$reason, parked-seconds => $parked.Num, :$round,
		));
	}

	my Instant $give-up = now + $!park-idle-timeout;

	loop {
		my %bus = self!bus-state($run);

		# Something to say: go round again, and the drain at the top of
		# that round says it.
		if %bus<queued> {
			$reason = 'completion';
			return %();
		}

		# Nothing outstanding and nothing queued, of the SAME instant:
		# every operation closed, and at least one of them was collected
		# somewhere else (a `task_wait` that was parked when its child
		# settled takes the answer itself and enqueues nothing). There is
		# no round left to run — the model already said its piece.
		if %bus<quiet> {
			$reason = 'completion';
			return %( finish => finish-spec(
				LLM::Agent::Event::RunCompleted.new(
					final         => $final,
					rounds        => $round,
					message-count => @conversation.elems,
				),
				final => $final, messages => @conversation.List,
			) );
		}

		if $run.is-cancelled {
			$reason = 'cancelled';
			# CLOSE-ALL FIRST. The run is over, and an operation left open
			# on a session-scoped bus would park the NEXT run of this
			# conversation on work nobody is producing any more.
			self!bus-close-all($run);
			return %( finish => cancel-spec('parked', $round, @conversation) );
		}

		my @steers = self!pull-steers($run);
		if @steers.elems {
			$reason = 'steer';
			@stashed.append: @steers;
			return %();
		}

		if now > $give-up {
			$reason = 'idle';
			my @closed = self!bus-close-all($run);
			return %( finish => failure-spec(
				park-idle-error($!park-idle-timeout, @closed),
				@attempts, @conversation, $round, reason => 'park-idle',
			) );
		}

		await Promise.in($!park-poll);
	}
}

# What the idle valve says for itself. Named operations rather than a
# count, because the one thing somebody reading this wants to know is
# WHICH piece of work never came back.
my sub park-idle-error(Real:D $timeout, @closed --> Str:D) {
	'LLM::Agent::Loop: the run waited ' ~ $timeout ~ 's for background '
		~ 'work to report and nothing arrived, so it stopped waiting. '
		~ (@closed.elems
			?? (@closed.elems == 1
				?? 'One operation never answered: '
				!! @closed.elems ~ ' operations never answered: ')
				~ @closed.join(', ')
				~ '. Whether they took effect is unknown'
			!! 'Nothing was outstanding by the time it gave up, which means '
				~ 'the bus was emptied from somewhere else');
}

#|( One park hook, shielded and named. A host that throws out of one of
    these has a bug; a run that failed because of it would have two — and
    the failure would arrive at the one moment the run has nothing else
    wrong with it. )
method !fire-park-hook($run, Str:D $name, &hook, %info --> Nil) {
	return unless &hook.defined;

	my $threw;
	{
		CATCH { default { $threw = $_ } }
		&hook(%info);
	}

	$run._emit(LLM::Agent::Event::Log.new(
		level  => 'error',
		logger => 'llm-agent.loop',
		data   => "the $name hook threw, and was ignored: "
			~ ($threw.message.lines.head // $threw.^name),
	)) if $threw.defined && $run.defined;

	Nil;
}

#|( The bus as it stands: C<< { outstanding, queued, quiet } >>, or the
    quiet answer for a loop that has no bus at all.

    B<Shielded, and quiet is the fallback.> The bus is the app's object,
    and a stand-in that throws must not be able to park a run for ever —
    which is what treating a failure as "something is outstanding" would
    do. The run ends instead, the failure is said out loud, and whatever
    was really on the bus is still on it for the next run. )
method !bus-state($run --> Hash:D) {
	return %( outstanding => 0, queued => 0, quiet => True )
		unless $!completion-bus.defined;

	my %state;
	my $threw;
	{
		CATCH { default { $threw = $_ } }
		%state = $!completion-bus.state.Hash;
	}

	if $threw.defined {
		self!bus-complaint($run, 'state', $threw);
		return %( outstanding => 0, queued => 0, quiet => True );
	}

	%(
		outstanding => (%state<outstanding> // 0).Int,
		queued      => (%state<queued> // 0).Int,
		quiet       => ?(%state<quiet> // True),
	);
}

#| Everything the bus is holding for us, taken off it. Shielded: a drain
#| that threw delivered nothing, which is a round with no injected turns
#| rather than a run that died at a round boundary.
method !bus-drain($run --> List:D) {
	return () unless $!completion-bus.defined;

	my @items;
	my $threw;
	{
		CATCH { default { $threw = $_ } }
		@items = $!completion-bus.drain.list.grep({ $_ ~~ Associative })
			.map({ $_.Hash });
	}

	if $threw.defined {
		self!bus-complaint($run, 'drain', $threw);
		return ();
	}
	@items.List;
}

#| The inventory a RunParked carries. Shielded, and an empty list is a
#| park with nothing to show for itself rather than a failed one.
method !bus-inventory($run --> List:D) {
	return () unless $!completion-bus.defined;

	my @ops;
	my $threw;
	{
		CATCH { default { $threw = $_ } }
		@ops = $!completion-bus.outstanding-ops.list
			.grep({ $_ ~~ Associative }).map({ $_.Hash });
	}

	if $threw.defined {
		self!bus-complaint($run, 'outstanding-ops', $threw);
		return ();
	}
	@ops.List;
}

#| Stop waiting for everything that is outstanding, and answer what was
#| closed. Shielded, for the same reason every other call here is.
method !bus-close-all($run --> List:D) {
	return () unless $!completion-bus.defined;

	my @closed;
	my $threw;
	{
		CATCH { default { $threw = $_ } }
		@closed = $!completion-bus.close-all.list.map({ ($_ // '').Str });
	}

	if $threw.defined {
		self!bus-complaint($run, 'close-all', $threw);
		return ();
	}
	@closed.List;
}

# One complaint about the bus, in the one shape all four make it.
method !bus-complaint($run, Str:D $what, $threw --> Nil) {
	$run._emit(LLM::Agent::Event::Log.new(
		level  => 'error',
		logger => 'llm-agent.loop',
		data   => %(
			message => "the completion bus threw on $what, and the run "
				~ 'carried on without it — background work may not be '
				~ 'delivered',
			operation => $what,
			error     => ($threw.message.lines.head // $threw.^name),
		),
	)) if $run.defined;
	Nil;
}

#|( One round trip's worth of preflight, retry and fallback. Returns
    C<< { ok, response } >>, C<< { ok => False, error, reason? } >> or
    C<< { cancelled, stage } >> — plus one variant of the second:
    C<< { ok => False, 'context-overflow' => True, error, target } >>,
    when B<every> backend refused the conversation for window reasons and
    the caller's remaining move is to make it smaller.

    A window refusal is either a preflight that said no before anything
    was sent, or a provider that truncated the completion at the edge of
    the window (C<!length-verdict>, C<'near-window'>) — the same fact
    arriving from the other side. C<reason> is the terminal C<RunFailed>
    reason a failure has one of, and today that is only
    C<'completion-truncated'>. )
method !round-trip(
	$run, @conversation, @tools, Int:D $round, @attempts, $context,
	--> Hash:D
) {
	my Int $attempt = 0;

	my Int $unfit = 0;
	my Int $best-target = 0;
	my LLM::Agent::TokenCount $best-counter;
	my LLM::Agent::TokenCount $best-counter-identity;
	my Str $best-model;
	my Numeric $best-ratio = -Inf;
	# The window refusals, in the order they happened, for the message the
	# context-overflow return carries. Collected rather than read back off
	# the tail of @attempts: a backend that failed twice (a 500, then a
	# provider-length) leaves two records, and "the last N records" would
	# then quote a retry instead of a refusal.
	my Str @refusals;

	for @!backends.kv -> Int $backend-index, $backend {
		my Str $model = model-of($backend);
		my LLM::Agent::TokenCount:D $attempt-counter = self!counter-for($model);
		self!align-counter($attempt-counter, $model, @tools, $context);

		# BEFORE the retry loop, and before any AttemptStarted. Preflight
		# unfitness is deterministic — the same conversation will not fit
		# the same window a second time, so burning max-retries on it is
		# spending the retry budget on arithmetic. And the attempt framing
		# describes TRANSPORT attempts (a Token belongs to the
		# AttemptStarted that opened it), so a backend that was skipped
		# without a byte going anywhere must not open a token scope.
		my %fit = self!preflight(
			$backend, $model, @conversation, @tools, $context,
		);
		unless %fit<ok> {
			$unfit++;
			my Numeric $ratio = %fit<usable>
				/ max(1, %fit<request>);
			if !$best-counter.defined
				|| ($best-counter-identity.WHICH eqv $attempt-counter.WHICH
					&& %fit<usable> > $best-target)
				|| (!($best-counter-identity.WHICH eqv $attempt-counter.WHICH)
					&& $ratio > $best-ratio)
			{
				$best-target  = %fit<usable>;
				$best-counter = %fit<compaction-counter>;
				$best-counter-identity = $attempt-counter;
				$best-model   = $model;
				$best-ratio   = $ratio;
			}
			@refusals.push: %fit<error>;

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
			my %usage = usage-of($resp);

			# A provider attempt can cost money even when it fails or is
			# cancelled. Record it before any exit and teach the counter that
			# belongs to this backend/profile from the same observation.
			self!spend-record($run.id, %usage);
			# The counter calibrates prefix-size estimates from BILLED
			# prompt tokens, not cache-adjusted ones: cached-prompt-tokens
			# changes what the attempt cost, not how many tokens the
			# prefix actually is, so it is deliberately left out here.
			$attempt-counter.record-usage(
				prompt-tokens     => $resp.prompt-tokens,
				completion-tokens => $resp.completion-tokens,
				message-count     => @conversation.elems,
				prefix-digest     => messages-digest(@conversation),
				backend           => $model,
			) if $resp.prompt-tokens.defined;

			return %( cancelled => True, stage => 'streaming' )
				if $run.is-cancelled;

			# THE LENGTH THE PROVIDER DOES NOT REPORT (see the Pod). A
			# completion the provider billed AT — or past — the backend's
			# own `max_tokens` was cut off there, whatever finish reason
			# came with it. A constrained decoder can close a tool call's
			# arguments into valid JSON exactly at the cap and still say
			# `tool_calls`, and what arrives is a truncated answer wearing
			# a successful finish reason: syntactically perfect, missing
			# whatever the model had not written yet.
			#
			# `>=`, not `==`: usage that includes reasoning tokens
			# overshoots the cap on models that bill thinking. And no
			# under-cap tolerance in the other direction — a completion
			# that stopped short of the cap stopped because it was
			# finished.
			#
			# Best-effort by construction: a provider that reports no
			# usage leaves `completion-tokens` undefined and this gate
			# inert. The honest `finish_reason: 'length'` below is still
			# the primary defence; this is the one for providers that do
			# not say so.
			my Int $cap = completion-cap-of($backend);
			my Bool $usage-clipped = $resp.is-success
				&& $resp.completion-tokens.defined
				&& $cap.defined
				&& $resp.completion-tokens >= $cap;

			if $resp.is-success && !$usage-clipped {
				# The digest and the model are what make the calibration
				# checkable: "812 tokens for 14 messages" is only usable
				# again if the next 14 messages are THESE 14, asked of the
				# same model. Computed once, here, rather than per message
				# inside the counter.
				$run._emit(LLM::Agent::Event::AttemptSucceeded.new(
					:$round, :$attempt, :$backend-index,
					model-used    => $resp.model-used,
					finish-reason => $resp.finish-reason,
					usage         => %usage,
					latency-ms    => ((now - $started) * 1000).Int,
				));
				return %( ok => True, response => $resp );
			}

			# A clip takes the failure path WHOLE — the attempt record, the
			# AttemptFailed that retracts the tokens it streamed, the
			# verdict below and the terminal it leads to are all the ones a
			# reported `length` gets, because it is the same failure. No
			# AttemptSucceeded was emitted for it, so nothing has to be
			# taken back. The only thing a consumer cannot work out for
			# itself is that the provider said otherwise, and this is where
			# it is said: a warning Log, and deliberately no event class of
			# its own.
			if $usage-clipped {
				$run._emit(LLM::Agent::Event::Log.new(
					level  => 'warning',
					logger => 'llm-agent.loop',
					data   => %(
						message => "the provider reported finish_reason '"
							~ ($resp.finish-reason // 'none')
							~ "' but billed {$resp.completion-tokens} "
							~ "completion tokens against a cap of $cap: the "
							~ 'completion was clipped at max_tokens, and the '
							~ 'turn is treated as truncated rather than '
							~ 'committed',
						'backend-index'     => $backend-index,
						model               => $model,
						'finish-reason'     => ($resp.finish-reason // 'none'),
						'completion-tokens' => $resp.completion-tokens,
						cap                 => $cap,
					),
				));
			}

			my Bool $timed-out = !$usage-clipped && ?%stream<timed-out>;
			my Str $error = $usage-clipped
				?? "[backend $backend-index] the provider reported "
					~ "finish_reason '" ~ ($resp.finish-reason // 'none')
					~ "' but billed {$resp.completion-tokens} completion "
					~ "tokens against a cap of $cap: the completion was "
					~ 'clipped at max_tokens'
				!! "[backend $backend-index] " ~ ($timed-out
					?? "no activity for {$!round-trip-timeout}s"
					!! ($resp.err // 'the completion stream failed').Str);
			my Str $error-class = $usage-clipped
				?? 'response'
				!! ($timed-out ?? 'timeout' !! $resp.error-class);
			my Int $error-status = ($usage-clipped || $timed-out)
				?? Int
				!! $resp.error-status;

			# THE PROVIDER-REPORTED LENGTH (see the Pod). A backend that
			# quit because the provider said `finish_reason: 'length'` has
			# not had an accident: it has reported a CAP, and the same
			# request will meet the same cap every time. Retrying it is the
			# most expensive way there is to learn nothing — a full
			# window's worth of prompt tokens per attempt.
			#
			# Which cap it was decides where the failure goes, and
			# `!length-verdict` is the only thing that knows: the window
			# (context overflow the preflight's counter missed, which
			# belongs in the compaction path) or max_tokens (which
			# compaction cannot help, and which ends the run with a reason
			# that says so).
			#
			# Read from the settled Response rather than from the error
			# text: LLM::Chat stamps the finish reason BEFORE it quits, so
			# the fact is structured and there is nothing to sniff.
			#
			# A usage clip enters here too, and asks the SAME question: the
			# provider's own numbers say the completion was cut off, and
			# which cap did the cutting is still the thing that decides
			# where the failure goes. A clip on a request at the window is
			# a window refusal like any other truncation; a clip on a small
			# one is the completion cap, named as such.
			my %length = (!$timed-out
					&& ($usage-clipped || ($resp.finish-reason // '') eq 'length'))
				?? self!length-verdict(
					$backend, $model, @conversation, @tools, $context, $resp,
				)
				!! %();
			my Str $length-kind = %length<kind> // '';
			# Onto the error the attempt record is about to carry, not
			# beside it: "Hit max tokens" on its own is what made this
			# defect expensive to diagnose, and the attempts list is where
			# somebody reading a failed run looks first.
			$error ~= ' — ' ~ %length<explain> if $length-kind;

			my %failed-record = attempt-record(
				:$backend-index, :$model, :$error,
				# Only when there is something worth keeping: an empty
				# raw-text would make a connection failure look like a
				# model that answered with nothing.
				|($resp.latest.chars ?? (raw-text => $resp.latest) !! ()),
			);
			%failed-record<usage> = %usage if %usage.elems;
			@attempts.push: %failed-record;

			my Str $disposition = classify-error(:$error-class, :$error-status);

			# The seatbelt under the preflight (see the Pod): a 400 whose
			# text is one of the documented context-length complaints is
			# an ADVANCE, not an abort. A conversation the primary cannot
			# take is very often one the fallback can, and aborting the
			# chain on it throws away the backend that would have worked.
			#
			# It is one of the TWO advances that must not degrade into a
			# retry below (the provider-reported `length` just after it is
			# the other): a deterministic refusal of this conversation by
			# this backend, where sending the identical bytes again buys a
			# second identical 400 and a wait on top of it.
			my Bool $will-not-fit = $disposition eq 'abort'
				&& $error-status.defined && $error-status == 400
				&& ?context-overflow-text($error);
			$disposition = 'advance' if $will-not-fit;

			# A `length` at the edge of the window is the SAME refusal as
			# that 400, and it goes to the same place: a non-degrading
			# advance, counted as this backend's window refusal so that a
			# chain which refuses everywhere comes back as
			# `context-overflow` and gets its one compaction. The next
			# backend may well have a bigger window — that is what the
			# chain is for — and re-sending these bytes to THIS one buys a
			# second identical truncation.
			my Str $abort-reason;
			if $length-kind eq 'near-window' {
				$will-not-fit = True;
				$disposition  = 'advance';
				$unfit++;
				my Numeric $ratio = %length<usable>
					/ max(1, %length<request>);
				if !$best-counter.defined
					|| ($best-counter-identity.WHICH eqv $attempt-counter.WHICH
						&& %length<usable> > $best-target)
					|| (!($best-counter-identity.WHICH eqv $attempt-counter.WHICH)
						&& $ratio > $best-ratio)
				{
					$best-target  = %length<usable>;
					$best-counter = %length<compaction-counter>;
					$best-counter-identity = $attempt-counter;
					$best-model   = $model;
					$best-ratio   = $ratio;
				}
				@refusals.push: $error;

				# `warning`, where the preflight skip is `info`: this one
				# cost a full prompt to discover, and the number that let
				# it through was wrong. Somebody should widen the margin or
				# fix the counter.
				$run._emit(LLM::Agent::Event::Log.new(
					level  => 'warning',
					logger => 'llm-agent.loop',
					data   => %(
						message         => 'the provider truncated the '
							~ 'completion on a request at or near the '
							~ 'window: treated as context overflow, not '
							~ 'retried',
						'backend-index' => $backend-index,
						model           => $model,
						needed          => %length<needed>,
						window          => %length<window>,
					),
				));
			}
			elsif $length-kind eq 'completion-cap' {
				# The other cap. Nothing in the loop's toolkit changes the
				# outcome — a smaller conversation does not make a
				# truncated answer fit max_tokens — so this is a terminal
				# with a name rather than an advance, and the chain stops
				# here rather than truncating the same answer once per
				# backend.
				$disposition  = 'abort';
				$abort-reason = 'completion-truncated';
			}

			# ADVANCE WITH NOWHERE TO GO. `advance` means "this failure is
			# a property of this backend, so ask a different one" — and on
			# the last link of the chain (very often the only link) there
			# is no different one. Dying there is strictly worse than one
			# more try: the chain is over either way if the retry fails,
			# and a run that ends on a single transient connect failure
			# ends for no reason at all. So it waits and asks again,
			# spending the SAME per-backend budget a retry-same would.
			# When that budget is gone the fall-through below still ends
			# the chain, and the AttemptFailed still says `advance`,
			# because disposition reports what the loop does.
			$disposition = 'retry-same'
				if $disposition eq 'advance'
					&& !$will-not-fit
					&& $backend-index == @!backends.end
					&& $retries-left > 0;

			if $disposition eq 'abort' {
				$run._emit(LLM::Agent::Event::AttemptFailed.new(
					:$round, :$attempt, :$backend-index, :$model,
					:$error, :$error-class, :$error-status,
					disposition => 'abort', :%usage,
				));
				return %(
					ok => False, error => $error,
					|($abort-reason.defined ?? (reason => $abort-reason) !! ()),
				);
			}

			if $disposition eq 'retry-same' && $retries-left > 0 {
				my Int $retry-n = $!max-retries - $retries-left;
				my Num $backoff = retry-backoff($retry-n, cap => $!backoff-cap);
				$retries-left--;

				$run._emit(LLM::Agent::Event::AttemptFailed.new(
					:$round, :$attempt, :$backend-index, :$model,
					:$error, :$error-class, :$error-status,
					disposition => 'retry-same', :$backoff, :%usage,
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
				disposition => 'advance', :%usage,
			));
			last;
		}
	}

	# Every backend refused the conversation on the SIZE of it — a
	# preflight that would not send it, or a provider that truncated it at
	# the edge of the window. That is not "every backend failed": the one
	# move left is the caller's, and it is compacting to `target`, the
	# least-destructive complete-request ceiling in its selected counter.
	#
	# A chain of pure preflight refusals has spent nothing. A chain that
	# got here through a provider-length has spent the prompts it took to
	# find out, which is exactly why that path refuses to spend them twice
	# on the same conversation.
	return %(
		ok                 => False,
		'context-overflow' => True,
		target             => $best-target,
		'target-counter'   => $best-counter,
		'target-model'     => $best-model,
		error              => 'LLM::Agent::Loop: the request does not fit any '
			~ 'backend in the chain — ' ~ @refusals.join('; '),
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
    C<usable> is the biggest complete request this backend would have taken
    (window less the reserve and margin) and is what a forced compaction
    aims at through a counter adapter that keeps context and tools attached
    to every candidate conversation. )
method !preflight(
	$backend, Str:D $model, @conversation, @tools, $context,
	--> Hash:D
) {
	my %terms = self!window-terms(
		$backend, $model, @conversation, @tools, $context,
	);
	return %( ok => True ) unless %terms.elems;
	return %( ok => True ) if %terms<needed> + %terms<reserve> <= %terms<window>;

	%(
		ok     => False,
		needed => %terms<needed> + %terms<reserve>,
		window => %terms<window>,
		usable => %terms<usable>,
		messages => %terms<messages>,
		request => %terms<request>,
		'compaction-counter' => %terms<compaction-counter>,
		error  => 'preflight: needs ~' ~ (%terms<needed> + %terms<reserve>)
			~ ' (messages ' ~ %terms<messages> ~ ' + tools ' ~ %terms<tools>
			~ ' + context ' ~ %terms<context>
			~ (%terms<framing> ?? ' + framing ' ~ %terms<framing> !! '')
			~ ' + margin ' ~ %terms<margin>
			~ ' + reserve ' ~ %terms<reserve> ~ '), window ' ~ %terms<window>,
	);
}

#|( The window arithmetic for one backend, as B<named terms> — an empty
    Hash when nothing describes it, and otherwise C<< { messages, margin,
    reserve, window, needed, usable } >> where C<needed> is everything
    B<except> the completion reserve.

    Two callers, and that is the whole reason it exists: C<!preflight>
    asks it before an attempt, and C<!length-verdict> asks it after a
    provider has truncated one. If those two ever disagreed about how big
    the request was, a C<length> would be judged against a different sum
    than the one that let it through. )
method !window-terms(
	$backend, Str:D $model, @conversation, @tools, $context,
	--> Hash:D
) {
	return %() unless $!request-budget.defined;

	my $profile = $!request-budget.profile-for($model);
	return %() unless $profile.defined;

	my LLM::Agent::TokenCount:D $counter = self!counter-for($model);
	my Int $messages = $counter.count-messages(@conversation);
	my $head-message = $context.defined ?? $context.head-message !! Message;
	my $tail-message = $context.defined ?? $context.tail-message !! Message;
	my Str $context-head = $head-message.defined
		?? ($head-message.content // '').Str
		!! Str;
	my Str $context-tail = $tail-message.defined
		?? ($tail-message.content // '').Str
		!! Str;
	my Int $context-tokens = ($context-head.defined
		?? $counter.count-text($context-head) !! 0)
		+ ($context-tail.defined ?? $counter.count-text($context-tail) !! 0);
	my Int $tool-tokens = @tools.elems
		?? $counter.count-text(to-json(@tools.List, :!pretty))
		!! 0;
	my Int $request = $counter.count-request(
		@conversation, :@tools,
		context-head => $context-head, context-tail => $context-tail,
	);
	# A request-aware tokenizer can account for template framing that no
	# component count sees. Keep that adjustment explicit so diagnostics
	# still add up, and so the conversation target removes all non-history
	# weight in the selected tokenizer's own units.
	my Int $framing = $request - $messages - $tool-tokens - $context-tokens;
	my Int $margin   = $profile.input-safety-margin;
	my Int $reserve  = $!request-budget.reserve-for($profile, $backend);
	my Int $window   = $profile.context-window;

	%(
		:$messages, tools => $tool-tokens, context => $context-tokens,
		:$framing, :$margin, :$reserve, :$window,
		:$request,
		'compaction-counter' => CompleteRequestCounter.new(
			:$counter, tools => @tools.List,
			|($context-head.defined ?? (:$context-head) !! ()),
			|($context-tail.defined ?? (:$context-tail) !! ()),
		),
		needed => $request + $margin,
		# Never negative: a window smaller than its own reserve has no
		# room for a request of any size, and "compact to -300
		# tokens" is not an instruction.
		#
		# The per-invocation CompleteRequestCounter keeps context and tools
		# attached while the compactor changes only the conversation, so this
		# target is the complete request ceiling rather than a number produced
		# by subtracting independently-counted tokenizer units.
		usable => max(0, $window - $reserve - $margin),
	);
}

# The counter that describes one backend/model. RequestBudget profiles may
# carry different tokenizers and independent Usage calibration; falling back
# to the loop counter preserves the single-backend API.
method !counter-for(Str:D $model --> LLM::Agent::TokenCount:D) {
	return $!counter unless $!request-budget.defined;
	my $profile = $!request-budget.profile-for($model);
	$profile.defined && $profile.counter.defined
		?? $profile.counter
		!! $!counter;
}

# A Usage calibration is provider prompt usage for one complete request
# shape. Appended conversation history is handled by its prefix digest, but
# changing the selected model, runtime context or tool catalogue changes the
# non-history bytes around that prefix and must discard the old calibration.
# This runs before every backend preflight (including an undeclared one), so
# fallback always reaches its own counter in its own request shape.
method !align-counter(
	LLM::Agent::TokenCount:D $counter, Str:D $model, @tools, $context,
	--> Nil
) {
	my Str $identity = $counter.WHICH.Str;
	my Str $shape = data-digest({
		model   => $model,
		context => ($context.defined ?? $context.digest !! Nil),
		tools   => @tools.List,
	});
	my $previous = %!counter-request-shapes{$identity};
	if $previous.defined && $previous ne $shape {
		$counter.invalidate;
	}
	%!counter-request-shapes{$identity} = $shape;
	Nil;
}

#|( What a provider-reported C<finish_reason: 'length'> means for B<this>
    request: an empty Hash when there is nothing to say, and otherwise
    C<< { kind, explain, needed, window, usable } >> where C<kind> is
    C<'near-window'> or C<'completion-cap'>.

    The two are different failures wearing one word. C<near-window> is
    B<context overflow the provider caught and the preflight did not> —
    the prompt filled the window and the answer was cut off at the edge of
    it — and it belongs in the compaction path, not in a retry.
    C<completion-cap> is a small prompt whose answer outgrew
    C<max_tokens>; compaction cannot help, and the run ends with
    C<< reason => 'completion-truncated' >>.

    B<The verdict leans towards C<near-window>, deliberately.> The counter
    is the thing that let this request through, so a C<length> arriving
    where the budget thought there was room is evidence that the counter
    was B<wrong> — and the provider is the one who actually tokenized it.
    So the counted sum has to clear the window by more than
    C<LENGTH-COUNTER-TOLERANCE> of itself before the cheerful reading
    (C<completion-cap>) is believed. A truncated response that carried
    C<usage> needs no tolerance at all: those are the provider's own
    numbers, and C<prompt + completion> reaching the window is the window
    saying so in its own words.

    A backend B<nothing describes> gets C<completion-cap>, for the same
    reason C<!preflight> waves it through: an undeclared window is not
    evidence of a full one, there is no target to compact to, and the
    terminal it produces names both possibilities so a deployment can
    declare a profile if the other one was true.

    C<usable> — the number a forced compaction aims at — is B<not> the
    preflight's C<usable>, and that difference is the whole reason this
    path works. The preflight's number is "window less the reserve and
    margin", measured by the counter that has just been proved wrong;
    against a conversation the counter thinks already fits, aiming at it
    would ask the compactor to drop nothing and turn a compaction into an
    instant C<context-exhausted>. So the target is the counted size that
    would still fit if the counter were as wrong as it is allowed to be —
    C<< (window - reserve) / inflation >>, where the inflation is
    C<< 1 + LENGTH-COUNTER-TOLERANCE >>, or the provider's own
    C<< prompt-tokens / counted >> ratio when it reported one and that
    ratio is worse. It is always B<strictly smaller> than what the counter
    just measured, which is what makes the one retry a different request. )
method !length-verdict(
	$backend, Str:D $model, @conversation, @tools, $context, $resp,
	--> Hash:D
) {
	my Int $cap = completion-cap-of($backend);
	my Str $cap-says = $cap.defined
		?? "max_tokens $cap"
		!! 'a max_tokens the backend does not report';

	my %terms = self!window-terms(
		$backend, $model, @conversation, @tools, $context,
	);
	return %(
		kind    => 'completion-cap',
		explain => "the completion was cut off at $cap-says, and no "
			~ "request-budget profile describes model '$model' — with no "
			~ 'declared window there is nothing to compare the request '
			~ 'against, so the loop reads this as the completion cap rather '
			~ 'than the context window. Raise max_tokens if the answer '
			~ 'needs more room; declare a profile for this model if what '
			~ 'ran out was really the window',
	) unless %terms.elems;

	my Int $needed  = %terms<needed>;
	my Int $reserve = %terms<reserve>;
	my Int $window  = %terms<window>;

	# The provider's own numbers, when the truncated response carried
	# them. Exact, so no tolerance is applied to them: prompt +
	# completion reaching the window IS the window, and a prompt that
	# leaves less room than the backend was going to generate was over
	# the line before it was sent.
	my Int $prompt     = ($resp.?prompt-tokens     // 0).Int;
	my Int $completion = ($resp.?completion-tokens // 0).Int;

	my Bool $near;
	my Str  $measured;
	if $prompt > 0 {
		$near = ($prompt + $completion >= $window)
			|| ($prompt + $reserve > $window);
		$measured = "the provider billed $prompt prompt tokens"
			~ ($completion > 0 ?? " and $completion completion tokens" !! '')
			~ ' against a ' ~ $window ~ "-token window, with $cap-says";
	}
	else {
		my Int $tolerance = ($needed * LENGTH-COUNTER-TOLERANCE).ceiling;
		$near = $needed + $reserve + $tolerance > $window;
		$measured = 'the counter measured this request at ~'
			~ ($needed + $reserve) ~ ' of a ' ~ $window
			~ '-token window (messages '
			~ %terms<messages> ~ ' + tools ' ~ %terms<tools> ~ ' + context '
			~ %terms<context> ~ ' + framing ' ~ %terms<framing> ~ ' + margin '
			~ %terms<margin> ~ ' + reserve '
			~ "$reserve), and $cap-says";
		$measured ~= $near
			?? ' — within the ' ~ $tolerance ~ '-token tolerance the counter is '
				~ 'allowed to be wrong by, so the window is what ran out'
			!! ' — ' ~ ($window - $needed - $reserve) ~ ' tokens of window '
				~ 'room the answer never needed to reach';
	}

	if $near {
		# How wrong the counter has to be assumed to be, and therefore how
		# much smaller than its own measurement the next request has to
		# measure. The provider's ratio when there is one and it is worse
		# than the tolerance — it is the only real measurement of the
		# counter's error anybody here has.
		my Numeric $inflation = LENGTH-COUNTER-TOLERANCE + 1;
		$inflation = max($inflation, $prompt / $needed)
			if $prompt > 0 && $needed > 0;

		return %(
			kind    => 'near-window',
			explain => 'provider-length: the completion was truncated on a '
				~ "request at or near the window — $measured, so the "
				~ 'conversation rather than the completion cap is what has '
				~ 'to get smaller',
			:$needed, :$window, messages => %terms<messages>,
			request => %terms<request>,
			'compaction-counter' => %terms<compaction-counter>,
			usable => max(0, (($window - $reserve) / $inflation).floor
				- %terms<margin>),
		);
	}

	%(
		kind    => 'completion-cap',
		explain => "the completion was cut off at $cap-says: $measured. "
			~ 'Compaction cannot help — raise max_tokens on the backend '
			~ "(or the profile's completion-reserve) if the model needs "
			~ 'more room to answer',
		:$needed, :$window,
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
		# Swallowed, both of them, and that is all they are for: the end of
		# the stream and a stream that failed are BOTH states of $resp,
		# which the wait below reads directly. A tap without a quit
		# handler rethrows on the Supply's own thread, which is the one
		# reason there is anything here at all.
		#
		# `{ Nil }` and not `{ }`: an empty pair of braces is an empty
		# HASH, and a Supply handed one where a Callable belongs takes the
		# whole attempt down.
		done => { Nil },
		quit => -> $ { Nil },
	);

	# Wake often enough to notice a cancel or a stall promptly, and never
	# so often that a two-minute timeout is a busy loop.
	my Num $poll = max(0.005e0, min(0.05e0, ($!round-trip-timeout / 20).Num));
	my Bool $timed-out = False;

	# A BARE TIMER, and deliberately NOT `Promise.anyof($resp-settled,
	# $run.cancellation, Promise.in($poll))`: every anyof pass registers a
	# continuation on each promise it is handed, and the runtime only lets
	# go of those when that promise settles. `$run.cancellation` never
	# settles on a run nobody cancels, so twenty passes a second grew an
	# array nothing could free for the life of the run — measured at some
	# 97MB over ten minutes of streaming — and a cancel that finally did
	# arrive woke every one of those stale continuations at once.
	#
	# Nothing is lost by not waiting on them. A cancel is prompt because
	# !poke-cancel aborts THIS stream from the cancelling thread (that is
	# what the Run's on-cancel hook is for), and everything else this loop
	# needs — the end of the stream, the inactivity clock — is a state it
	# reads rather than an event it has to be told about. The one cost is
	# observation latency, and $poll bounds it at 50ms.
	until $resp.is-done {
		await Promise.in($poll);
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

#|( The tool section, B<one group at a time>: dispatch, wait, settle, then
    the next. A group is one call unless its tool opted into
    C<concurrent-tools>, which is what makes this the same method it was
    before that option existed.

    Returns C<< { settled } >> — how many operations reached an outcome,
    which is what the call counters count — plus a C<finish> spec when the
    run ends here rather than going round again.

    Everything that can end a run mid-batch is checked at the B<boundary
    between groups>, never inside one: an operation that has been
    dispatched is always allowed to settle first, because a cancel (or a
    cap) is a reason to stop starting things, not a reason to stop knowing
    what the last one did. )
method !run-tool-ops(
	$run, @ops, @tool-calls, @conversation, @ids, Int:D $round, %call-counts,
	@attempts,
	--> Hash:D
) {
	my Int $settled = 0;

	for self!concurrency-groups(@ops) -> @group {
		# Where this group starts and where the rest of the batch does. The
		# abandon ranges below are stated in terms of the WHOLE batch, so a
		# group that never runs takes everything behind it with it — which
		# is what the ungrouped code said with `$index` and still means.
		my Int $index = @group[0];
		my Int $after = @group[*-1] + 1;

		# The run caps, at the boundary between two groups —
		# `!caps-tripped` answers with an empty Hash when there is no
		# budget to answer from. The check is HERE, and not inside
		# `!execute-ops`, precisely so a tripped cap can never abandon an
		# operation that is already running: what is behind this group has
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
					caps-error(%caps), @attempts, @conversation, $round,
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

		my @batch-ops   = @group.map({ @ops[$_] }).List;
		my @batch-calls = @group.map({ @tool-calls[$_] }).List;

		my %group-outcome = self!dispatch-group(
			$run, @batch-ops, @batch-calls, @conversation, @ids, $round,
		);

		# Completed, failed and outcome-unknown all count; abandoned never
		# gets here. An unknown outcome counting is deliberate: a call that
		# times out identically for ever must still trip the guard.
		for @batch-ops -> $op {
			%call-counts{$op.signature}++;
			$settled++;
		}

		# Belt and braces for the grant hook. Even with nothing wired, a
		# human's "always" answer is on disk before the NEXT group is
		# dispatched — per-group dispatch bounds the staleness to one
		# group's runtime. Shielded: a session that cannot take the grants
		# must not leave the rest of this batch unanswered in the
		# transcript.
		self!sync-grants-shielded($run);

		if %group-outcome<cancelled> {
			self!abandon-ops(
				$run, @ops[$after ..^ @ops.elems], @conversation, @ids,
				$round, 'cancelled',
			);
			return %(
				settled => $settled,
				finish  => cancel-spec('tools', $round, @conversation),
			);
		}

		# A deadline leaves this group's side effects unknown. Dispatching
		# anything chosen against the pre-deadline world could reorder or
		# duplicate mutations, so account for every later call as known not
		# to have run and return control to the model for a fresh decision.
		if %group-outcome<deadline> {
			self!abandon-ops(
				$run, @ops[$after ..^ @ops.elems], @conversation, @ids,
				$round, 'deadline',
			);
			return %( settled => $settled );
		}
	}

	%( settled => $settled );
}

#|( The batch, cut into groups: a list of index lists, in model order,
    covering every operation exactly once.

    B<Consecutive runs only.> The batch is walked in order and a call
    whose tool matches C<concurrent-tools> joins the run being built; the
    first one that does not B<ends> it and stands alone. Grouping
    therefore only ever merges NEIGHBOURS, which is the whole of why model
    order survives it: a group is a contiguous slice of the batch, the
    slices are dispatched in order, and a call the model put between two
    groupable ones still happens between them.

    With no patterns configured this is one group per operation, which is
    the ungrouped loop exactly. )
method !concurrency-groups(@ops --> List:D) {
	return @ops.keys.map({ ($_,).List }).List unless @!concurrent-tools.elems;

	my @groups;
	my @current;
	for @ops.kv -> Int $index, $op {
		if self!concurrent-tool($op.tool) {
			@current.push: $index;
		}
		else {
			@groups.push: @current.List if @current.elems;
			@current = ();
			@groups.push: ($index,).List;
		}
	}
	@groups.push: @current.List if @current.elems;
	@groups.List;
}

#| Whether C<$tool> was named in C<concurrent-tools>: an exact name, or a
#| trailing-C<*> prefix glob, matched the way every pattern here is.
method !concurrent-tool(Str:D $tool --> Bool:D) {
	so @!concurrent-tools.first({ match-tool-pattern($_, $tool) });
}

#|( Whether C<$tool> was named in C<identical-call-exempt>, and so whether
    the identical-call guard ignores it. The same matching as everything
    else here; an unreadable name is the empty string, which no valid
    pattern except C<*> can match. )
method !identical-exempt(Str:D $tool --> Bool:D) {
	return False unless @!identical-call-exempt.elems;
	so @!identical-call-exempt.first({ match-tool-pattern($_, $tool) });
}

#|( One group — normally one operation: every C<tool-dispatched> envelope
    and every C<ToolStarted> first, then the provider once, then whichever
    settle path each answer (or the lack of one) calls for. Returns
    C<< { cancelled } >>, True only when the run is ending here.

    B<Every envelope before anything runs.> A group's N dispatch lines are
    written, in model order, before the batch goes down — so a crash mid
    group leaves N dispatched-unsettled operations rather than one, which
    is the honest record of what really had been handed over. The resume
    repair settles all of them; see L<LLM::Agent::Session>'s
    C<pending-tool-operations>.

    The write order on every settle path is the same, and it is
    load-bearing: B<the tool message first, the C<tool-settled> envelope
    second>. A crash between the two leaves a dispatched-unsettled
    operation whose call already has a C<tool> message, which is the
    signature of "it completed and the settle never landed" — and the
    only thing that distinguishes it from "it was still running". )
method !dispatch-group(
	$run, @ops, @calls, @conversation, @ids, Int:D $round,
	--> Hash:D
) {
	# The durable records come first, and each envelope id becomes its
	# operation's own: with a session, an operation IS its dispatch line.
	for @ops -> $op {
		my Str $op-id = self!record-dispatch($op);
		$op.dispatch(:$op-id);
	}

	# Visible to the shims for exactly as long as the group is running: an
	# ask arriving now is about these calls, and so is a progress
	# notification naming one of them.
	self!set-in-flight($run, @ops);
	LEAVE { self!clear-in-flight($run.id, @ops) }

	for @ops -> $op {
		$run._emit(LLM::Agent::Event::ToolStarted.new(
			id => $op.call-id, name => $op.tool, :$round,
		));
	}

	my %answer = self!execute-ops($run, @ops, @calls);

	if %answer<results>:exists {
		my @results = %answer<results>.list;
		# Settled in model order, each with the result at its own position:
		# the provider contract is one answer per call in the caller's
		# order, and `normalize-results` has already made that true even of
		# a provider that came up short.
		for @ops.kv -> Int $at, $op {
			self!settle-op(
				$run, $op, @results[$at], @conversation, @ids, $round,
			);
		}
		return %( cancelled => False );
	}

	# No answer, and none coming: the calls are detached and still running
	# somewhere. What they did is unknown — never failed. See the Pod.
	my Bool $deadline = ?%answer<deadline>;
	self!settle-unknown($run, @ops, @conversation, @ids, $round, :$deadline);

	%( cancelled => !$deadline, deadline => $deadline );
}

#|( One answered operation: the tool message, the settle, the settle
    envelope and the C<ToolResult> — in that order, which is the recovery
    story (see C<!dispatch-group>). )
method !settle-op(
	$run, $op, %result, @conversation, @ids, Int:D $round,
	--> Nil
) {
	my Bool $is-error = ?%result<is_error>;
	# THE ARTIFACT SEAM. Every byte of tool output the conversation,
	# the transcript and the ToolResult event will ever see passes
	# through here, before the message is built — which is what makes
	# an oversized result reach all three as the SAME excerpt, with
	# the full bytes spilled to a file beside the transcript.
	my %observed = self!observe-result(
		$run, $op.op-id, $op.tool, (%result<content> // '').Str,
	);
	my Str $content = %observed<content>;
	my %artifact = %observed<artifact>;

	# A BACKGROUND ACK, when the provider says so. The result is real and
	# the call really is answered — but what it answers with is "this has
	# started", not what it did, and a crash repair reading this transcript
	# has to be able to tell the two apart. Without the flag an
	# acknowledged-but-unreported operation looks exactly like a tool call
	# that finished, and repair stays silent about work that was lost.
	#
	# It rides the TOOL MESSAGE's extras because that is the durable line
	# the ack is: the dispatch envelope was written before the provider was
	# called, when nothing yet knew this would be a background op.
	my Bool $background = ?%result<background>;

	my $message = Message.new(
		role => 'tool', :$content, tool-call-id => $op.call-id,
	);
	@conversation.push: $message;
	@ids.push: self!record($message, extra => %(
		|($is-error ?? ('is-error' => True) !! ()),
		|($background ?? (background => True) !! ()),
	));

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

	Nil;
}

#|( Every operation of a group that was given up on: a C<tool> message
    saying so, an C<outcome-unknown> settle, and a C<ToolAbandoned> with
    C<< dispatched => True >>. One per operation, in model order.

    A whole group at once is B<coarser than a single call and no less
    honest>: every operation in it really had been handed to the provider,
    and none of them answered. That is the trade C<concurrent-tools>
    documents — for a group of one, which is every group until something
    opts in, this is the per-call path it always was. )
method !settle-unknown(
	$run, @ops, @conversation, @ids, Int:D $round, Bool:D :$deadline,
	--> Nil
) {
	my Str $reason = $deadline ?? 'deadline' !! 'cancelled';
	my Str $content = $deadline
		?? DEADLINE-UNKNOWN-MESSAGE
		!! CANCELLED-UNKNOWN-MESSAGE;

	for @ops -> $op {
		my $message = Message.new(
			role => 'tool', :$content, tool-call-id => $op.call-id,
		);
		@conversation.push: $message;
		@ids.push: self!record($message, extra => %(
			'outcome-unknown' => True,
			# `cancelled` as well, on that path only: it is the key a
			# transcript reader has looked for since 0.1.0, and dropping it
			# would break every consumer that tells a cancelled tail from a
			# normal one.
			|($deadline ?? () !! (cancelled => True)),
		));

		$op.settle(outcome => 'outcome-unknown', :$reason);
		self!record-settle($op);

		$run._emit(LLM::Agent::Event::ToolAbandoned.new(
			id => $op.call-id, name => $op.tool, :$reason, dispatched => True,
			:$round,
		));
	}
	Nil;
}

#|( Hand one group's calls to the provider and wait for them, in a single
    C<start> so that a cancel does not have to wait for them and a
    deadline can give up on them. Returns C<< { results } >> with one
    normalised result per call in call order,
    C<< { deadline => True } >> or C<< { cancelled => True } >> — the
    last two about the B<whole> group, which is what makes a group's
    blast radius the group.

    Normally a batch of one, through an unchanged provider contract:
    C<Registry>'s per-server grouping degenerates to singletons, which is
    the price of real per-operation dispatch and settle boundaries — and,
    incidentally, makes side effects happen in the order the model asked
    for them. A tool named in C<concurrent-tools> buys that price back for
    its own neighbours, and nothing else's. )
method !execute-ops($run, @ops, @calls --> Hash:D) {
	# The calls outlive this method on both give-up paths, so their work
	# section is closed by the batch itself rather than by a LEAVE here:
	# `.then` fires exactly once, whichever way it ends and whether or not
	# anybody is still waiting — which is what keeps `drained` honest.
	my @batch = @calls.List;
	my Bool $ticket = $run._work-begin;
	# `.list.eager`, and it is not decoration: a provider that hands back a
	# LAZY list has not done the work yet, and reifying it where the old
	# code did — on the driver's thread, after the wait — would run the
	# tool at the one moment nothing is watching the clock. A deadline
	# would never fire and a cancel would wait for the very call it was
	# cancelling. Forcing it here keeps the work inside the section this
	# method can give up on.
	my $batch = start { $!provider.execute-tool-calls(@batch).list.eager };
	$batch.then({ try $run._work-done }) if $ticket;

	# The adaptive poll of `!stream`, for the same reason: a fixed
	# `Promise.in($!tool-deadline)` cannot pause while a human is being
	# asked, and the deadline has to. Frequent enough to notice a
	# sub-second deadline, never so frequent that a minute-long tool is a
	# busy loop.
	#
	# And a bare timer for the same reason as well: an anyof over $batch
	# and $run.cancellation registered a continuation per pass on a
	# promise that may never settle. See !stream for the whole of it.
	my Num $poll = $!tool-deadline.defined
		?? max(0.002e0, min(0.05e0, ($!tool-deadline / 20).Num))
		!! 0.05e0;

	my Bool $expired = False;
	until $batch.status !~~ Planned {
		await Promise.in($poll);
		# The order matters: an operation that answered in the same
		# instant it was cancelled ANSWERED, and recording it as unknown
		# would throw away a fact we have.
		last if $batch.status !~~ Planned;
		last if $run.is-cancelled;

		# The longest-running operation in the group, which for a group of
		# one is the operation. They were dispatched in the same instant and
		# every ask span is recorded on all of them, so the max is the
		# group's own clock rather than an arbitrary member's.
		if $!tool-deadline.defined
			&& @ops.map({ .working-seconds }).max > $!tool-deadline {
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
	# that takes the run down — one per call, because a group that threw
	# threw for all of them and every call still needs its answer.
	return %( results => @ops.map(-> $op {
		%(
			role         => 'tool',
			tool_call_id => $op.call-id,
			content      => 'The tool provider failed: '
				~ ($threw.message.lines.head // $threw.^name),
			is_error     => True,
		);
	}).List ) if $threw.defined;

	my @mismatches;
	my @results = normalize-results(@batch, @answers, @mismatches);

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

	%( results => @results );
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
				!! ($reason eq 'deadline'
					?? AFTER-DEADLINE-MESSAGE
					!! NEVER-RAN-MESSAGE)),
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
    path, B<before the C<tool> message is built> — and so does every byte
    of a background deliverable, before its user turn is built
    (C<!drain-completions>). Returns C<< { content, artifact } >>: what
    everything downstream will carry, and the metadata of the file the
    rest of it went to (empty when there is no rest of it).

    C<$op-id> names the artifact file and C<$label> is what a failed write
    is reported against — a tool name for a tool result, a deliverable's
    kind for a background turn. Taken as B<strings> rather than as the
    operation they came from precisely so a completion, which is not a
    tool operation and has no C<ToolOperation> behind it, goes through
    this seam and not through a second one that would drift from it.

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
method !observe-result(
	$run, Str:D $op-id, Str:D $label, Str:D $content,
	--> Hash:D
) {
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
		%stored = $!artifact-store.store($op-id, $content);
	}

	if $threw.defined {
		$run._emit(LLM::Agent::Event::Log.new(
			level  => 'warning',
			logger => 'llm-agent.loop',
			data   => %(
				message   => 'the full tool result could not be written to '
					~ 'an artifact file; the model was given the excerpt '
					~ 'anyway, and the rest of the output is gone',
				'op-id'   => $op-id,
				tool      => $label,
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
			'run-id'              => $run-id,
			'started-at'          => now,
			cost                  => 0e0,
			'reported-cost'       => False,
			'total-tokens'        => 0,
			'prompt-tokens'       => 0,
			'reported-prompt'     => False,
			'completion-tokens'   => 0,
			'reported-completion' => False,
			'cached-prompt-tokens' => 0,
			'reported-cached'     => False,
			complete               => True,
			# The seconds this run spent PARKED, and the span that is open
			# while it is. Both live here rather than in the state machine
			# because `!spent` reads them under this lock, and because a
			# terminal reached from inside a park has to be able to close
			# the open one — see `!spent`.
			'parked-seconds'      => 0e0,
			'park-open-at'        => Instant,
		;
	};
	Nil;
}

#|( Open the park span. Nothing is billed as B<work> from here until
    C<!park-end>, which is what makes C<max-wall-clock> a bound on how
    long the run itself worked rather than on how patient it was with
    somebody else's.

    Idempotent in the sense that matters: a second open while one is
    already running leaves the first alone. One park at a time is
    structurally true — the state machine is one thread — and this is
    what keeps it true anyway. )
method !park-begin(--> Nil) {
	$!spend-lock.protect: { %!spend<park-open-at> //= now };
	Nil;
}

#| Close the park span into C<parked-seconds> and answer how long it was.
#| Zero for a close with no span open, which a doubled LEAVE would be.
method !park-end(--> Real:D) {
	$!spend-lock.protect: {
		with %!spend<park-open-at> -> $opened {
			my Real $span = now - $opened;
			%!spend<parked-seconds> = (%!spend<parked-seconds> // 0) + $span;
			%!spend<park-open-at> = Instant;
			$span;
		}
		else {
			0;
		}
	};
}

#|( Add one successful attempt's usage to the bill. C<cost> is only ever
    added when a provider reported one — a run whose backends price
    nothing spends nothing, which is honest, rather than counting an
    unreported cost as zero and calling that a measurement.

    The prompt and completion halves are kept the same way, and for the
    same reason: a run whose backend reports only a total has no split
    to show, which is a different answer from a split of zero.

    C<cached-prompt-tokens> is accumulated the same way, but it is a
    cache-hit SUBSET of C<prompt-tokens> — already counted there — so it
    never contributes to the C<complete> computation or the total
    fallback; doing so would double-count tokens the provider already
    billed once. )
method !spend-record(Str:D $run-id, %usage --> Nil) {
	$!spend-lock.protect: {
		if (%!spend<run-id> // '') eq $run-id {
			# Every invocation represents one provider attempt. Its usage is
			# complete only when the provider gave a total or both halves.
			my Bool $complete = %usage<complete>:exists
				?? ?%usage<complete>
				!! (%usage<total-tokens>.defined
					|| (%usage<prompt-tokens>.defined
						&& %usage<completion-tokens>.defined));
			%!spend<complete> = False unless $complete;
			if %usage<cost>.defined {
				%!spend<cost> += %usage<cost>.Num;
				%!spend<reported-cost> = True;
			}

			if %usage<prompt-tokens>.defined {
				%!spend<prompt-tokens> += %usage<prompt-tokens>.Int;
				%!spend<reported-prompt> = True;
			}

			if %usage<completion-tokens>.defined {
				%!spend<completion-tokens> += %usage<completion-tokens>.Int;
				%!spend<reported-completion> = True;
			}

			# A cache-hit subset of prompt-tokens, not an independent count:
			# it never feeds `complete` or the total fallback below, since
			# those tokens are already counted via prompt-tokens/total.
			if %usage<cached-prompt-tokens>.defined {
				%!spend<cached-prompt-tokens> += %usage<cached-prompt-tokens>.Int;
				%!spend<reported-cached> = True;
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
    prompt-tokens, completion-tokens, cached-prompt-tokens, wall-clock,
    parked-seconds } >>, with C<cost>, the two token halves,
    C<cached-prompt-tokens> and C<parked-seconds> present only when
    something reported them (or, for the last, only when the run has
    actually parked). The Map a finished run hands back carries exactly
    this.

    B<C<wall-clock> is the time this run spent WORKING>, which is elapsed
    time B<less> every second it spent parked on background work. A run
    that delegated three children and waited an hour for them did not work
    for an hour, and a C<max-wall-clock> that said it did would kill runs
    for being patient — which for an agent whose whole job is delegating
    is a cap on the one thing it is supposed to do. C<parked-seconds> is
    the difference, reported so the two numbers can be added back up.

    A terminal reached from B<inside> a park closes that park's open span
    here, exactly as C<LLM::Agent::ToolOperation>'s settle closes an open
    ask span: the LEAVE in C<!park-for-completions> is what normally does
    it, and this is what makes the answer right anyway if it somehow did
    not. )
method !spent(--> Hash:D) {
	$!spend-lock.protect: {
		with %!spend<park-open-at> -> $opened {
			%!spend<parked-seconds> = (%!spend<parked-seconds> // 0)
				+ (now - $opened);
			%!spend<park-open-at> = Instant;
		}
		my Real $parked = %!spend<parked-seconds> // 0;

		my %spent =
			'total-tokens' => (%!spend<total-tokens> // 0),
			# Never negative: the two clocks are read at different
			# instants, and a park closed a microsecond after `now` was
			# taken must not produce a run that worked for -0.001 seconds.
			'wall-clock'   => (%!spend<started-at>.defined
				?? (max(0, now - %!spend<started-at> - $parked) * 1000).round
					/ 1000
				!! 0),
		;
		%spent<parked-seconds> = ($parked * 1000).round / 1000 if $parked > 0;
		%spent<complete> = ?(%!spend<complete> // False);
		%spent<cost> = %!spend<cost> if %!spend<reported-cost>;
		%spent<prompt-tokens> = %!spend<prompt-tokens>
			if %!spend<reported-prompt>;
		%spent<completion-tokens> = %!spend<completion-tokens>
			if %!spend<reported-completion>;
		%spent<cached-prompt-tokens> = %!spend<cached-prompt-tokens>
			if %!spend<reported-cached>;
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
# `!dispatch-group` for why that ordering is the whole recovery story.
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

# Remember the operations a shim may be asked about, under their run's
# name. One group at a time, so this is the whole of what is running.
method !set-in-flight(LLM::Agent::Run:D $run, @ops --> Nil) {
	$!op-lock.protect: {
		%!in-flight = run-id => $run.id, run => $run, ops => @ops.List;
	};
	Nil;
}

# Drop them, but only if this run still owns the slot AND it still holds
# THESE operations: same reasoning as `!clear-active`, one level down.
# Compared element-wise by identity — a List's own identity is not a thing
# two references to the same group are guaranteed to share.
method !clear-in-flight(Str:D $run-id, @ops --> Nil) {
	$!op-lock.protect: {
		my @held = (%!in-flight<ops> // ()).list;
		%!in-flight = ()
			if (%!in-flight<run-id> // '') eq $run-id
				&& @held.elems == @ops.elems
				&& !@held.kv.map(-> $at, $op { $op === @ops[$at] }).first(!*);
	};
	Nil;
}

#|( The operations this run has in flight, in model order, or the empty
    list. Normally one — a group is one call unless a tool opted into
    C<concurrent-tools> — which is why both shims that read this were
    written against a single operation and still behave that way. )
method !in-flight-ops(Str:D $run-id --> List:D) {
	$!op-lock.protect: {
		(%!in-flight<run-id> // '') eq $run-id
			?? (%!in-flight<ops> // ()).List
			!! ();
	};
}

# The provenance snapshot for callbacks fired by a provider. The Run object
# and operations are captured atomically from the dispatch that installed
# them; no callback consults whichever run happens to be live later.
method !in-flight-context(--> Hash:D) {
	$!op-lock.protect: {
		%!in-flight<run> ~~ LLM::Agent::Run:D
			?? %( run => %!in-flight<run>, ops => (%!in-flight<ops> // ()).List )
			!! %();
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
		# Exempt tools are skipped BEFORE they are counted, not after: a
		# tool whose repetition is the protocol (see the Pod) must neither
		# trip the guard nor walk the batch's tally up under a call that
		# is not exempt.
		next if self!identical-exempt(call-tool-name($call));

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
	$run, @conversation, @ids, @attempts, Int:D $round,
	Int:D $context-tokens,
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
	#
	# ONE question, and the compactor owns it: over the trigger, or enough
	# reclaimable observation to be worth an aging epoch below it. Every
	# reason to make a pass lives in that predicate, so this line never has
	# to learn a second one.
	return %() unless $!compactor.needs-compaction(
		@conversation, tokens => $tokens + $context-tokens,
	);

	self!run-compaction($run, @conversation, @ids, @attempts, $round, $tokens);
}

#|( The compaction a chain of B<window refusals> forces, aimed at a number
    the compactor does not own: C<$target>, a complete-request ceiling
    paired with the selected backend counter — or, when a provider truncated
    the answer instead of the preflight catching it, a number small enough
    to be a different request even if the counter is wrong (see
    C<!length-verdict>).

    Returns an empty Hash when the round should be tried again — the
    conversation is smaller now — and a B<finish spec> when it should
    not. There are two of those, and both are C<context-exhausted>: no
    compactor at all (the honest end of a run whose conversation does not
    fit anything), and a compaction that ran and still could not get
    under the target. Both carry C<@attempts>: on the preflight path that
    is the skip records, and on the provider-length path it is the
    truncation that was paid for to discover this.

    This is what stops C<context-budget> being decorative. Before it, a
    loop with a budget and no compactor sent the doomed request anyway
    and let the provider explain. )
method !force-compaction(
	$run, @conversation, @ids, @attempts, Int:D $round, Int:D $target,
	LLM::Agent::TokenCount:D $counter, Str:D $model,
	--> Hash:D
) {
	return failure-spec(
		'LLM::Agent::Loop: the request does not fit any backend in the '
		~ 'chain and there is no compactor to make it smaller — the '
			~ 'complete request needs to be under ' ~ $target ~ " '$model' tokens "
			~ 'for the selected backend',
		@attempts, @conversation, $round, reason => 'context-exhausted',
	) unless $!compactor.defined;

	my Int $tokens = $counter.count-messages(@conversation);
	self!run-compaction(
		$run, @conversation, @ids, @attempts, $round, $tokens, $target,
		$counter,
	);
}

# One compaction, framed and applied: the events, the session line, the
# parallel id array, and the swap. Shared by the trigger-driven check at
# the top of a round and by the refusal-driven one between two round trips,
# so the two can never disagree about what a compaction does. @attempts is
# carried rather than used: the only thing it feeds is the terminal a
# compaction that cannot help produces, and a failure has to say what was
# tried before it.
method !run-compaction(
	$run, @conversation, @ids, @attempts, Int:D $round, Int:D $tokens,
	Int $target?, LLM::Agent::TokenCount $counter?,
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
		|($counter.defined ?? (:$counter) !! ()),
	);

	# NB the `// ()`: a compactor that predates elision — or a duck-typed one
	# — returns no such key, and `Any.elems` is 1.
	my @elisions = (%result<elisions> // ()).list;

	# The elisions go to the transcript FIRST, and against the ids the
	# compactor was handed: a stub rewrites a message that is still in the
	# conversation, so the line that names it has to be in the file before
	# any compaction line that replaces it. One is written even when the
	# compaction below folds those messages into a summary — the stubs are
	# what the summarizer was shown, and a transcript that says otherwise is
	# a transcript that cannot explain the summary it holds.
	self!record-elisions(@elisions, @ids);

	if %result<dropped> == 0 {
		# An ELISION-ONLY pass: nothing was replaced, so the ids do not move
		# and there is nothing to rebuild — but the conversation is not the
		# one that went in, and the working array has to say so.
		if @elisions.elems {
			@conversation.splice(0, @conversation.elems);
			@conversation.append: %result<messages>.list;
		}

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
		return exhausted-spec(%result, @attempts, @conversation, $round)
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
		?? exhausted-spec(%result, @attempts, @conversation, $round)
		!! %();
}

#|( One C<elision> line for the observations a compaction pass stubbed in
    place, translating the compactor's B<indices into the conversation> into
    the B<envelope ids> the transcript names them by — the same translation
    C<cut-index> gets on its way to a C<replaces-through-id>.

    Nothing at all without a session: a sessionless run's C<@ids> is a list
    of undefined placeholders (that is what C<!record> answers with nothing
    to append to), and nothing reads it. )
method !record-elisions(@elisions, @ids --> Nil) {
	# NB `with`, not an early return: a `--> Nil` signature refuses
	# `return Nil` outright ("no return arguments allowed").
	with $!session {
		.append-elision(items => @elisions.map(-> %elision {
			%( id => @ids[%elision<index>], stub => %elision<stub> );
		}).List) if @elisions.elems;
	}

	Nil;
}

#|( The finish spec of a run that has nowhere left to go: the compactor
    did everything it could and the conversation still will not fit the
    window. A terminal, not an exception — the caller gets a kept result
    with a C<reason> it can branch on, and a transcript that ends on the
    compaction rather than on half a request. )
my sub exhausted-spec(%result, @attempts, @conversation, Int:D $round
	--> Hash:D
) {
	failure-spec(
		'LLM::Agent::Loop: the conversation does not fit the context '
			~ 'budget even after compaction — ' ~ %result<tokens-after>
			~ ' tokens after compacting ' ~ %result<tokens-before>
			~ ', and everything that could be dropped has been. The sticky '
			~ 'prefix plus the recent window is bigger than the window: '
			~ 'either a single message is enormous, or keep-recent is too '
			~ 'large for this budget',
		@attempts, @conversation, $round, reason => 'context-exhausted',
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
#|( The tool name of a raw call as the model wrote it, or the empty string
    when there is nothing readable there. The limits run over calls rather
    than over C<ToolOperation>s — they are checked B<before> a single
    operation is built — so this is the name the exemption is matched
    against. )
my sub call-tool-name($call --> Str:D) {
	my $function = $call ~~ Associative ?? $call<function> !! Any;
	return '' unless $function ~~ Associative;
	$function<name> ~~ Str:D ?? $function<name> !! '';
}

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

#|( The messages a request really carries: the run context's head message
    (when it has one), the conversation, and the context's tail message
    (when it has one).

    B<This is a view, and it is built here and used in exactly one place.>
    The conversation is what the loop, the session and the compactor all
    reason about; the wire view exists for the length of one
    C<chat-completion-stream> call and is never stored. Request-budget
    counters receive the same conversation and context halves through
    C<count-request>, without making this transient array history. Without a
    context it B<is> the conversation. )
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

#|( What C<$backend> says it will generate at most, or an undefined Int
    when it does not say. Duck-typed exactly as
    C<< RequestBudget.reserve-for >> is: C<.settings.max_tokens> is a
    convention among the L<LLM::Chat> backends, not a contract. )
my sub completion-cap-of($backend --> Int) {
	my $max = try $backend.settings.max_tokens;
	($max.defined && $max ~~ Numeric && $max > 0) ?? $max.Int !! Int;
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
    C<provider-name> / C<cached-prompt-tokens> where a provider's Response
    subclass carries them (OpenRouter's does).

    Probed with C<.?>, the telemetry-payload idiom: a Response that never
    heard of C<cost> contributes no such key, and a test double needs
    only the accessors it cares to expose. Absent means "not reported",
    which is B<not> the same as zero — a run whose backends price nothing
    has no cost, rather than a cost of nothing. The same doctrine applies
    to C<cached-prompt-tokens>: it is a cache-hit SUBSET of
    C<prompt-tokens>, not an independent count, and a provider that
    doesn't report cache hits contributes no such key rather than a zero
    that would misleadingly claim "definitely no cache hit". )
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
	my $cached = $resp.?cached-prompt-tokens;
	%usage<cached-prompt-tokens> = $cached.Int if $cached.defined;

	%usage;
}

# The replay-visible extras of a committed assistant turn: what it was
# thinking, what it cost, and how the provider said it stopped.
#
# `finish-reason` is recorded on the COMMITTED turn on purpose: it is the
# provider's own account of why generation ended, and reading a
# transcript back is the only place a truncation nobody caught can still
# be seen. The clip gate in `!round-trip` means a turn that reached this
# point was not billed at the backend's cap — so a 'stop' here is a stop
# the numbers agree with.
my sub assistant-extras($resp --> Hash:D) {
	my %extra;
	%extra<reasoning> = $resp.reasoning-text if $resp.reasoning-text.defined;
	%extra<finish-reason> = $resp.finish-reason if $resp.finish-reason.defined;
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
