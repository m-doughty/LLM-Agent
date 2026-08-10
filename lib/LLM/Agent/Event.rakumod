=begin pod

=head1 NAME

LLM::Agent::Event - the typed events an agent run publishes

=head1 SYNOPSIS

=begin code :lang<raku>

use LLM::Agent::Event;

# One Supply, every kind of event. Dispatch on the class...
react whenever $run.events -> $event {
    given $event {
        when LLM::Agent::Event::Token       { print $event.text }
        when LLM::Agent::Event::ToolCall    { note "-> {$event.name}" }
        when LLM::Agent::Event::RunFailed   { note $event.error }
    }
}

# ...or on the stable kind string, which is what a transcript stores.
react whenever $run.events -> $event {
    $log-file.say: to-json($event.to-hash);
    last if $event.is-terminal;
}

=end code

=head1 DESCRIPTION

An agent run is a long, failure-prone, resumable thing, and every consumer
wants a different slice of it: a TUI wants tokens and tool calls, a logger
wants everything as plain data, a test wants the exact ordering, a metrics
sink wants only the attempt records. Rather than a hook per concern, a run
publishes B<one> C<Supply> of these objects and each consumer filters it.

Every event carries the moment it was created (C<.ts>, an C<Instant>), a
stable C<.kind> string, and knows how to flatten itself into plain data
(C<.to-hash>).

=head2 The envelope: run-id and seq

An event that has been published by a L<LLM::Agent::Run> also carries the
B<envelope> the Run stamped on it:

=begin table

Field  | What it is
=======|==========================================================
run-id | the id of the Run that published it
seq    | its position in that run's publication order, 0-based

=end table

Both are stamped B<at publication>, on a clone, inside the Run's one
critical section — so C<seq> is the total order of the run's events even
though a token stream, a tool thread, an asker and a server's log hook all
emit from threads of their own. It is contiguous (C<0 .. N> with no gaps),
and the terminal event is always the last one, C<N>.

What it is B<not> is a promise about which event is C<seq> 0: a log
notification from an MCP server can legitimately beat the driver's own
C<RunStarted> into the mailbox. Order is a fact about publication, not
about causality.

An event you built yourself and never handed to a Run has neither field,
and C<to-hash> omits both — which is why a hand-built event still
serialises exactly as it did before there was an envelope.

=head2 The attempt-framing contract

This is the part worth reading twice, because it is what makes a
mid-stream failure I<replayable> rather than corrupting.

A single round of the loop may talk to the backend several times: the
first attempt can die after streaming 400 tokens, and the retry starts
again from nothing. Those 400 tokens were already emitted as C<Token>
events, and they cannot be un-emitted — a Supply has no undo.

So the framing events are the contract:

=begin table

Event            | What a consumer must do
=================|=================================================
AttemptStarted   | open a fresh token scope; nothing before it belongs here
Token            | append to the CURRENT scope
AttemptFailed    | B<discard> every Token since the last AttemptStarted
AttemptSucceeded | commit the scope; the AssistantMessage that follows is authoritative

=end table

A consumer that ignores this renders a doubled reply the first time a
backend 500s halfway through a sentence. A consumer that honours it shows
the text rewinding, which is what actually happened. The
C<AssistantMessage> event that follows a success carries the committed
text, so a consumer that does not want live tokens at all can simply
ignore C<Token> and render only C<AssistantMessage>.

The transcript is never in doubt: only committed messages are written to
a session, so nothing a failed attempt streamed can ever be replayed as
if the model had said it.

=head2 Exactly one terminal

A run emits exactly one of C<RunCompleted>, C<RunFailed> or
C<RunCancelled>, and the Supply is C<done> immediately afterwards. The
Supply is B<never> C<quit>: a failure is data (a C<RunFailed> event and a
kept result Promise), not an exception thrown at whoever happened to be
tapping. C<$event.is-terminal> is the test; C<LLM::Agent::Event::TERMINAL-KINDS>
is the same answer for code working from C<kind> strings.

=head2 to-hash: plain data only

C<.to-hash> returns C<kind>, C<ts>, the envelope (C<run-id> and C<seq>,
when the event has been published), and the event's payload keys,
containing nothing but C<Str> / C<Int> / C<Num> / C<Rat> / C<Bool> /
C<Hash> / C<List> — it round-trips through C<to-json> unchanged, which is
what the JSONL transcript and any log sink need.

Two rules make that predictable:

=item B<C<ts> is an ISO-8601 UTC string> with microsecond precision
(C<2026-08-09T13:10:08.542283Z>), not a number. It matches the session
envelope's timestamp format exactly, so forwarding an event to a
transcript needs no conversion, and it stays readable when a human greps
the file. The original C<Instant> is still on the object as C<.ts> for
anyone doing arithmetic — C<$b.ts - $a.ts> is a C<Duration> in seconds.

=item B<Undefined payload values are omitted.> An C<AttemptFailed> from a
connection error has no C<error-status>, so the key is absent rather than
null, and a sink can use C<:exists> and C<.defined> interchangeably. The
exception is a key whose value is a container that is present but empty
(C<usage>, C<attempts>): those are always emitted, so "the provider
reported no usage" is an empty hash rather than a missing key.

=head2 Naming: why these are not C<is export>ed

The classes are plain global names under C<LLM::Agent::Event::>, declared
without C<is export> — exactly like C<LLM::Chat::Retry::Exceptions>, and
for the same reason. C<is export> on a nested-name class exports its
B<leaf> name too, so an C<is export>ed C<LLM::Agent::Event::Log> would
put a bare C<Log> into the importer's scope and collide with every other
module that has an opinion about what C<Log> means. C<use
LLM::Agent::Event;> here gives you the fully-qualified names and nothing
else.

=head1 THE TAXONOMY

Every row below also carries the two envelope fields C<run-id?> and
C<seq?> — see L</The envelope: run-id and seq> — so they are not repeated
per class.

=begin table

Class             | kind               | Payload
==================|====================|===================================================
RunStarted        | run-started        | message-count, context-digest?
RoundStarted      | round-started      | round, tokens?
AttemptStarted    | attempt-started    | round, attempt, backend-index, model
Token             | token              | text, round?, attempt?
AttemptFailed     | attempt-failed     | round, attempt, backend-index, model?, error, error-class?, error-status?, disposition, backoff?
AttemptSucceeded  | attempt-succeeded  | round, attempt, backend-index, model-used?, finish-reason?, usage, latency-ms?
AssistantMessage  | assistant-message  | message, reasoning?, round?
TurnCommitted     | turn-committed     | message-id?, round?
ToolCall          | tool-call          | id, name, arguments?, round?
ToolStarted       | tool-started       | id, name, round?
ToolProgress      | tool-progress      | id, progress, total?, message?, round?
ToolResult        | tool-result        | id, name?, content, is-error, artifact?, round?
ToolAbandoned     | tool-abandoned     | id, name, reason, dispatched, round?
Subagent          | subagent           | agent-id, agent-type, label?, inner
AskPending        | ask-pending        | request, tool?
AskAnswered       | ask-answered       | request, answer?
Log               | log                | level, logger?, data
LimitReached      | limit-reached      | limit, count?, max?
TurnDiscarded     | turn-discarded     | reason, round?
CompactionStarted | compaction-started | tokens-before?, budget?, message-count?, round?
CompactionDone    | compaction-done    | tokens-before?, tokens-after?, dropped?, summary?, fallback, round?
RunCompleted      | run-completed      | final, rounds?, message-count?
RunFailed         | run-failed         | error, attempts, round?, reason?
RunCancelled      | run-cancelled      | stage?, round?

=end table

A C<?> marks an optional attribute — one whose key is absent from
C<to-hash> when it was not supplied.

=head2 Turns: committed, and discarded

C<AttemptSucceeded> says B<the transport worked>. It does not say the
model's turn is part of the conversation, and the two really do come
apart: a turn that asks for tools when a limit has been reached is
discarded whole (see L<LLM::Agent::Loop>), tokens and all.

So a turn ends in exactly one of two events:

=item B<C<TurnCommitted>> — beside the C<AssistantMessage>, carrying the
B<session envelope id> of the committed message. That id is the join key
between the conversation and the C<tool-dispatched> envelopes that follow
it, which is why it is worth an event of its own; C<AssistantMessage>
keeps the payload and the commit role it has always had.

=item B<C<TurnDiscarded>> — every streamed scope that will never be
followed by an C<AssistantMessage>: a limit discarded it (C<reason =>
'limit'>), the backend chain ran out (C<'failed'>), or the run was
cancelled mid-flight (C<'cancelled'>).

The invariant a consumer may rely on: B<an C<AttemptSucceeded> that is
never followed by an C<AssistantMessage> in the same round is always
followed by a C<TurnDiscarded>>. A UI that renders streamed text can
therefore always retract it on a signal rather than leaving it on screen
until the next turn overwrites it.

=head2 A tool call, event by event

Five events frame one tool call, and they answer five different
questions:

=begin table

Event         | The question it answers
==============|===========================================================
ToolCall      | what did the model ask for? (it is proposed)
ToolStarted   | it has been handed to the provider (it is dispatched)
ToolProgress  | it is still running, and here is how far
ToolResult    | it answered — with a result, or with an error
ToolAbandoned | it will not answer; here is what we know about whether it ran

=end table

C<ToolResult>'s C<content> is B<what the model was given>, which for a
result bigger than C<< request-budget.max-observation-size >> is an
excerpt rather than the whole thing — the same excerpt that went into the
conversation and the transcript, with the full bytes in the file
C<artifact> names. A consumer rendering a tool result is therefore
rendering exactly what the model saw, and C<artifact> is how it offers to
show the rest. See L<LLM::Agent::Artifacts>.

C<ToolAbandoned> is the one to read twice. C<< dispatched => False >>
means the call was B<never handed to the provider> and is known not to
have run. C<< dispatched => True >> means it was, and then the loop
stopped waiting — the outcome is genuinely B<unknown>, not failed.
Nothing invents a C<ToolResult> for either case: a result event would
tell a consumer the tool answered, and it did not.

C<round> is 1-based. C<attempt> is 1-based B<within a round> and counts
across backends: attempt 3 may be the first attempt against the second
backend. C<disposition> is one of C<retry-same>, C<advance> or C<abort> —
the buckets of L<LLM::Chat::Retry>'s C<classify-error>. C<reason> is the
named-failure key described on C<RunFailed>, and is present only for the
failures that have a name.

=head2 Subagent: a child run's event, carried on the parent's stream

A run that spawns another run (L<LLM::Agent::Subagents>) has two event
streams to reconcile, and merging them naively would be a disaster: two
runs' C<seq> numbers interleaved in one order, two C<RunCompleted>s on a
Supply that promises exactly one terminal, a consumer unable to tell
whose C<Token> it is rendering.

So a child's events are not merged — they are B<wrapped>. Each one is
flattened with C<.to-hash> and carried as the C<inner> payload of a
C<Subagent> event published on the B<parent's> stream, which stamps it
with the parent's C<run-id> and the next parent C<seq> like any other
event. Nothing about the parent's envelope contract moves:

=begin table

Layer   | run-id / seq            | kind
========|=========================|=====================================
outer   | the PARENT's            | always C<subagent>, never terminal
inner   | the CHILD's, as stamped | whatever the child emitted

=end table

C<inner> is plain data, not an C<Event> object — it has already been
through C<to-hash>, so a C<Subagent> event serialises to JSON in one
step like every other event, and a consumer reads C<< $e.inner<kind> >>
to dispatch on what the child did.

Two consequences worth stating out loud. A C<Subagent> whose
C<< inner<kind> >> is C<run-completed> is B<not> terminal: the child
ended, the parent did not, and C<is-terminal> stays False so a consumer
that stops tapping on a terminal does not stop halfway through the
parent's run. And C<agent-id> — not the inner C<run-id> — is the key to
group by when several children are running at once: it is short, it is
what the transcript's C<subagent-spawned> envelope records, and it is
stable across a child that had to be restarted.

=head1 SEE ALSO

L<LLM::Agent::Run> (the handle that carries the Supply), L<LLM::Chat::Retry>
(where C<disposition> comes from).

=end pod

use LLM::Chat::Conversation::Message;

# The three constraint types below are deliberately `my`-scoped. A bare
# `subset` is our-scoped, and at file scope that means GLOBAL — which is
# exactly the leaf-name pollution the module Pod explains this file goes
# out of its way to avoid. They exist to type attributes, not to be named
# by importers.

#| One of the three C<classify-error> buckets, as recorded on an
#| AttemptFailed: what the loop decided to do about the failure.
my subset AgentDisposition of Str where * eq any('retry-same', 'advance', 'abort');

#| A log payload: free text, or the structured record a server sent.
my subset AgentLogData where { $_ ~~ Str || $_ ~~ Associative };

#| Tool-call arguments as they arrived: the JSON string most APIs send, or
#| an already-decoded Hash. Undefined for a call that takes none.
my subset AgentToolArgs where { !.defined || $_ ~~ Str || $_ ~~ Associative };

#| Why a streamed assistant turn was thrown away rather than committed.
my subset AgentDiscardReason of Str where * eq any('limit', 'failed', 'cancelled');

#| Why a tool call will never answer. See ToolAbandoned: this says why the
#| loop stopped, and C<dispatched> says whether the call can have run.
my subset AgentAbandonReason of Str
	where * eq any('cancelled', 'deadline', 'budget-exhausted');

#|( The base of the taxonomy. Never emitted itself: C<kind> is a stub, so
    an event class that forgot to declare one fails loudly the first time
    anybody asks. )
class LLM::Agent::Event {
	#| When the event was created, on the emitting thread. Subtracting two
	#| gives a Duration in seconds.
	has Instant:D $.ts = now;

	#|( The Run that published this event, stamped by it. Undefined on an
	    event that was built by hand and never emitted. )
	has Str $.run-id;

	#|( Position in the publishing Run's total order: 0-based, contiguous,
	    terminal last. Stamped by the Run at publication, so it orders
	    events from every thread that emitted into the run — see the
	    envelope section of the module Pod. Undefined until published. )
	has Int $.seq;

	#| The kinds that end a run. Exactly one of these is emitted per run,
	#| and the Supply is done straight afterwards.
	our constant TERMINAL-KINDS = <run-completed run-failed run-cancelled>.Set;

	#| The stable wire name of this event class. Stable means: persisted in
	#| transcripts, matched by consumers that never load this module, and
	#| therefore not renameable without a format version bump.
	method kind(--> Str:D) { ... }

	#| True for RunCompleted / RunFailed / RunCancelled and nothing else.
	method is-terminal(--> Bool:D) { False }

	#| This event's own keys, before C<to-hash> drops the undefined ones.
	#| Overridden by every subclass; the base contributes nothing.
	method payload(--> Hash:D) { {} }

	#| C<.ts> as an ISO-8601 UTC string with microsecond precision — the
	#| same format the session envelope stamps its lines with.
	method ts-iso(--> Str:D) { DateTime.new($!ts, :timezone(0)).Str }

	#|( The event as plain data: C<kind>, C<ts> (ISO-8601 UTC), the
	    envelope (C<run-id> / C<seq>, when it has been published) and the
	    payload keys, with undefined values omitted. Nothing but strings,
	    numbers, booleans, hashes and lists comes out, so the result can go
	    straight into C<to-json>. )
	method to-hash(--> Hash:D) {
		my %h = kind => self.kind, ts => self.ts-iso;
		%h<run-id> = $!run-id if $!run-id.defined;
		%h<seq>    = $!seq    if $!seq.defined;
		for self.payload.pairs -> $pair {
			%h{$pair.key} = $pair.value if $pair.value.defined;
		}
		%h;
	}

	method gist(--> Str:D) {
		my %p = self.payload;
		my $detail = %p.keys.sort.grep({ %p{$_}.defined })
			.map({ "$_={%p{$_}.gist}" }).join(' ');
		"[{self.kind}]{$detail ?? ' ' ~ $detail !! ''}";
	}
}

#|( The run has started: the driver's own first event, emitted exactly
    once.

    It has no C<run-id> attribute of its own — that is the envelope's, on
    the base class, and a second one here would shadow it so that
    C<< .new(run-id => ...) >> filled one and the Run stamped the other.
    The driver still has to supply it (a C<RunStarted> that cannot say
    which run started is useless in a shared log), which is what the
    TWEAK below enforces. )
class LLM::Agent::Event::RunStarted is LLM::Agent::Event {
	#| How many messages the caller handed in.
	has Int:D $.message-count is required;

	#|( The digest of the L<LLM::Agent::RunContext> this run was given, or
	    an undefined Str for a run that was given none. The B<key is
	    absent> in that case rather than present and null: a run with no
	    context and a run whose context is empty are different facts.

	    Note it is not counted in C<message-count>. The context is
	    rendered into the request and never into the conversation, so the
	    count is of history and the digest is of everything else. )
	has Str $.context-digest;

	submethod TWEAK {
		die 'LLM::Agent::Event::RunStarted: run-id is required — it is the '
			~ 'only thing that tells two interleaved runs apart in a shared '
			~ 'log'
			unless self.run-id.defined;
	}

	method kind(--> Str:D) { 'run-started' }
	method payload(--> Hash:D) {
		my %payload = message-count => $!message-count;
		%payload<context-digest> = $!context-digest if $!context-digest.defined;
		%payload;
	}
}

#| A new round of the loop: one model turn plus the tool calls it asks for.
class LLM::Agent::Event::RoundStarted is LLM::Agent::Event {
	#| 1-based.
	has Int:D $.round is required;
	#| The counter's estimate of the conversation size at the top of the
	#| round, after any compaction. Optional: a loop without a budget has
	#| no reason to count.
	has Int $.tokens;

	method kind(--> Str:D) { 'round-started' }
	method payload(--> Hash:D) { { round => $!round, tokens => $!tokens } }
}

#|( A call to a backend is about to start. B<Opens a token scope> — see
    the attempt-framing contract in the module Pod. )
class LLM::Agent::Event::AttemptStarted is LLM::Agent::Event {
	has Int:D $.round is required;
	#| 1-based within the round, counting across backends: attempt 3 may
	#| be the first attempt against the second backend.
	has Int:D $.attempt is required;
	#| Position of this backend in the fallback chain, 0-based.
	has Int:D $.backend-index is required;
	#| What the backend calls its model, or 'unknown' for a backend that
	#| does not say.
	has Str:D $.model is required;

	method kind(--> Str:D) { 'attempt-started' }
	method payload(--> Hash:D) {
		{
			round => $!round, attempt => $!attempt,
			backend-index => $!backend-index, model => $!model,
		};
	}
}

#|( One streamed fragment of assistant text. The highest-frequency event
    by far, and the only one a consumer may have to throw away: it belongs
    to the most recent AttemptStarted, and an AttemptFailed retracts every
    Token since. )
class LLM::Agent::Event::Token is LLM::Agent::Event {
	#| The fragment, exactly as the backend sent it. Not trimmed, not
	#| joined — concatenating every Token of a committed attempt
	#| reproduces the assistant's text.
	has Str:D $.text is required;
	#| Which scope this belongs to. Redundant with the framing events, and
	#| supplied as a convenience for consumers that filter rather than
	#| follow the stream in order.
	has Int $.round;
	has Int $.attempt;

	method kind(--> Str:D) { 'token' }
	method payload(--> Hash:D) {
		{ text => $!text, round => $!round, attempt => $!attempt };
	}
}

#|( A backend attempt failed. B<Retracts> every Token since the matching
    AttemptStarted. C<disposition> says what the loop is about to do:
    C<retry-same> (after C<backoff> seconds, same backend), C<advance>
    (next backend, no wait) or C<abort> (the chain stops; a RunFailed
    follows immediately). )
class LLM::Agent::Event::AttemptFailed is LLM::Agent::Event {
	has Int:D $.round is required;
	has Int:D $.attempt is required;
	has Int:D $.backend-index is required;
	has Str $.model;
	#| The failure, already prefixed with the backend it came from.
	has Str:D $.error is required;
	#| The Response's structured error shape, when it had one: 'http',
	#| 'timeout', 'connection', 'response', 'unknown'.
	has Str $.error-class;
	#| Only meaningful when C<error-class> is 'http'.
	has Int $.error-status;
	has AgentDisposition:D $.disposition is required;
	#| Seconds the loop will sleep before retrying. Present only for
	#| C<retry-same> — an advance does not wait.
	has Num $.backoff;

	method kind(--> Str:D) { 'attempt-failed' }
	method payload(--> Hash:D) {
		{
			round => $!round, attempt => $!attempt,
			backend-index => $!backend-index, model => $!model,
			error => $!error, error-class => $!error-class,
			error-status => $!error-status, disposition => $!disposition,
			backoff => $!backoff,
		};
	}
}

#|( A backend attempt finished cleanly. B<Commits> the token scope; the
    AssistantMessage that follows carries the same text as a whole. )
class LLM::Agent::Event::AttemptSucceeded is LLM::Agent::Event {
	has Int:D $.round is required;
	has Int:D $.attempt is required;
	has Int:D $.backend-index is required;
	#| The model the provider says actually served the request, which on
	#| an aggregator is not always the one that was asked for.
	has Str $.model-used;
	#| 'stop', 'tool_calls', 'length', ... as the provider reported it.
	has Str $.finish-reason;
	#| C<prompt-tokens> / C<completion-tokens> / C<total-tokens> as far as
	#| the provider reported them. B<Empty> — not absent — when it
	#| reported nothing, so "zero" and "unknown" stay distinguishable.
	has %.usage;
	#| Wall-clock time from AttemptStarted to here.
	has Int $.latency-ms;

	method kind(--> Str:D) { 'attempt-succeeded' }
	method payload(--> Hash:D) {
		{
			round => $!round, attempt => $!attempt,
			backend-index => $!backend-index, model-used => $!model-used,
			finish-reason => $!finish-reason, usage => %!usage.Hash,
			latency-ms => $!latency-ms,
		};
	}
}

#|( The committed assistant turn: the message that was appended to the
    conversation and written to the transcript. A consumer that ignores
    Token events entirely can render a whole run from these. )
class LLM::Agent::Event::AssistantMessage is LLM::Agent::Event {
	has LLM::Chat::Conversation::Message:D $.message is required;
	#| The thinking trace, for models that emit one. Kept out of the
	#| Message because it is not part of what gets sent back to the model.
	has Str $.reasoning;
	has Int $.round;

	method kind(--> Str:D) { 'assistant-message' }
	method payload(--> Hash:D) {
		{
			message => $!message.to-hash, reasoning => $!reasoning,
			round => $!round,
		};
	}
}

#|( The assistant turn is B<part of the conversation now>: it has been
    appended and, when there is a session, written to it.

    The identity-only complement to C<AssistantMessage>, which carries the
    content. What this adds is C<message-id> — the session envelope's id —
    which is the key that joins the committed turn to the
    C<tool-dispatched> envelopes of the calls it asked for. A sessionless
    run has no such id, and the key is simply absent. )
class LLM::Agent::Event::TurnCommitted is LLM::Agent::Event {
	#| The session envelope id of the committed assistant message.
	#| Undefined — and absent from C<to-hash> — on a sessionless run.
	has Str $.message-id;
	has Int $.round;

	method kind(--> Str:D) { 'turn-committed' }
	method payload(--> Hash:D) {
		{ message-id => $!message-id, round => $!round };
	}
}

#|( The assistant turn that was streamed in this round B<is not> part of
    the conversation: nothing was committed, nothing was written to the
    session, and no C<AssistantMessage> is coming.

    A consumer that renders live tokens must retract them here. See the
    module Pod: every C<AttemptSucceeded> with no C<AssistantMessage>
    after it in the same round is followed by one of these. )
class LLM::Agent::Event::TurnDiscarded is LLM::Agent::Event {
	#| Why the turn was thrown away: C<limit> (it asked for tools a limit
	#| had already stopped), C<failed> (the backend chain ran out) or
	#| C<cancelled> (the run was cancelled before it could be committed).
	has AgentDiscardReason:D $.reason is required;
	has Int $.round;

	method kind(--> Str:D) { 'turn-discarded' }
	method payload(--> Hash:D) { { reason => $!reason, round => $!round } }
}

#| A tool call the model asked for, emitted before it is executed.
class LLM::Agent::Event::ToolCall is LLM::Agent::Event {
	#| The provider's call id; the matching ToolResult carries the same one.
	has Str:D $.id is required;
	has Str:D $.name is required;
	has AgentToolArgs $.arguments;
	has Int $.round;

	method kind(--> Str:D) { 'tool-call' }
	method payload(--> Hash:D) {
		{
			id => $!id, name => $!name, arguments => $!arguments,
			round => $!round,
		};
	}
}

#|( The call has been B<handed to the provider> and is running: the
    dispatch boundary, one per call, emitted immediately after the
    C<tool-dispatched> envelope is written and before the provider is
    called.

    C<ToolCall> stays "the model asked for this"; this is "and now it is
    really happening". A UI that shows a spinner starts it here — a call
    that is queued behind three others has not started yet, and saying it
    has is how a hung tool becomes indistinguishable from a busy one. )
class LLM::Agent::Event::ToolStarted is LLM::Agent::Event {
	#| Matches the ToolCall's id.
	has Str:D $.id is required;
	has Str:D $.name is required;
	has Int $.round;

	method kind(--> Str:D) { 'tool-started' }
	method payload(--> Hash:D) {
		{ id => $!id, name => $!name, round => $!round };
	}
}

#|( A running tool said how far it has got: an MCP C<notifications/progress>
    forwarded through the loop's C<progress-hook>, correlated to the call
    it belongs to.

    C<progress> and C<total> are the protocol's own numbers — C<total> is
    optional there and optional here, so a server that reports "17 files"
    with no idea how many there are in total is representable. Progress
    for a call that is B<not> the one in flight is dropped rather than
    reported: a late notification from a previous call would move the
    wrong bar. )
class LLM::Agent::Event::ToolProgress is LLM::Agent::Event {
	#| Matches the ToolCall's id.
	has Str:D $.id is required;
	#| How far it has got, in whatever unit the server chose.
	has Num:D $.progress is required;
	#| What it is counting towards, when the server knows.
	has Num $.total;
	#| A human-readable note from the server.
	has Str $.message;
	has Int $.round;

	method kind(--> Str:D) { 'tool-progress' }
	method payload(--> Hash:D) {
		{
			id => $!id, progress => $!progress, total => $!total,
			message => $!message, round => $!round,
		};
	}
}

#|( What a tool call came back with. Always emitted for an executed call,
    including a refused or failed one — the provider stack never throws,
    it answers with C<is-error>. )
class LLM::Agent::Event::ToolResult is LLM::Agent::Event {
	#| Matches the ToolCall's id.
	has Str:D $.id is required;
	has Str $.name;
	#|( What the model will see as the tool message's content — which for
	    an oversized result is the B<excerpt>, not the whole thing. See
	    C<artifact>. )
	has Str:D $.content is required;
	has Bool:D $.is-error = False;
	#|( Present only when the result was too big to live in the
	    conversation and was spilled to a file:
	    C<< { file, digest, bytes, chars, elided-chars } >>, where C<file>
	    is a basename in the transcript's C<.artifacts> directory. Empty —
	    and dropped from C<to-hash> — for the ordinary result, which is
	    almost all of them. See L<LLM::Agent::Artifacts>. )
	has %.artifact;
	has Int $.round;

	method kind(--> Str:D) { 'tool-result' }
	method payload(--> Hash:D) {
		{
			id => $!id, name => $!name, content => $!content,
			is-error => $!is-error, round => $!round,
			artifact => (%!artifact.elems ?? %!artifact.Hash !! Any),
		};
	}
}

#|( A tool call will never answer, and this is what is known about whether
    it ran. B<Not> a C<ToolResult>: nothing came back, and inventing one
    would tell a consumer the tool answered.

    C<dispatched> is the whole message. B<False> means it was never handed
    to the provider: it did not run, which is the strongest thing the loop
    can say about a tool call and is only ever true of one that was still
    queued. B<True> means it was handed over and the loop then stopped
    waiting (the deadline passed, or the run was cancelled), so whether it
    took effect is B<unknown> — and a consumer that renders that as a
    failure is inviting somebody to retry a write that already landed.

    The matching conversation message says the same thing in words, so the
    model is not told a tool failed either. )
class LLM::Agent::Event::ToolAbandoned is LLM::Agent::Event {
	#| Matches the ToolCall's id.
	has Str:D $.id is required;
	has Str:D $.name is required;
	#| C<cancelled> (the run was cancelled), C<deadline> (it outlived
	#| C<Loop.tool-deadline>) or C<budget-exhausted> (a run cap tripped
	#| before this call was dispatched).
	has AgentAbandonReason:D $.reason is required;
	#| False: never dispatched, so it did not run. True: dispatched and
	#| detached, so the outcome is unknown.
	has Bool:D $.dispatched is required;
	has Int $.round;

	method kind(--> Str:D) { 'tool-abandoned' }
	method payload(--> Hash:D) {
		{
			id => $!id, name => $!name, reason => $!reason,
			dispatched => $!dispatched, round => $!round,
		};
	}
}

#|( One event of a B<child> run, carried on its parent's stream. NOT
    terminal, whatever the child's event was: the child ending is not the
    parent ending. See the module Pod for the two-layer envelope.

    C<inner> is the child event's C<to-hash> — plain data, carrying the
    B<child's> C<run-id>, C<seq> and C<kind> — and the wrapper itself is
    stamped with the parent's when the parent Run publishes it. )
class LLM::Agent::Event::Subagent is LLM::Agent::Event {
	#| The spawning composer's short handle for this child, and the key to
	#| group by: the same one its C<subagent-spawned> envelope records.
	has Str:D $.agent-id is required;
	#| Which agent from the composer's table this is: 'reviewer', 'tester'.
	has Str:D $.agent-type is required;
	#| What the model called this particular child, when it named one.
	has Str $.label;
	#|( The child event, flattened. Required, and required to be a Hash: a
	    wrapper with nothing inside says a child emitted something without
	    saying what, which is worse than no event at all. )
	has %.inner is required;

	method kind(--> Str:D) { 'subagent' }
	method payload(--> Hash:D) {
		{
			agent-id => $!agent-id, agent-type => $!agent-type,
			label => $!label, inner => %!inner.Hash,
		};
	}
}

#|( A question is waiting on a human — a permission prompt or a server
    elicitation forwarded by a policy. The run is B<blocked> until it is
    answered; there is no timeout unless the asker imposes one.

    Note for transcript writers: the request may contain whatever the
    model was about to do with the user's files. A session deliberately
    stores only the resulting grants, not the questions. )
class LLM::Agent::Event::AskPending is LLM::Agent::Event {
	#| The ask hash as the policy built it — C<kind> is 'permission' or
	#| 'server-elicit'; see MCP::Client::Policy for the two shapes.
	has %.request is required;
	#| The tool being asked about, when it is a permission question.
	has Str $.tool;

	method kind(--> Str:D) { 'ask-pending' }
	method payload(--> Hash:D) {
		{ request => %!request.Hash, tool => $!tool };
	}
}

#| The answer came back, and the run is unblocked.
class LLM::Agent::Event::AskAnswered is LLM::Agent::Event {
	has %.request is required;
	#| Whatever the asker returned. Normally the C<< { action => ... } >>
	#| hash, but a badly-behaved UI can return anything, and this event
	#| reports what really happened rather than what should have.
	has $.answer;

	method kind(--> Str:D) { 'ask-answered' }
	method payload(--> Hash:D) {
		{
			request => %!request.Hash,
			answer => ($!answer ~~ Associative
				?? $!answer.Hash
				!! ($!answer.defined ?? $!answer.Str !! Str)),
		};
	}
}

#|( A log line from somewhere inside the run — typically an MCP server's
    C<notifications/message>, forwarded by the loop's log hook. )
class LLM::Agent::Event::Log is LLM::Agent::Event {
	#| The syslog-ish level the sender used: 'debug', 'info', 'warning',
	#| 'error', ...
	has Str:D $.level is required;
	#| Who sent it, when the sender said.
	has Str $.logger;
	#| Free text or a structured record — nothing else. A sender that
	#| offers anything else is a bug worth failing on rather than
	#| stringifying into a transcript.
	has AgentLogData $.data is required;

	method kind(--> Str:D) { 'log' }
	method payload(--> Hash:D) {
		{
			level => $!level, logger => $!logger,
			data => ($!data ~~ Associative ?? $!data.Hash !! $!data),
		};
	}
}

#|( A configured limit stopped the loop from going further. The run does
    not end here: the loop tells the model its tools are gone and gives it
    one last round to answer with what it has. )
class LLM::Agent::Event::LimitReached is LLM::Agent::Event {
	#| Which limit: 'tool-rounds', 'tool-calls' or 'identical-calls'.
	has Str:D $.limit is required;
	#| What was counted.
	has Int $.count;
	#| What it was allowed to be.
	has Int $.max;

	method kind(--> Str:D) { 'limit-reached' }
	method payload(--> Hash:D) {
		{ limit => $!limit, count => $!count, max => $!max };
	}
}

#| Compaction is starting: the conversation has outgrown its budget.
class LLM::Agent::Event::CompactionStarted is LLM::Agent::Event {
	has Int $.tokens-before;
	has Int $.budget;
	has Int $.message-count;
	has Int $.round;

	method kind(--> Str:D) { 'compaction-started' }
	method payload(--> Hash:D) {
		{
			tokens-before => $!tokens-before, budget => $!budget,
			message-count => $!message-count, round => $!round,
		};
	}
}

#|( Compaction finished. C<fallback> is the one to watch: True means the
    summarizing model could not be reached and the middle of the
    conversation was hard-trimmed instead, so context was lost rather than
    condensed. The loop makes progress either way. )
class LLM::Agent::Event::CompactionDone is LLM::Agent::Event {
	has Int $.tokens-before;
	has Int $.tokens-after;
	#| How many messages the compaction replaced.
	has Int $.dropped;
	#| The summary that replaced them. Absent for a hard trim.
	has Str $.summary;
	has Bool:D $.fallback = False;
	has Int $.round;

	method kind(--> Str:D) { 'compaction-done' }
	method payload(--> Hash:D) {
		{
			tokens-before => $!tokens-before, tokens-after => $!tokens-after,
			dropped => $!dropped, summary => $!summary,
			fallback => $!fallback, round => $!round,
		};
	}
}

#| TERMINAL. The model answered and asked for no more tools.
class LLM::Agent::Event::RunCompleted is LLM::Agent::Event {
	#| The final assistant text.
	has Str:D $.final = '';
	has Int $.rounds;
	#| Size of the conversation the run ended with.
	has Int $.message-count;

	method kind(--> Str:D) { 'run-completed' }
	method is-terminal(--> Bool:D) { True }
	method payload(--> Hash:D) {
		{
			final => $!final, rounds => $!rounds,
			message-count => $!message-count,
		};
	}
}

#|( TERMINAL. Every backend in the chain failed, or one of them failed in
    a way that means trying again is pointless. C<attempts> is the record
    of what was tried — the same shape L<LLM::Chat::Retry>'s
    C<attempt-record> builds, and the same list an
    C<X::LLM::Chat::Retry::Exhausted> would have carried. )
class LLM::Agent::Event::RunFailed is LLM::Agent::Event {
	has Str:D $.error is required;
	#| C<< { backend-index, model, error, raw-text? } >> per attempt.
	#| B<Empty> — not absent — for a failure that never got as far as
	#| calling a backend.
	has @.attempts;
	has Int $.round;
	#|( The machine-readable half of C<error>, for the failures a program
	    can do something about. Absent for the ordinary ones — a caller
	    branching on it is branching on a case somebody deliberately named.

	    Two are named so far. C<context-exhausted>: the conversation will
	    not fit the context window — either compaction ran out of things
	    to drop, or every backend's preflight refused it and compacting to
	    the roomiest one's window did not help. C<budget-exhausted>: a run
	    cap (cost, total tokens or wall clock) was reached; C<error> names
	    which one, what was spent and what the cap was. Both are the loop
	    stopping B<cleanly> rather than sending a request it knows will
	    fail or spending money somebody said not to. )
	has Str $.reason;

	method kind(--> Str:D) { 'run-failed' }
	method is-terminal(--> Bool:D) { True }
	method payload(--> Hash:D) {
		{
			error => $!error, attempts => @!attempts.List, round => $!round,
			reason => $!reason,
		};
	}
}

#|( TERMINAL. The caller cancelled. Nothing is emitted after this — that
    is the promise C<Run.cancel> makes — so a consumer can stop tapping
    the moment it arrives. )
class LLM::Agent::Event::RunCancelled is LLM::Agent::Event {
	#| Where the run was when it noticed: 'streaming', 'backoff',
	#| 'tools', 'compaction', 'start'. Advisory; useful in a log.
	has Str $.stage;
	has Int $.round;

	method kind(--> Str:D) { 'run-cancelled' }
	method is-terminal(--> Bool:D) { True }
	method payload(--> Hash:D) { { stage => $!stage, round => $!round } }
}
