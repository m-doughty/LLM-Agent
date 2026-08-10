=begin pod

=head1 NAME

LLM::Agent::ToolOperation - one tool call, from "the model asked" to
"here is what we know about what happened"

=head1 SYNOPSIS

=begin code :lang<raku>

use LLM::Agent::ToolOperation;

my $op = LLM::Agent::ToolOperation.new(
    run-id      => $run.id,
    round       => 3,
    call-id     => 'call_1',                  # the model's tool_calls id
    tool        => 'fs_write',
    arguments   => canonical-arguments($raw), # the comparison key, not the wire text
    idempotency => 'destructive',
);

# The loop dispatches it, and — with a session — the `tool-dispatched`
# envelope's id becomes the operation's id.
$op.dispatch(op-id => $envelope-id);

# ...and settles it, exactly once, whatever came back.
$op.settle(outcome => 'completed', result-digest => data-digest($content));

say $op.state;             # 'completed'
say $op.duration;          # seconds between dispatch and settle

=end code

=head1 DESCRIPTION

A tool call is the only part of an agent round that B<changes the world>.
Everything else — a request, a stream, a summary — can be repeated,
retried or thrown away at no cost; C<fs_write> cannot. So a tool call is
the one thing the loop tracks as an B<operation> with a state of its own,
rather than as a value that either arrives or does not.

The point of the state machine is a single sentence: B<an operation whose
outcome we do not know must never be recorded as one that failed>. A
local deadline, a cancelled run, a killed process — none of those say
anything about whether the remote side effect happened. C<failed> is a
claim; C<outcome-unknown> is the truth.

=head2 The states

=begin table

State           | What it means
================|============================================================
proposed        | the model asked for it; nothing has been sent anywhere
dispatched      | the provider has it; it is running
completed       | it answered, and the answer was not an error
failed          | it answered, and the answer B<was> an error (or was refused)
outcome-unknown | we stopped waiting: it may or may not have taken effect
abandoned       | it was never dispatched, and is known B<not> to have run

=end table

Two of those are worth dwelling on.

C<abandoned> is only reachable from C<proposed>. It is the strongest
statement the loop can make about a tool call — "this did not happen" —
and it is only true of a call the provider was never handed. The moment
an operation is dispatched, the only honest terminals are what the
provider said (C<completed> / C<failed>) or C<outcome-unknown>.

C<outcome-unknown> is B<not> an error. A run that trips a tool deadline
carries on, and the model is told, in the tool message, that the result
is unknown rather than that the tool failed. Downgrading it to C<failed>
would let a model "retry" a C<fs_write> that had already landed.

=head2 authorized is data, not a state

The original design had an C<authorized> state between C<proposed> and
C<dispatched>. It is not here, deliberately.

The loop reaches a policy through the B<provider contract>, which never
throws: an C<MCP::Client::Policy> that allows a call simply runs it, and
one that denies it answers with an C<is_error> result. There is no moment
at which the loop is told "this was authorized" — for an allow-verdict
call there is nothing to observe at all. A state the machine cannot
observe is a state the machine would be lying about.

What the loop B<can> observe is a question being asked, because that
comes back through its own C<wrap-ask> shim. So an ask is recorded as
B<time>: C<ask-seconds> (and, while a human is still thinking, an open
span). That is what makes C<working-seconds> — and therefore the tool
deadline — pause for humans instead of punishing them. A denial arrives
as an C<is_error> result and settles as C<failed>.

=head2 Idempotency is a classification, not a promise

C<idempotency> is one of C<read-only>, C<idempotent>, C<destructive> or
C<unknown>, and it is B<configuration>: L<LLM::Agent::Loop>'s
C<idempotency-rules> map tool-name patterns onto these classes, exactly
as an C<MCP::Client::Policy> rule maps a pattern onto a decision. No MCP
server publishes anything of the sort — there is no annotation for it
anywhere in the protocol — so guessing from the name is the only thing
available, and the default is C<unknown>.

It is recorded so that a B<repair> can word itself honestly ("a
destructive operation may have taken effect"), and for nothing else. In
particular the loop B<never> retries an operation on the strength of it.

=head2 Ownership and durability

Instances are owned by the loop, one per call, for the length of a round.
They are B<not> the durable record — the session envelopes are
(C<tool-dispatched> / C<tool-settled>; see L<LLM::Agent::Session>) — and
after a resume the pending operations come back as plain hashes from
C<< $session.pending-tool-operations >> rather than as objects. This
class is what the live loop reasons with; the transcript is what survives
the process.

Every transition is B<lock-guarded and win-or-lose>: C<dispatch>,
C<settle> and C<abandon> return True for the caller that made the
transition and False for one that arrived too late, rather than throwing.
A deadline firing at the same instant as a result arriving is a race the
loop is allowed to lose, and it must lose it B<quietly>: whoever gets
there first decides what happened, and the other path checks the return
value and does nothing.

=head1 SEE ALSO

L<LLM::Agent::Loop> (dispatches and settles them), L<LLM::Agent::Session>
(the durable envelopes), L<LLM::Agent::Event> (C<ToolStarted>,
C<ToolProgress>, C<ToolAbandoned>).

=end pod

use UUID::V4;

use LLM::Agent::Canonical;

unit class LLM::Agent::ToolOperation;

#| The six states, as a set for anything validating one from the outside.
our constant STATES =
	<proposed dispatched completed failed outcome-unknown abandoned>.Set;

#| The three states an operation the provider was handed may settle in.
our constant SETTLED-OUTCOMES = <completed failed outcome-unknown>.Set;

#| The idempotency classes C<Loop.idempotency-rules> may name.
our constant IDEMPOTENCY-CLASSES =
	<read-only idempotent destructive unknown>.Set;

#| The model's C<tool_calls> id: the only authority on which call this is.
has Str:D $.call-id is required;

#| The tool the model asked for. Empty for a malformed call — which is a
#| call the provider refuses, not one this class gets to reject.
has Str:D $.tool is required;

#|( The arguments B<canonicalised> (see L<LLM::Agent::Canonical>), not the
    wire text: this is a comparison key, and key order and whitespace are
    not semantics. )
has Str:D $.arguments = '';

#| SHA-256 of C<arguments>. Derived unless supplied.
has Str $.arguments-digest;

#| C<read-only> / C<idempotent> / C<destructive> / C<unknown>.
has Str:D $.idempotency = 'unknown';

#| The run this belongs to, and the round within it.
has Str $.run-id;
has Int $.round;

#| When the model asked. Set at construction; never moves.
has Instant:D $.proposed-at = now;

# Everything below moves, and everything that touches it holds the lock.
# The lock is a strict leaf: nothing under it emits an event, writes a
# file or calls back into the loop.
has Lock:D $!lock .= new;

has Str $!op-id;
has Str $!state = 'proposed';
has Instant $!dispatched-at;
has Instant $!settled-at;
has Str $!reason;
has Str $!result-digest;
has %!artifact;
has Str $!error-text;

# Ask spans. `$!ask-depth` rather than a flag because a policy that
# elicits from a server while a permission prompt is open is a shape the
# protocol allows, and a span that closed on the inner answer would start
# charging the operation for the outer question.
has Real:D $!ask-seconds = 0;
has Int:D $!ask-depth = 0;
has Instant $!ask-open-at;

submethod TWEAK(Str :$op-id) {
	die 'LLM::Agent::ToolOperation: idempotency must be one of '
		~ IDEMPOTENCY-CLASSES.keys.sort.join(', ') ~ "; got '$!idempotency'"
		unless IDEMPOTENCY-CLASSES{$!idempotency};

	# An operation always has an id, from the moment it exists. With a
	# session it is REPLACED at dispatch by the `tool-dispatched` envelope's
	# id — which is what makes the transcript joinable — and without one
	# this uuid is all there ever is.
	$!op-id = ($op-id.defined && $op-id.chars) ?? $op-id.Str !! uuid-v4;
	$!arguments-digest //= data-digest($!arguments);
}

# === Identity ===

#|( This operation's id: the C<tool-dispatched> envelope's id once it has
    been dispatched into a session, and a uuid otherwise. )
method op-id(--> Str:D) { $!lock.protect: { $!op-id } }

#|( The identical-call signature: the tool name, a NUL, and the
    canonicalised arguments. The same key L<LLM::Agent::Loop> counts with,
    computed from the same two fields. )
method signature(--> Str:D) { $!tool ~ "\0" ~ $!arguments }

# === The state machine ===

#| One of C<STATES>.
method state(--> Str:D) { $!lock.protect: { $!state } }

#|( The terminal state, or an undefined Str while the operation is still
    C<proposed> or C<dispatched>. Same string as C<state> once it is one
    of the four terminals. )
method outcome(--> Str) {
	# NB no junction: `!($x eq 'a' | 'b')` autothreads into a junction that
	# is truthy either way, which is a memorably quiet way to break a
	# Bool-returning method.
	$!lock.protect: {
		($!state eq 'proposed' || $!state eq 'dispatched') ?? Str !! $!state;
	};
}

#| True once this operation has reached one of its four terminals.
method is-terminal(--> Bool:D) {
	$!lock.protect: {
		so !($!state eq 'proposed' || $!state eq 'dispatched');
	};
}

#| Why it settled the way it did: C<deadline>, C<cancelled>, ... Undefined
#| for the ordinary settles, which have nothing to add.
method reason(--> Str) { $!lock.protect: { $!reason } }

method dispatched-at(--> Instant) { $!lock.protect: { $!dispatched-at } }
method settled-at(--> Instant)    { $!lock.protect: { $!settled-at } }
method result-digest(--> Str)     { $!lock.protect: { $!result-digest } }
method error-text(--> Str)        { $!lock.protect: { $!error-text } }

#|( The artifact the full result was spilled to, when it was too big to
    live in the conversation: C<< { file, digest, bytes, chars,
    elided-chars } >>. Empty until L<LLM::Agent::Loop>'s artifact path
    fills it in. )
method artifact(--> Hash:D) { $!lock.protect: { %!artifact.Hash } }

#|( C<proposed> → C<dispatched>. Returns True for the caller that made the
    transition, False for one that finds the operation already dispatched
    or settled.

    C<:$op-id> replaces the operation's id, and is how the
    C<tool-dispatched> envelope's id becomes the operation's own. An
    undefined or empty one leaves the constructor's uuid in place, which
    is what a sessionless run gets. )
method dispatch(Str :$op-id --> Bool:D) {
	$!lock.protect: {
		if $!state eq 'proposed' {
			$!op-id = $op-id.Str if $op-id.defined && $op-id.chars;
			$!state = 'dispatched';
			$!dispatched-at = now;
			True;
		}
		else {
			False;
		}
	};
}

#|( C<dispatched> → C<completed> / C<failed> / C<outcome-unknown>. Returns
    True for the caller that settled it and False for one that arrived
    after — a deadline and a result racing each other is a race the loop
    is allowed to lose, and losing it must be quiet.

    Dies only on a settle that is not one of the three, or on settling an
    operation that was never dispatched: both are programming errors in
    the driver rather than things a provider can cause. )
method settle(
	Str:D :$outcome!,
	Str :$reason,
	Str :$result-digest,
	:%artifact,
	Str :$error-text,
	--> Bool:D
) {
	die 'LLM::Agent::ToolOperation.settle: outcome must be one of '
		~ SETTLED-OUTCOMES.keys.sort.join(', ') ~ "; got '$outcome'"
		unless SETTLED-OUTCOMES{$outcome};

	$!lock.protect: {
		if $!state eq 'dispatched' {
			$!state = $outcome;
			$!settled-at = now;
			$!reason = $reason if $reason.defined;
			$!result-digest = $result-digest if $result-digest.defined;
			%!artifact = %artifact.Hash if %artifact.elems;
			$!error-text = $error-text if $error-text.defined;
			self!close-ask;
			True;
		}
		elsif $!state eq 'proposed' {
			die 'LLM::Agent::ToolOperation.settle: '
				~ "operation {$!op-id} has not been dispatched — a call "
				~ 'nothing was handed cannot have an outcome; abandon it '
				~ 'instead';
		}
		else {
			False;
		}
	};
}

#|( C<proposed> → C<abandoned>: this call was B<never dispatched> and is
    known not to have run. Returns False on an operation that has been
    dispatched — that one may have taken effect, and saying otherwise is
    the one thing this class exists to prevent. )
method abandon(Str :$reason = 'cancelled' --> Bool:D) {
	$!lock.protect: {
		if $!state eq 'proposed' {
			$!state = 'abandoned';
			$!settled-at = now;
			$!reason = $reason if $reason.defined;
			True;
		}
		else {
			False;
		}
	};
}

# === Ask spans, and the clock the deadline reads ===

#|( A question has been put to a human about this operation. Nestable, and
    idempotent in the sense that matters: the span opens on the first
    C<ask-begin> and closes on the matching C<ask-end>. )
method ask-begin(--> Nil) {
	$!lock.protect: {
		$!ask-open-at = now if $!ask-depth == 0;
		$!ask-depth++;
	};
	Nil;
}

#| The answer came back. Adds the span to C<ask-seconds>.
method ask-end(--> Nil) {
	$!lock.protect: {
		if $!ask-depth > 0 {
			$!ask-depth--;
			self!close-ask if $!ask-depth == 0;
		}
	};
	Nil;
}

#| Seconds this operation spent waiting for a human, closed spans only.
method ask-seconds(--> Real:D) { $!lock.protect: { $!ask-seconds } }

#| True while a question about this operation is open.
method asking(--> Bool:D) { $!lock.protect: { $!ask-depth > 0 } }

#|( How long this operation has actually been B<working>: wall clock since
    dispatch, B<minus> every second spent waiting for a human — closed
    spans and the one that is still open.

    This is the clock C<Loop.tool-deadline> is measured against, and the
    subtraction is the whole point. A deadline that ran while a permission
    prompt sat on somebody's screen would abandon the call the moment they
    came back from lunch, having never let it start.

    0 for an operation that has not been dispatched; frozen at the settle
    for one that has finished. )
method working-seconds(--> Real:D) {
	$!lock.protect: {
		if $!dispatched-at.defined {
			my $end = $!settled-at // now;
			my $open = $!ask-open-at.defined ?? ($end - $!ask-open-at) !! 0;
			max(0, $end - $!dispatched-at - $!ask-seconds - $open);
		}
		else {
			0;
		}
	};
}

#|( Wall-clock seconds from dispatch to settle, asks included — what the
    tool really took. Undefined until both ends exist. )
method duration(--> Real) {
	$!lock.protect: {
		($!dispatched-at.defined && $!settled-at.defined)
			?? ($!settled-at - $!dispatched-at)
			!! Rat;
	};
}

# Close an open ask span into $!ask-seconds. MUST be called with the lock
# held; called both by ask-end and by settle, because an operation can be
# cancelled with the question still on screen.
method !close-ask(--> Nil) {
	with $!ask-open-at {
		$!ask-seconds += (($!settled-at // now) - $_);
		$!ask-open-at = Instant;
	}
	$!ask-depth = 0;
	Nil;
}

# === Plain data ===

#|( The operation as plain data — the same shape
    C<< $session.pending-tool-operations >> hands back for one that
    outlived its process, plus the live state. Undefined values are
    omitted, so it round-trips through C<to-json>. )
method to-hash(--> Hash:D) {
	$!lock.protect: {
		my %h =
			'op-id'            => $!op-id,
			'call-id'          => $!call-id,
			tool               => $!tool,
			arguments          => $!arguments,
			'arguments-digest' => $!arguments-digest,
			idempotency        => $!idempotency,
			state              => $!state,
			'proposed-at'      => iso($!proposed-at),
		;
		%h<run-id>        = $!run-id if $!run-id.defined;
		%h<round>         = $!round if $!round.defined;
		%h<dispatched-at> = iso($!dispatched-at) if $!dispatched-at.defined;
		%h<settled-at>    = iso($!settled-at) if $!settled-at.defined;
		%h<reason>        = $!reason if $!reason.defined;
		%h<result-digest> = $!result-digest if $!result-digest.defined;
		%h<error-text>    = $!error-text if $!error-text.defined;
		%h<artifact>      = %!artifact.Hash if %!artifact.elems;
		%h<ask-seconds>   = $!ask-seconds.Num if $!ask-seconds > 0;
		%h;
	};
}

method gist(--> Str:D) {
	$!lock.protect: {
		"LLM::Agent::ToolOperation<{$!op-id}> {$!tool} ({$!call-id}) "
			~ $!state ~ ($!reason.defined ?? "/{$!reason}" !! '');
	};
}

# The session envelope's timestamp format, so an operation rendered here
# and one read back out of a transcript are directly comparable.
my sub iso(Instant:D $instant --> Str:D) {
	DateTime.new($instant, :timezone(0)).Str;
}
