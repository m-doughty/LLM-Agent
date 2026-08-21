=begin pod

=head1 NAME

LLM::Agent::CompletionBus - the outstanding background work a run will not
end without, and the turns it comes back as

=head1 SYNOPSIS

=begin code :lang<raku>

use LLM::Agent::CompletionBus;

# One bus per conversation, not per run: a child that settles after its
# parent run ended is delivered to the NEXT run of the same conversation.
my $bus = LLM::Agent::CompletionBus.new(max-outstanding => 16);

my $loop = LLM::Agent::Loop.new(
    :@backends, provider => $subagents, completion-bus => $bus,
);

# ...from a composer, when a background operation starts:
my %admitted = $bus.open('reviewer-1', kind => 'subagent',
    label => 'review billing/');
# %admitted<ok> is False when the bus is already at max-outstanding, and
# %admitted<outstanding> / %admitted<max> are what the refusal says.

# ...and when it finishes, from whatever thread noticed:
$bus.settle('reviewer-1', deliverable => %(
    kind   => 'subagent-settled',
    head   => '[background event] ... The reviewer agent has finished:',
    body   => $child-answer,          # excerpt-seam routed by the loop
    tail   => 'Incorporate this result and continue your work.',
    extras => %( 'completion-of' => 'reviewer-1', 'call-id' => 'c1' ),
));

# The loop, and NOTHING else, drains:
for $bus.drain -> %item { ... }

=end code

=head1 DESCRIPTION

A background tool call answers B<twice>: once immediately, with an
acknowledgement that says the work has started, and once later, with what
the work actually produced. This class is the thing in between — the
register of work that has been acknowledged and not yet reported, and the
queue of the reports themselves.

Two questions live here, and they are the only two:

=item B<Is the run allowed to end?> A model that has stopped asking for
tools normally means the run is over. With background work outstanding it
means nothing of the sort: the answer it is waiting for has not arrived
yet. C<quiet> is the whole of that decision.

=item B<What has arrived since the last round?> C<drain> answers with
every deliverable in the order it landed, and takes them off the bus.

Everything else — what a deliverable B<says>, how a turn is framed, when
a run parks and for how long — belongs to L<LLM::Agent::Loop> and to the
composer that opened the operation. This class holds no opinion about any
of it.

=head2 Tracked operations, and untracked deliverables

There are two ways something reaches a run through this bus, and the
difference is B<whether the run waits for it>.

=begin table

Kind      | How it arrives         | Does the run park for it?
==========|========================|===========================
tracked   | open ... settle        | YES, until it settles
untracked | push                   | no, ever

=end table

A B<tracked> operation is one somebody promised an answer for. A C<task>
call that acknowledged immediately told the model "its answer will arrive
later"; C<open> is that promise written down, and until the matching
C<settle> the run will not end. That is the whole of C<Park, don't end>.

An B<untracked> deliverable is news. A detached shell job that exited, a
watcher that noticed something — nothing acknowledged them, nothing is
waiting for them, and a run that parked on one would park for ever
because nothing has undertaken to produce it. C<push> puts it in the
queue and touches the outstanding count not at all: it will be delivered
at the next round boundary if the run is still going, and it will not by
itself keep the run alive.

=head2 quiet, and the race it closes

C<quiet> is the finish decision, and the reason it is a method here
rather than two reads at the call site is that it must be B<one
snapshot>:

=begin code :lang<text>

    quiet  =  nothing outstanding  AND  nothing queued

=end code

Both halves, under one lock, at one instant. Read separately —
"outstanding is 0" and then, a microsecond later, "the queue is empty" —
they describe two different moments, and the operation that settled
between them is a result that reaches nobody: the run ends, and the
answer the model was told to expect is dropped on the floor.

C<state> is the same snapshot with the numbers in it
(C<< { outstanding, queued, quiet } >>), and it is what the park polls:
one lock acquisition per pass, and a decision that cannot be made from a
world that has moved on.

=head2 Single consumer: drain is the driver's

C<drain> is B<destructive>: what it hands back is gone from the bus,
because the bus has no way of taking it back if the caller drops it. That
makes it exactly as safe as one consumer and no safer, and the contract
is therefore explicit:

B<Only the run's driving thread may call C<drain>>, at a round boundary,
and it must record everything it is handed. Everything else here —
C<open>, C<settle>, C<push>, C<quiet>, C<state>, C<outstanding-ops>,
C<close-all> — is safe from any thread and may be called concurrently
from as many as you like.

A second consumer does not corrupt anything: the lock is real. What it
does is take half the completions and put them somewhere the model will
never see them, which is a bug that looks like a flaky model rather than
like a race.

=head2 The bus lock is a leaf

Nothing this class does calls anything it does not own: no callback, no
emit, no I/O, no other lock. Every method is a short critical section
over a Hash and an Array.

That is a promise callers may rely on, and it is what makes it safe to
call C<open> or C<push> from inside somebody else's critical section —
a composer's question table, a notification sink on a flusher thread.
Taking the bus lock can never wait on anything except another bus
operation, and no bus operation waits on anything at all.

The other side of the same promise: B<do not put callbacks on it>. If
this class ever grows an C<on-settle> hook, the leaf property is gone and
so is the freedom above.

=head2 A deliverable

A deliverable is plain data, and its shape is the contract between
whoever produced the work and the loop that renders it:

=begin table

Key    | What it is
=======|=================================================================
kind   | REQUIRED. What sort of event this is: 'subagent-settled', 'job-exited'
head   | The framing and the identity — who, what, and that this is not the user
body   | The content, which the loop routes through the observation excerpt seam
tail   | What the model should do about it
extras | Envelope extras for the injected turn: completion-of, call-id, ...

=end table

The three-way split is B<not> decoration. The loop excerpts C<body> and
only C<body>: a child that answered with a megabyte cannot be allowed
into an unelidable user turn whole, and framing that got excerpted along
with it would leave a turn that no longer says it is an automated event.
So the words that must survive at any size go in C<head> and C<tail>, and
the words that may be cut go in C<body>.

A deliverable with no C<kind>, or with nothing at all in any of the three
text fields, is B<refused> — C<settle> closes the operation anyway and
C<push> answers False. An empty user turn is worse than a missing one.

C<seq> (this bus's own arrival order) and C<op-id> (the tracked
operation's key, absent for an untracked deliverable) are stamped on the
way in and are not the caller's to supply.

=head2 Scope: one bus per conversation

A bus belongs to a B<conversation>, not to a run. A child that settles
thirty seconds after its parent run was cancelled has still done the work
and still has something to say, and the next run of the same conversation
is exactly who should hear it — which is the same argument that makes a
steer queue outlive one run.

C<clear> is the other end of that: a host swapping to a different
conversation calls it, and everything the old one had outstanding goes,
because a completion delivered into a conversation that never asked for
it is a turn out of nowhere.

=head1 SEE ALSO

L<LLM::Agent::Loop> (the park, the round-top drain, and the only caller
of C<drain>), L<LLM::Agent::Subagents> (the composer that opens and
settles a delegation), L<LLM::Agent::Event> (C<BackgroundOpStarted>,
C<BackgroundOpSettled>, C<BackgroundOpDelivered>, C<RunParked>,
C<RunResumed>).

=end pod

unit class LLM::Agent::CompletionBus;

#|( How many operations may be outstanding at once before C<open> starts
    refusing. Sixteen is a number, not a law: it is well above what a
    model delegates in one turn and well below the point at which the
    completions of a single round stop fitting a context window. )
our constant DEFAULT-MAX-OUTSTANDING = 16;

#| See C<DEFAULT-MAX-OUTSTANDING>. A refused C<open> is a guidance result
#| for the model, never an exception.
has Int:D $.max-outstanding = DEFAULT-MAX-OUTSTANDING;

# The one lock, and a strict leaf: see the module Pod. Nothing under it
# calls anything this class does not own.
has Lock:D $!lock .= new;

# key => { op-id, kind, label, meta, seq }. An entry exists from `open`
# until `settle` or `close-all`, and it is the whole of what makes a run
# refuse to finish.
has %!open;

# The deliverables, oldest first. Only `drain` takes anything out.
has @!queue;

# Arrival order, over both tables: an op's seq orders the inventory a
# RunParked reports, and a deliverable's orders the turns a round injects.
has Int:D $!seq = 0;

submethod TWEAK {
	die 'LLM::Agent::CompletionBus: max-outstanding must be at least 1 — a '
		~ 'bus that may never track anything is a bus that refuses every '
		~ 'background operation'
		unless $!max-outstanding >= 1;
}

#|( Track an operation that has been acknowledged and will answer later.
    The run will not end until it settles.

    Answers C<< { ok, outstanding, max, reason? } >> — a Hash rather than
    a Bool because the caller's job on a refusal is to tell the B<model>
    what happened, and "there are already 16 of these, which is the
    limit" needs both numbers read at the same instant they were decided
    against. C<outstanding> is the count B<after> a successful open.

    Refused for two reasons, both of them values:

    =item the bus is at C<max-outstanding> (C<< reason => 'at-capacity' >>);

    =item C<$key> is already open (C<< reason => 'duplicate' >>) — which
    is a bug in the caller rather than a condition, but not one worth
    taking a tool call down over.

    Safe from any thread. )
method open(Str:D $key, Str:D :$kind!, Str :$label, :%meta --> Hash:D) {
	$!lock.protect: {
		if %!open{$key}:exists {
			%(
				ok => False, reason => 'duplicate',
				outstanding => %!open.elems, max => $!max-outstanding,
			);
		}
		elsif %!open.elems >= $!max-outstanding {
			%(
				ok => False, reason => 'at-capacity',
				outstanding => %!open.elems, max => $!max-outstanding,
			);
		}
		else {
			%!open{$key} = %(
				'op-id' => $key, :$kind, :$label, meta => %meta.Hash,
				seq => $!seq++,
			);
			%(
				ok => True,
				outstanding => %!open.elems, max => $!max-outstanding,
			);
		}
	};
}

#|( Close a tracked operation and, unless it was collected somewhere
    else, enqueue what it produced. B<Atomic>: the close and the enqueue
    are one critical section, so there is no instant at which the bus is
    quiet and the deliverable has not landed.

    Answers True B<exactly once per open operation> — the once-guard. A
    second settle for the same key finds nothing open, answers False, and
    enqueues nothing, which is what lets several threads race to report
    the same child without the model hearing about it twice.

    C<:collected> is the synchronous join: a caller that has already
    handed the result to the model itself (a C<task_wait> that was parked
    when the child settled) closes the operation and enqueues B<nothing>.
    It also B<withdraws> any deliverable already queued for that key,
    whether or not the operation was still open — which is the other
    order of the same race: the child settled first, its turn was queued,
    and the model then asked for it by name before the round boundary
    that would have delivered it. One presentation, both ways round.

    A settle for a key that was never open — or was closed by
    C<close-all> — enqueues nothing at all. The run that was waiting for
    it has stopped waiting, and a deliverable for it would be a turn in
    somebody else's conversation.

    Safe from any thread. )
method settle(
	Str:D $key, :%deliverable, Bool:D :$collected = False,
	--> Bool:D
) {
	$!lock.protect: {
		my Bool $was-open = %!open{$key}:exists;
		%!open{$key}:delete;

		# The withdraw runs whether or not it was open: see the Pod on the
		# other order of the race.
		@!queue = @!queue.grep({ ($_<op-id> // '') ne $key }).Array
			if $collected;

		if $was-open && !$collected {
			with self!accept(%deliverable, $key) -> %item {
				@!queue.push: %item;
			}
		}

		$was-open;
	};
}

#|( Enqueue a deliverable B<nothing is waiting for>: news rather than an
    answer. It never touches the outstanding count, so a run parks for it
    exactly never, and it is delivered at the next round boundary if the
    run is still going.

    This is the seam for a detached job's exit notice and for anything
    else a host wants to put in front of the model as a framed event.
    B<Lifecycle only.> A source that pushes a deliverable per line of a
    build's output has turned this into an injection channel and a flood
    channel at once: the queue is unbounded on purpose (dropping a
    completion silently is worse than a long round), and bounding what
    goes into it is the sink's job.

    Answers False for a deliverable the bus will not carry — no C<kind>,
    or no text in any of C<head>, C<body> and C<tail>. Safe from any
    thread. )
method push(%deliverable --> Bool:D) {
	$!lock.protect: {
		with self!accept(%deliverable, Str) -> %item {
			@!queue.push: %item;
			True;
		}
		else {
			False;
		}
	};
}

#|( Everything that has arrived, oldest first, B<taken off the bus>.

    B<The driving thread's, and only its.> See the module Pod: what this
    hands back is gone, and a second consumer is a consumer taking
    completions the model will never see. Call it at a round boundary and
    record every one of them. )
method drain(--> List:D) {
	$!lock.protect: {
		my @taken = @!queue;
		@!queue = ();
		@taken.List;
	};
}

#|( May the run end? True when nothing is outstanding B<and> nothing is
    queued, read as one snapshot — see the module Pod on the race that
    closes. The one-line form of C<< state<quiet> >>. )
method quiet(--> Bool:D) {
	$!lock.protect: { !%!open.elems && !@!queue.elems };
}

#|( The whole picture at one instant: C<< { outstanding, queued, quiet } >>.

    What a park polls. The three answers are consistent with each other
    because they are read together — which "how many are outstanding?"
    followed by "is the queue empty?" is not, and the difference is a
    completion delivered to nobody. )
method state(--> Hash:D) {
	$!lock.protect: {
		%(
			outstanding => %!open.elems,
			queued      => @!queue.elems,
			quiet       => !%!open.elems && !@!queue.elems,
		);
	};
}

#|( What is outstanding, in the order it was opened, as plain data:
    C<< { op-id, kind, label?, meta } >>. The inventory a C<RunParked>
    event carries and a UI renders as "waiting on".

    Fresh Hashes the caller may render, sort and hand on: nothing it does
    to what it is given reaches the bus's own tables. )
method outstanding-ops(--> List:D) {
	$!lock.protect: {
		%!open.values.sort({ $_<seq> }).map({
			%(
				'op-id' => $_<op-id>,
				kind    => $_<kind>,
				|($_<label>.defined ?? (label => $_<label>) !! ()),
				# `.clone`, not `.Hash`: see `!accept`.
				meta    => $_<meta>.clone,
			);
		}).List;
	};
}

#|( Close every outstanding operation and answer the keys it closed, in
    open order. B<The queue is untouched>: a deliverable that has already
    arrived was paid for, and throwing it away because something else
    will never answer would lose a result that exists.

    Two callers, and both of them are the run giving up on work rather
    than the work finishing: a cancel that arrived while the run was
    parked, and the idle valve that fires when nothing has arrived for
    C<park-idle-timeout>. Neither is C<clear>: what is closed here stops
    holding the run open, and what has already landed still gets said.

    Safe from any thread, and a no-op on a bus with nothing open. )
method close-all(--> List:D) {
	$!lock.protect: {
		my @closed = %!open.values.sort({ $_<seq> }).map({ $_<op-id> }).List;
		%!open = ();
		@closed;
	};
}

#|( Forget everything: outstanding operations and queued deliverables
    alike. For a host swapping to a B<different conversation>, which is
    the one case where a completion that has genuinely arrived still must
    not be delivered — it belongs to the conversation that asked for it,
    and injecting it into another one is a turn out of nowhere.

    Not for the end of a run. A bus outlives a run on purpose; see the
    module Pod. )
method clear(--> Nil) {
	$!lock.protect: {
		%!open  = ();
		@!queue = ();
	};
	Nil;
}

method gist(--> Str:D) {
	my %state = self.state;
	'LLM::Agent::CompletionBus<outstanding ' ~ %state<outstanding>
		~ ' queued ' ~ %state<queued> ~ '>';
}

#|( Normalise a deliverable, or Nil for one the bus will not carry.
    B<Must be called with the lock held>: it stamps C<seq>, which is this
    bus's arrival order over both tables.

    Total by construction. What arrives here came from a composer, a
    notification sink or an app, and a malformed one is a deliverable
    that does not get carried rather than an exception on somebody's
    flusher thread. )
method !accept(%deliverable, Str $op-id) {
	my Str $kind = %deliverable<kind> ~~ Str:D ?? %deliverable<kind>.trim !! '';
	return Nil unless $kind.chars;

	my Str $head = text-of(%deliverable<head>);
	my Str $body = text-of(%deliverable<body>);
	my Str $tail = text-of(%deliverable<tail>);
	# An empty user turn is worse than a missing one: it costs a round
	# trip and tells the model nothing at all.
	return Nil unless ($head ~ $body ~ $tail).chars;

	%(
		seq    => $!seq++,
		:$kind, :$head, :$body, :$tail,
		|($op-id.defined ?? ('op-id' => $op-id) !! ()),
		# `.clone`, and NOT `.Hash`: a Hash's `.Hash` is the invariant
		# identity method and answers with the invocant itself, so the bus
		# would be holding the caller's own Hash and a consumer poking at
		# what a drain handed over would be poking at it.
		extras => (%deliverable<extras> ~~ Associative
			?? %deliverable<extras>.clone
			!! %()),
	);
}

# One text field of a deliverable. Deliberately total, and deliberately
# NOT stringifying a Hash or a Message that found its way in here: what
# `.Str` makes of one of those would go into the conversation as
# something a system said, and the empty string is the honest answer.
my sub text-of($value --> Str:D) {
	$value ~~ Str:D ?? $value !! '';
}
