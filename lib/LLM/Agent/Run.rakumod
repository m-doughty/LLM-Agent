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

=end table

All five keys are always present, so a caller can index blind and branch
on C<outcome>.

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

Cancelling a run that has already finished is a no-op — the outcome
stands.

=head1 INTERNAL: THE DRIVING SEAM

Everything below is for whoever drives the Run — normally
C<LLM::Agent::Loop>, in tests a hand-rolled driver. It is not part of the
API a consumer of a Run uses, which is why it is underscore-prefixed.

A Run is a passive handle: it owns the Supplier, the vow on the result
Promise, and the terminal-once invariant, and nothing else. The driver
constructs one, drives it with C<_emit> and finishes it with C<_finish>:

=begin code :lang<raku>

my $run = LLM::Agent::Run.new(
    # Called once, on the cancelling thread, the first time cancel() is
    # invoked. Optional, and shielded: an exception from it cannot break
    # cancellation. Use it to poke a blocking wait awake (aborting an
    # in-flight stream at the backend, say) rather than waiting for the
    # next poll.
    on-cancel => { $backend.cancel($current-response) with $current-response },
);

start {
    $run._emit: LLM::Agent::Event::RunStarted.new(
        run-id => $run.id, message-count => @messages.elems,
    );

    # ... rounds, attempts, tools; poll $run.is-cancelled, or use
    #     $run.cancellation with Promise.anyof to wait on it ...

    $run._finish:
        LLM::Agent::Event::RunCompleted.new(final => $text),
        final => $text, messages => @conversation;
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

=item C<_finish> emits the terminal, C<done>s the Supply and keeps the
Promise, in that order. A consumer that reacts to the terminal event and
then reads C<.result> may therefore find it Planned for a moment — await
it, or use C<is-done>.

The driver is assumed to be B<single-threaded with respect to emitting>:
C<_emit> and C<_finish> are called from the one state-machine thread. The
internal lock is there to make C<cancel> (which arrives from any thread)
safe against C<_finish>, not to serialise a multi-threaded driver.

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
	#| Stamped on the RunStarted event, and what tells two interleaved
	#| runs apart in a shared log.
	has Str:D $.id = uuid-v4;

	#| Every event of the run, in order, ending with exactly one terminal
	#| and then C<done>. Never C<quit>. See the first-tap caveat above.
	has Supply $.events;

	#| KEPT — never broken — with the outcome Map. See the table above.
	has Promise:D $.result .= new;

	#|( Kept with True the first time C<cancel> is called; stays Planned
	    otherwise. For waiting on a cancel rather than polling for one:

	        await Promise.anyof($tool-batch, $run.cancellation);
	 )
	has Promise:D $.cancellation .= new;

	#| INTERNAL. Registered by the driver; called once on the first
	#| cancel, shielded. See the driving-seam section.
	has &.on-cancel;

	has Supplier::Preserving:D $!supplier .= new;
	has Lock:D $!lock .= new;
	has Bool $!finished = False;
	has Bool $!cancel-requested = False;
	has $!vow;
	has $!cancel-vow;

	submethod TWEAK {
		$!events     = $!supplier.Supply;
		$!vow        = $!result.vow;
		$!cancel-vow = $!cancellation.vow;
	}

	#| True once the run has finished, whatever the outcome. Poll-friendly
	#| (no tap, no await), which is what makes tests able to wait for a
	#| run without racing a Supply they may have already consumed.
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

	    An exception from C<on-cancel> is swallowed deliberately: a
	    backend whose abort request failed must not turn "cancel this run"
	    into an exception in the caller's UI thread. The driver's own
	    cancellation path is what actually ends the run. )
	method cancel(--> Nil) {
		my $first = $!lock.protect: {
			$!cancel-requested ?? False !! ($!cancel-requested = True);
		};
		return unless $first;

		$!cancel-vow.keep(True);
		if &!on-cancel.defined {
			try &!on-cancel();
		}
	}

	#|( INTERNAL (driver only). Publish a non-terminal event.

	    Returns True when it was published, False when the run had already
	    finished and it was dropped — which is not an error: a tool thread
	    or a log hook can legitimately fire one moment too late, and the
	    "nothing after the terminal" contract matters more than the
	    stray event.

	    Dies on a terminal event: those go through C<_finish>, which is
	    the only thing that can keep the result Promise. )
	method _emit(LLM::Agent::Event:D $event --> Bool:D) {
		die "LLM::Agent::Run._emit: {$event.kind} is a terminal event — "
			~ 'finish the run with ._finish so the result Promise is kept'
			if $event.is-terminal;

		my $go = $!lock.protect: { !$!finished };
		return False unless $go;

		$!supplier.emit($event);
		True;
	}

	#|( INTERNAL (driver only). End the run: publish the terminal event,
	    close the Supply, keep the result Promise.

	    C<%outcome> supplies C<final> (Str), C<messages> (the conversation
	    as Message objects), C<error> (Str) and C<attempts> (List) — all
	    optional, all defaulted, and all present in the resulting Map. The
	    C<outcome> key is derived from C<$terminal> and cannot be
	    overridden.

	    Returns True the first time and False every time after, so a
	    driver whose success path and cancel path race each other stays
	    correct without holding a lock of its own. )
	method _finish(LLM::Agent::Event:D $terminal, *%outcome --> Bool:D) {
		die "LLM::Agent::Run._finish: {$terminal.kind} is not a terminal event"
			unless $terminal.is-terminal;

		my $first = $!lock.protect: {
			$!finished ?? False !! ($!finished = True);
		};
		return False unless $first;

		$!supplier.emit($terminal);
		$!supplier.done;
		$!vow.keep(%(
			outcome  => OUTCOME-OF{$terminal.kind},
			final    => (%outcome<final> // '').Str,
			messages => (%outcome<messages> // ()).List,
			error    => (%outcome<error>.defined ?? %outcome<error>.Str !! Str),
			attempts => (%outcome<attempts> // ()).List,
		).Map);
		True;
	}

	method gist(--> Str:D) {
		my $state = self.is-done
			?? $!result.result<outcome>
			!! (self.is-cancelled ?? 'cancelling' !! 'running');
		"LLM::Agent::Run<{$!id}> $state";
	}
}
