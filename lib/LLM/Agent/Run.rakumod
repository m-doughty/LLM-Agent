=begin pod

=head1 NAME

LLM::Agent::Run - the handle on one agent run: events, result, cancel

=head1 SYNOPSIS

=begin code :lang<raku>

my $run = $loop.run(@messages);   # returns immediately; work happens behind it

# Live: one Supply of typed events.
start react whenever $run.events -> $event {
    print $event.text if $event ~~ LLM::Agent::Event::Token;
}

# Or just wait for the answer. The Promise is KEPT even when the run failed.
my %outcome = await $run.result;
given %outcome<outcome> {
    when 'completed' { say %outcome<final> }
    when 'failed'    { note "gave up: {%outcome<error>}" }
    when 'cancelled' { note 'cancelled' }
}

# From anywhere, at any time, as often as you like:
$run.cancel;

=end code

=head1 DESCRIPTION

C<Loop.run> hands back one of these and gets out of the way. It is three
things bolted together — a Supply to watch, a Promise to await, and a
cancel button — plus the guarantees that make those three safe to use
together.

=head2 The result Promise is kept, never broken

Whatever happens, C<$run.result> is B<kept> with a Map:

=begin table

Key      | Value
=========|====================================================
outcome  | 'completed', 'failed' or 'cancelled'
final    | the last assistant text (Str, '' when there is none)
messages | the conversation as Message objects, as the run left it
error    | why it failed (Str; undefined otherwise)
attempts | the attempt records behind a failure (List; empty otherwise)
reason   | the named failure behind it (Str; undefined for everything else)
spent    | what it cost — B<only> when something was counting; see below

=end table

The first six keys are always present, so a caller can index blind and
branch on C<outcome>.

C<spent> is the exception, and deliberately: it appears only when the
loop had an L<LLM::Agent::RequestBudget> to count against, and carries
C<< { total-tokens, wall-clock, cost? } >> — C<cost> itself only when a
provider reported one. Absent means B<nobody was counting>, which is a
different answer from "nothing was spent", and collapsing the two into a
zero would let a dashboard report a free run for a backend that simply
does not price its calls.

C<reason> is the one to branch on when a failure needs handling rather
than reporting: it carries the same string as the C<RunFailed> event's
C<reason> — C<'context-exhausted'> and C<'budget-exhausted'> are the two
so far — and is undefined for the ordinary failures, whose C<error> is
all there is to say.

Kept-not-broken is deliberate. A broken Promise makes a failed run into an
exception thrown at whoever happened to be C<await>ing, which means a
caller who wanted to inspect the attempts has to catch first and unwrap
second, and a caller who wanted to fire-and-forget gets an unhandled
Promise warning at GC time for a failure it had already handled through
the event stream. A run that failed is a run that finished; it is data.

The same reasoning applies to the Supply: it is C<done> after the terminal
event and B<never> C<quit>.

=head2 The events Supply preserves

C<$run.events> comes from a C<Supplier::Preserving>, because a scripted
run can finish in under a millisecond — long before a test (or a TUI that
is still laying out its widgets) gets around to tapping. With a plain
Supplier those events are gone; here they are buffered and the first tap
receives the whole run from the beginning.

B<Caveat, and it bites:> the buffer is delivered to the B<first> tap only.
A second tap arriving after the first has drained it sees only what is
emitted from then on — and on a finished run, that is nothing at all, not
even the C<done>. So: tap once, and if two consumers need the stream, tap
once and fan out yourself. This is why the test kit's C<drain-events>
insists it is the only tap.

=head2 Cancellation

C<cancel> is idempotent, safe from any thread, and never throws. It does
not itself stop anything: it keeps the C<cancellation> Promise, calls the
C<on-cancel> hook the driver registered (once), and returns. The driver
notices and winds the run down, ending with a C<RunCancelled> event.

Cancelling a run that has already finished is a B<total> no-op. Not "the
outcome stands, but the machinery still fires": the C<cancellation>
Promise stays C<Planned>, C<is-cancelled> stays False, and the
C<on-cancel> hook is B<not> called. That last one is the point. A hook
belongs to a driver, a driver holds handles on the things it was driving,
and a finished run's driver has already let go of them — so a hook fired
after the end would reach for a stream, a backend or a slot that
something else now owns. A run that is over cannot be asked to stop; it
has stopped.

=head2 The drained Promise

C<result> tells you the run has an answer. C<drained> tells you the run
has stopped B<producing>: it is kept once the run is closed B<and> every
work section the driver opened has closed — the state machine, the token
stream, a detached tool batch, an asker or a log hook still inside an
C<_emit>.

The two deliberately diverge on cancellation. A cancelled run's C<result>
is kept promptly, because the caller asked it to stop and should not wait
on a tool batch nobody can interrupt; its C<drained> stays C<Planned>
until that batch finally returns. If you are tearing down a loop, an app,
or a test fixture and want to know that nothing is still running behind
you, C<drained> is the one to await.

C<drained> attests B<producer quiescence, not delivery>. A subscriber
that blocks forever in its C<whenever> block parks the run's delivery
task and nothing else: C<result>, C<cancellation> and C<drained> all
still resolve.

=head1 INTERNAL: THE DRIVING SEAM

Everything below is for whoever drives the Run — normally
C<LLM::Agent::Loop>, in tests a hand-rolled driver. It is not part of the
API a consumer of a Run uses, which is why it is underscore-prefixed.

A Run is the run's B<serialisation point>: it owns the Supplier, the vow
on the result Promise, the terminal-once invariant, and the mailbox that
turns emissions from any number of threads into one published order. The
driver constructs one, drives it with C<_emit> and finishes it with
C<_finish>:

=begin code :lang<raku>

my $run = LLM::Agent::Run.new(
    # Called once, on the cancelling thread, the first time cancel() is
    # invoked. Optional, and shielded: an exception from it cannot break
    # cancellation. Use it to poke a blocking wait awake (aborting an
    # in-flight stream at the backend, say) rather than waiting for the
    # next poll.
    on-cancel => { $backend.cancel($current-response) with $current-response },
);

$run._work-begin;   # the driver's own work section, opened up front

start {
    $run._emit: LLM::Agent::Event::RunStarted.new(
        run-id => $run.id, message-count => @messages.elems,
    );

    # ... rounds, attempts, tools; poll $run.is-cancelled, or use
    #     $run.cancellation with Promise.anyof to wait on it ...

    # The epilogue, in this order: let go of everything this run owns —
    # here the handle the cancel hook above pokes — THEN finish it, which
    # is what lets the next run start, THEN close the driver's work
    # section, which is what keeps `drained` honest.
    $current-response = Nil;
    $run._finish:
        LLM::Agent::Event::RunCompleted.new(final => $text),
        final => $text, messages => @conversation;
    $run._work-done;
}

$run;   # handed to the caller immediately

=end code

The invariants the Run enforces so the driver cannot get them wrong:

=item C<_emit> B<refuses terminal events> (that is what C<_finish> is
for) and silently drops anything emitted after the run has finished,
returning False. A late Log event from a tool thread cannot appear after
C<RunCompleted>.

=item C<_finish> is B<once>. The second call returns False and changes
nothing — so a driver racing its own cancel path against its own success
path cannot keep the result Promise twice (which would throw) or emit two
terminals.

=item The C<outcome> key of the result Map is B<derived from the terminal
event class>, not passed in, so it can never disagree with the event the
consumer just saw.

=item C<_finish> B<keeps the result Promise before it publishes the
terminal event>, both inside one critical section. So a consumer that
reacts to C<RunCompleted> and immediately reads C<.result> finds it
C<Kept> — it never has to await what it can already see happened. (This
is the reverse of the 0.1.0 ordering, which emitted first and kept
after, leaving a window where the terminal was visible and the result was
not.)

=head2 Publication: the mailbox

Events reach the Supply from B<one> thread, and it is not the driver's.
C<_emit> and C<_finish> stamp the event with C<run-id> and the next
C<seq>, push it onto the run's mailbox, and return; a single drain task
publishes the mailbox in order. Everything that matters follows from
that one critical section:

=item The driver may be as multi-threaded as it likes. The state machine,
a token tap, a tool thread, an asker and a server's log hook all emit
concurrently, and the order the Supply publishes is the order the lock
granted — which is exactly the order C<seq> records.

=item Nothing can follow the terminal. C<_finish> closes the run and
enqueues the terminal in the same critical section, so a concurrent
C<_emit> either got in before (and is published before) or is refused.
The Supply's C<done> is sent only when the mailbox is empty B<and> the
run is closed, which cannot be observed before the terminal has been
published.

=item C<_emit> returning True means B<accepted and ordered>, not
delivered. Delivery is the drain task's job, and it happens after the
call returned. Wait on C<drained> (or on the Supply's C<done>) if you
need "everything has been published"; C<is-done> is the answer to
"the run is over".

=item A subscriber that throws loses its own event and nothing else — the
same shielding C<&!on-cancel> gets. A subscriber that B<blocks> parks
publication only; the result, cancellation and drained Promises are all
resolved off the mailbox.

The lock is a strict B<leaf>: nothing called under it emits into the
Supply, calls the C<on-cancel> hook, or calls back into the driver.

=head2 Work sections, and drained

C<_work-begin> / C<_work-done> bracket anything that may still emit.
C<_work-begin> returns False on a closed run — there is nothing left to
attest, and the caller must then B<not> call the paired C<_work-done>.
When the last section closes on a closed run, C<drained> is kept.

The driver's own section is the outer one, and its C<_work-done> must be
the B<last> thing the driver does, after every handle it holds has been
released. That is what makes C<drained> mean "this run is not touching
anything any more" rather than "the state machine returned".

A driver that dies must still call C<_finish> with a C<RunFailed> — an
abandoned Run leaves its result Promise Planned forever, and C<await>ing
it hangs. C<LLM::Agent::Loop> wraps its state machine accordingly.

=head1 SEE ALSO

L<LLM::Agent::Event>

=end pod

use UUID::V4;

use LLM::Agent::Event;

# kind => outcome. The one place the mapping lives, so `_finish` can
# derive the result Map's `outcome` from the terminal event rather than
# trusting the driver to keep two things in step.
my constant OUTCOME-OF = {
	'run-completed' => 'completed',
	'run-failed'    => 'failed',
	'run-cancelled' => 'cancelled',
};

class LLM::Agent::Run {
	#| This run's identity: a UUID v4 unless the caller supplies one.
	#| Stamped on B<every> event this run publishes, and what tells two
	#| interleaved runs apart in a shared log.
	has Str:D $.id = uuid-v4;

	#|( Every event of the run, in one order — the order C<seq> records —
	    ending with exactly one terminal and then C<done>. Never C<quit>.
	    See the first-tap caveat above. )
	has Supply $.events;

	#| KEPT — never broken — with the outcome Map. See the table above.
	has Promise:D $.result .= new;

	#|( Kept with True the first time C<cancel> is called; stays Planned
	    otherwise — including on a run that had already finished, which
	    C<cancel> ignores entirely. For waiting on a cancel rather than
	    polling for one:

	        await Promise.anyof($tool-batch, $run.cancellation);
	 )
	has Promise:D $.cancellation .= new;

	#|( Kept with True once the run is closed B<and> every work section
	    the driver opened has closed: nothing can emit into this run any
	    more. Producer quiescence, not delivery — see the Pod. )
	has Promise:D $.drained .= new;

	#| INTERNAL. Registered by the driver; called once on the first
	#| cancel, shielded. See the driving-seam section.
	has &.on-cancel;

	has Supplier::Preserving:D $!supplier .= new;

	# The one lock, and a strict leaf: nothing called while it is held
	# emits into the Supply, calls &!on-cancel, or calls back into the
	# driver. Everything below it is a hash lookup or an integer.
	has Lock:D $!lock .= new;

	# Stamped, ordered, and not yet published. Drained by one task at a
	# time — $!draining is that task's baton.
	has @!mailbox;
	has Bool $!draining = False;
	has Int:D $!next-seq = 0;

	# Closed means: the terminal is in the mailbox (or past it). Nothing
	# is ever enqueued afterwards, which is why "empty and closed" is a
	# safe moment to `done` the Supply exactly once.
	has Bool $!closed = False;

	has Int:D $!outstanding = 0;
	has Bool $!drained-done = False;
	has Bool $!cancel-requested = False;
	has $!vow;
	has $!cancel-vow;
	has $!drained-vow;

	submethod TWEAK {
		$!events      = $!supplier.Supply;
		$!vow         = $!result.vow;
		$!cancel-vow  = $!cancellation.vow;
		$!drained-vow = $!drained.vow;
	}

	#|( True once the run has finished, whatever the outcome. Poll-friendly
	    (no tap, no await), which is what makes tests able to wait for a
	    run without racing a Supply they may have already consumed.

	    A driver that finishes its run last — as C<LLM::Agent::Loop> does —
	    makes this mean more than "there is a result": by the time it flips,
	    that driver has already released everything the run owned. What it
	    does B<not> promise is that every event has been delivered, or that
	    a detached tool batch has returned; C<drained> is that. )
	method is-done(--> Bool:D) {
		$!result.status !== Planned;
	}

	#| True once somebody has asked for cancellation — which is not the
	#| same as the run having stopped. C<is-done> is that.
	method is-cancelled(--> Bool:D) {
		$!cancellation.status === Kept;
	}

	#|( Ask the run to stop. Idempotent, thread-safe, never throws, and
	    cheap: it keeps the C<cancellation> Promise and calls the driver's
	    C<on-cancel> hook once. The run itself stops when the driver
	    notices, which it promises to do without waiting out a backoff.

	    On a run that has already finished this does B<nothing at all> —
	    no vow, no hook, C<is-cancelled> stays False. A finished run's
	    driver has already let go of the stream, the backend and the slot
	    the hook would have poked, and whatever holds them now is not this
	    run's business.

	    An exception from C<on-cancel> is swallowed deliberately: a
	    backend whose abort request failed must not turn "cancel this run"
	    into an exception in the caller's UI thread. The driver's own
	    cancellation path is what actually ends the run. )
	method cancel(--> Nil) {
		my $first = $!lock.protect: {
			($!closed || $!cancel-requested)
				?? False
				!! ($!cancel-requested = True);
		};
		return unless $first;

		# Outside the lock, in this order: the Promise a driver may be
		# blocked on first, then the hook, which is somebody else's code
		# and must never run under our lock.
		$!cancel-vow.keep(True);
		if &!on-cancel.defined {
			try &!on-cancel();
		}
	}

	#|( INTERNAL (driver only). Publish a non-terminal event, from any
	    thread.

	    Returns True when it was B<accepted and ordered> — not when it was
	    delivered; delivery happens on the drain task, after this returns.
	    False means the run had already closed and the event was dropped,
	    which is not an error: a tool thread or a log hook can legitimately
	    fire one moment too late, and the "nothing after the terminal"
	    contract matters more than the stray event.

	    Dies on a terminal event: those go through C<_finish>, which is
	    the only thing that can keep the result Promise. )
	method _emit(LLM::Agent::Event:D $event --> Bool:D) {
		die "LLM::Agent::Run._emit: {$event.kind} is a terminal event — "
			~ 'finish the run with ._finish so the result Promise is kept'
			if $event.is-terminal;

		my Bool $spawn = False;
		my Bool $accepted = $!lock.protect: {
			$!closed ?? False !! do { $spawn = self!enqueue($event); True };
		};

		self!drain if $spawn;
		$accepted;
	}

	#|( INTERNAL (driver only). End the run: keep the result Promise and
	    publish the terminal event, in that order and in one critical
	    section, so a consumer that sees the terminal can read the result
	    without awaiting it.

	    C<%outcome> supplies C<final> (Str), C<messages> (the conversation
	    as Message objects), C<error> (Str), C<attempts> (List) and
	    C<reason> (Str) — all optional, all defaulted, and all present in
	    the resulting Map. The
	    C<outcome> key is derived from C<$terminal> and cannot be
	    overridden.

	    Returns True the first time and False every time after, so a
	    driver whose success path and cancel path race each other stays
	    correct without holding a lock of its own. )
	method _finish(LLM::Agent::Event:D $terminal, *%outcome --> Bool:D) {
		die "LLM::Agent::Run._finish: {$terminal.kind} is not a terminal event"
			unless $terminal.is-terminal;

		# Built before the lock: %outcome is the driver's data and
		# flattening it is the driver's work, not the critical section's.
		my %result =
			outcome  => OUTCOME-OF{$terminal.kind},
			final    => (%outcome<final> // '').Str,
			messages => (%outcome<messages> // ()).List,
			error    => (%outcome<error>.defined ?? %outcome<error>.Str !! Str),
			attempts => (%outcome<attempts> // ()).List,
			reason   => (%outcome<reason>.defined ?? %outcome<reason>.Str !! Str),
		;
		# The one CONDITIONAL key, and the only one: a driver that was
		# counting says what the run spent, and one that was not says
		# nothing at all rather than a zero it did not measure. The six
		# above are always there — that contract does not move.
		%result<spent> = %outcome<spent>.Hash
			if %outcome<spent> ~~ Associative;
		my $result = %result.Map;

		my Bool $spawn = False;
		my Bool $first = $!lock.protect: {
			if $!closed {
				False;
			}
			else {
				$!closed = True;
				# Kept BEFORE the terminal is enqueued, so that a
				# subscriber which reacts to the terminal always finds the
				# result there. Safe under a leaf lock: keeping a Promise
				# only schedules its continuations, it never runs anybody
				# else's code on this thread.
				$!vow.keep($result);
				$spawn = self!enqueue($terminal);
				True;
			}
		};
		return False unless $first;

		self!drain if $spawn;
		# A Run nobody opened a work section on (a hand-rolled driver, a
		# test) is quiescent the moment it closes.
		self!settle-drained;
		True;
	}

	#|( INTERNAL (driver only). Open a work section: a stretch of time in
	    which something may still C<_emit> into this run. Returns False on
	    a closed run — there is nothing left to attest, and the caller must
	    then B<not> call the paired C<_work-done>. )
	method _work-begin(--> Bool:D) {
		$!lock.protect: {
			$!closed ?? False !! do { $!outstanding++; True };
		};
	}

	#|( INTERNAL (driver only). Close a work section opened by a
	    C<_work-begin> that returned True. When the last one closes on a
	    closed run, C<drained> is kept. Never throws. )
	method _work-done(--> Nil) {
		$!lock.protect: { $!outstanding-- if $!outstanding > 0 };
		self!settle-drained;
		Nil;
	}

	# Stamp and enqueue one event. MUST be called with $!lock held: the
	# stamp, the mailbox order and the published order are the same order,
	# and they only stay the same order inside one critical section.
	# `clone` runs no TWEAK and mutates nothing shared — the caller's event
	# object is left exactly as it was handed to us.
	# Returns True when the caller must spawn the drain task.
	method !enqueue(LLM::Agent::Event:D $event --> Bool:D) {
		@!mailbox.push: $event.clone(run-id => $!id, seq => $!next-seq++);
		my Bool $spawn = !$!draining;
		$!draining = True;
		$spawn;
	}

	#| Publish the mailbox, in order, on one task at a time.
	method !drain(--> Nil) {
		start {
			loop {
				my @batch;
				my Bool $empty = False;
				my Bool $publish-done = False;

				$!lock.protect: {
					if @!mailbox.elems {
						@batch = @!mailbox.splice(0, @!mailbox.elems);
					}
					else {
						# The baton pass. Clearing the flag in the same
						# critical section that saw the mailbox empty is
						# what makes it lossless: a concurrent _emit either
						# lands in a batch this task is about to take, or
						# finds $!draining False and spawns the successor.
						$!draining = False;
						$empty = True;
						# "Empty AND closed" cannot be observed before the
						# terminal was dequeued — closed is set in the same
						# critical section that pushed it — so this is the
						# one moment the Supply can be done, and only one
						# task can ever reach it.
						$publish-done = $!closed;
					}
				};

				# A subscriber that throws loses its own event and nothing
				# else; one that blocks parks publication and nothing else.
				# NB the block, not `try ... for @batch`: a statement
				# modifier binds LOOSER than the `try`, so that form wraps
				# the whole loop and the first throwing subscriber would
				# take the rest of the batch — the terminal included — down
				# with it. `Supplier.emit` really does rethrow a tap's
				# exception at whoever emitted.
				for @batch -> $event {
					try $!supplier.emit($event);
				}

				if $empty {
					try $!supplier.done if $publish-done;
					last;
				}
			}
		}
		Nil;
	}

	# Keep the drained vow once nothing can produce another event: the run
	# is closed and every work section has ended. Called outside the lock.
	method !settle-drained(--> Nil) {
		my Bool $settled = $!lock.protect: {
			(!$!drained-done && $!closed && $!outstanding == 0)
				?? ($!drained-done = True)
				!! False;
		};
		$!drained-vow.keep(True) if $settled;
		Nil;
	}

	method gist(--> Str:D) {
		my $state = self.is-done
			?? $!result.result<outcome>
			!! (self.is-cancelled ?? 'cancelling' !! 'running');
		"LLM::Agent::Run<{$!id}> $state";
	}
}
