=begin pod

=head1 NAME

LLM::Agent::Subagents - a tool provider that spawns child agent runs and
answers with what they said

=head1 SYNOPSIS

=begin code :lang<raku>

use LLM::Agent::Subagents;

my $loop;                       # forward-declared: the composer needs it

my $subagents = LLM::Agent::Subagents.new(
    # Everything the model could already do. The composer publishes this
    # catalogue plus one tool of its own, and forwards every call it does
    # not own to it untouched.
    inner => $policy,

    # What may be spawned. `name` and `description` are required and are
    # what the model is shown; every other key is yours and is handed
    # back to the spawn callback verbatim.
    types => [
        {
            name        => 'reviewer',
            description => 'Reviews a diff and reports problems. Read-only.',
            backends    => @cheap-backends,     # app-owned, passed through
            identity    => 'You are a meticulous code reviewer.',
        },
        {
            name        => 'tester',
            description => 'Runs the test suite and reports what failed.',
            backends    => @backends,
            identity    => 'You run tests and report results.',
        },
    ],

    # The whole of the app's side of the deal: build a child run, hand
    # back something with `.run` and `.session-path`. See THE SPAWN
    # CALLBACK.
    spawn => -> %spec { build-child(%spec) },

    # Deferred, because $loop does not exist yet — the same idiom the
    # policy's on-ask uses. `loop => $loop` here would copy an undefined
    # value and the composer would never find a run to emit into.
    loop    => { $loop },
    session => $session,        # the PARENT's transcript

    max-live             => 4,
    max-identical-spawns => 3,
);

$loop = LLM::Agent::Loop.new(:@backends, provider => $subagents, :$session);

# The parent's stream now carries the children's events too, wrapped.
react whenever $loop.run([$question]).events -> $event {
    given $event {
        when LLM::Agent::Event::Subagent {
            note "[{$event.agent-id}] {$event.inner<kind>}";
        }
        when LLM::Agent::Event::Token { print $event.text }
    }
}

=end code

=head1 DESCRIPTION

A subagent is a second agent run, started by the model of the first one,
with a conversation of its own that the parent never sees. This module is
the whole of that mechanism on the L<LLM::Agent> side: a B<tool provider>
that stacks over another one, publishes a C<task> tool beside its tools,
and answers a C<task> call with the child run's final message.

Stacking is the point. C<MCP::Client::Registry> composes several servers
into one provider, C<MCP::Client::Policy> composes a provider with a
permission model, and this composes a provider with the ability to
delegate — all three through the same duck-typed pair (C<tools-for-llm>
and C<execute-tool-calls>), so the loop cannot tell them apart and the
order they are stacked in is the app's decision:

=begin code :lang<text>

    Subagents( Policy( Registry( client, client, ... ) ) )
        the model may delegate, and everything it or its children do
        goes through the same permission model

    Policy( Subagents( Registry( ... ) ) )
        delegating is itself a permission question

=end code

What it deliberately is B<not> is a scheduler. It does not own a queue,
a thread pool, a priority or a notion of what a child costs; it starts a
child when the model asks for one, refuses when too many are already
running, and waits. An app that wants queueing wraps the spawn callback,
which is exactly why that callback is the whole of the seam.

=head2 What a task call does, end to end

=item The arguments are read and checked: an C<agent-type> that is in the
table, a C<prompt> that is not empty, an optional C<label>.

=item The two guards run — the identical-spawn digest and the C<max-live>
backstop. Either one refusing is an C<is_error> result and B<not> an
exception: the model is told, in words, what happened and what to do
instead.

=item The spawn callback is called with the spec, and hands back a
handle. A C<subagent-spawned> envelope goes to the parent's transcript.

=item The child's event Supply is tapped — this is its B<only> tap — and
every event is wrapped in an C<LLM::Agent::Event::Subagent> and published
on the B<parent's> stream through C<< Loop.emit-external >>.

=item The child's result is awaited. Its final text becomes the tool
result; a failed or cancelled child becomes an C<is_error> result saying
so. A C<subagent-settled> envelope records the outcome, an excerpt of
what came back, and what the child spent.

=head2 THE SPAWN CALLBACK

The one thing this module does not do is build a child. That is
deliberate: how a child is configured — which backends, which system
prompt, which tools, which transcript, whether it is queued behind
others, whether it is even in this process — is entirely the app's, and a
composer with an opinion about it would have to grow a dependency on
everything an app knows.

So C<&spawn> is called with one Hash and must return a handle:

=begin table

Spec key | What it is
=========|=======================================================
agent-id | this child's short unique id ('reviewer-1')
type     | the type record from C<types>, verbatim, as a Hash
prompt   | what the model asked for, as it wrote it
label    | the model's name for this piece of work, or an undefined Str

=end table

=begin code :lang<raku>

sub build-child(%spec) {
    my %type = %spec<type>;

    # A transcript of its own. Nothing says a child must have one — an
    # undefined path is fine — but a child that writes into the PARENT's
    # session would interleave two conversations in one file.
    my $path = $sessions-dir.add("{%spec<agent-id>}.jsonl");
    my $child-session = LLM::Agent::Session.create(
        path => $path,
        meta => { agent => %type<name>, label => %spec<label> // '' },
    );

    my $child-loop = LLM::Agent::Loop.new(
        backends => %type<backends>,
        provider => %type<provider>,     # usually NOT this composer:
                                         # see "Children do not delegate"
        session  => $child-session,
    );

    my $context = LLM::Agent::RunContext.new(
        head-sections => [ identity => %type<identity> ],
        facts         => [ date => Date.today.Str, cwd => $*CWD.Str ],
    );

    class { has $.run; has Str $.session-path }.new(
        run => $child-loop.run(
            [LLM::Chat::Conversation::Message.new(
                role => 'user', content => %spec<prompt>,
            )],
            :$context,
        ),
        session-path => $path.Str,
    );
}

=end code

The handle is B<duck-typed>, checked with C<.can>, and needs exactly two
things:

=item C<.run> — an L<LLM::Agent::Run>, already started. The composer taps
it and awaits its result; it never starts anything itself.

=item C<.session-path> — where the child's transcript is, as a Str, for
the C<subagent-spawned> envelope. An empty string is fine and means "this
child has no transcript"; what is not fine is leaving the parent's reader
guessing.

A callback that throws, returns something that is not handle-shaped, or
returns a handle whose C<.run> is not a Run is a wiring bug that will
happen at three in the morning, so it is B<not> an exception: it is an
C<is_error> result naming what was wrong, the child's slot is released,
and the parent run carries on.

=head3 Children do not delegate, unless you say so

Nothing here stops an app handing the child loop this same composer as
its provider — and nothing here would stop the resulting tree from being
five levels deep, either. C<max-live> is per composer, so a shared one
caps the whole tree; a composer per child caps each level separately and
the tree is unbounded. Give a child a provider without a C<task> tool
unless recursive delegation is something you want and have bounded.

=head2 The wrapping contract

A child's events are B<not> merged into the parent's stream: they are
wrapped, one C<LLM::Agent::Event::Subagent> per child event, carrying the
child's C<.to-hash> as C<inner>. The parent Run stamps the wrapper with
its own C<run-id> and C<seq>; the inner hash keeps the child's. See
L<LLM::Agent::Event>'s Pod for why, and for what a consumer does with it.

Three properties follow, and they are the ones worth relying on:

=item B<The parent's terminal contract is untouched.> A C<Subagent> event
is never terminal, whatever the child's event was, so a child completing
cannot end the parent's Supply.

=item B<Ordering is the parent's.> The wrapper goes through
C<< Loop.emit-external >>, which is the same mailbox the loop's own
events go through, so a child's event is ordered against the parent's
tokens rather than racing them.

=item B<A late child is dropped, not an error.> A child that emits after
the parent run has finished — a cancelled parent whose child is still
winding down — finds no live run, and C<emit-external> answers False. The
"nothing after the terminal" contract wins.

=head2 The guards

Two, and both exist because a model that has discovered delegation will
delegate.

B<The identical-spawn guard> counts C<< (agent-type, prompt) >> as a
digest, the way L<LLM::Agent::Loop>'s identical-call guard counts a
call's name and canonicalised arguments: the arguments are reparsed, so
key order and JSON whitespace are not part of the identity, and the
prompt is trimmed, so a trailing newline is not either. The same spawn
more than C<max-identical-spawns> times is refused with an C<is_error>
saying so. A spawn that failed to start counts — a model retrying a
spawn that cannot work is exactly the loop this is for.

The tally is B<per parent run> by default (C<identical-spawn-scope>),
and that default matters: the guard is about a model going round in
circles within one turn of work. Three identical delegations across
three unrelated runs are three occasions on which somebody asked for the
same thing, and a composer that refused the fourth because of what
happened an hour ago would get more broken the longer the host stayed
up. C<< identical-spawn-scope => 'composer' >> is there for a host that
really does mean "this much and no more, ever".

B<The C<max-live> backstop> refuses a spawn while C<max-live> children
are already running, with a message telling the model to wait for what it
started. It is a backstop and not a queue: the refusal is immediate,
because a model blocked on an invisible queue looks exactly like a model
that has hung.

Both are checked and the child's slot is reserved in B<one> critical
section, so two spawns arriving at once cannot both take the last slot.

=head2 Cancelling, and the cascade

The first spawn of a batch registers on the parent run's C<cancellation>
Promise, so cancelling the parent cancels every child. That is a cascade,
not a wait: the parent's own cancel path does not wait for the children,
and a child that was mid-tool-call takes as long to wind down as it
takes. Every cancelled child's C<task> call settles as an C<is_error> —
the batch is never left hanging.

C<cancel-children> is the same thing for a shutdown path, and
C<live-agents> is what a UI renders while they run.

=head3 A child's life is longer than its call

Three moments, and they are all different:

=begin table

Moment          | What it means
================|=========================================================
child result    | the C<task> call is ANSWERED; the parent may carry on
child drained   | the child has stopped PRODUCING; the composer lets go
composer's slot | held from admission to drained, not to result

=end table

The parent is told as soon as the child has a result, because making a
model wait on a call nobody is waiting for is how a run stalls. But the
composer keeps the child — its C<max-live> slot, its place in
C<live-agents>, and the right to cancel it — until the child's
C<drained> Promise is kept.

That gap is not theoretical. A child that abandoned a tool call to a
deadline has a result while the abandoned call is still running, still
writing files; L<LLM::Agent::Run> is explicit that C<result> and
C<drained> diverge exactly there. A composer that let go at C<result>
would free the slot to start another child beside the one still working,
drop it out of whatever a UI is rendering, and — worst — leave
C<cancel-children> with nothing to cancel, so a shutdown would report
that everything had stopped while a tool call carried on.

=head3 Where a child's events go, and where they do not

Every event of a child is published through an emitter B<bound to the
run that spawned it>, captured before the child exists
(L<LLM::Agent::Loop>'s C<emitter-for>). Never through a fresh
"what is running now?" lookup, because for a child that outlives its
parent the answer to that question is B<the next run>:

=begin code :lang<text>

    run A spawns a child ─┐
    run A is cancelled    │  the child is still winding down
    run A finishes        │
    run B starts          │
                          └─► the child's last events arrive HERE

=end code

Published by a lookup, those events land on B: B's transcript grows
turns from a conversation it never had, and its C<seq> ordering acquires
events with no cause in it. Published through the captured emitter, they
are B<dropped> — the emitter answers False once its run is over, for
ever. The child's C<task> call still settles (as an C<is_error> when the
child was cancelled), because settling belongs to the call and not to
the stream.

The same binding covers the two session envelopes and the C<Log> event a
failed envelope write produces: everything the composer says about a
child belongs to the run that started it.

=head3 The window, and why there isn't one

Building a child is B<somebody else's code> — the spawn callback may
open a transcript, start a process, or queue behind three other agents —
so there is a stretch of time in which a spawn has been admitted and no
C<LLM::Agent::Run> exists yet. A cancel arriving in that stretch used to
find nothing to cancel and silently do nothing, which stranded the child
and hung its C<task> call. It is closed structurally rather than by
narrowing:

=item The B<slot is the cancellation target>, not the run. It is taken
before the spawn callback is called, and C<cancel-children> writes
C<cancel-requested> onto every slot — including the ones with no run yet
— under the same lock the spawn path registers its run with.

=item The parent run is captured B<once per batch>, before anything is
spawned, and the cascade is registered on it there. C<.then> on an
already-kept Promise fires immediately, so "cancelled before the spawn"
and "cancelled after it" are one case. (Looking the run up later is what
does not work: a cancelled parent has B<finished> by the time its
detached tool call gets around to spawning, and C<Loop.live-run> quite
correctly answers with nothing for a run that is over.)

=item There are B<two interception points> and they meet in the middle:
before the spawn callback is called (the child is never started at all),
and in the same critical section that registers the child's run (the
child is cancelled the moment there is something to cancel).

So, for a cancel arriving at each point of a child's life:

=begin table

It arrives                        | What stops the child
==================================|=========================================
before the task call is admitted  | the pre-spawn check (the captured parent is cancelled): never started
between the guard and the slot    | same check, one line later: never started
between the slot and the run      | the flag on the slot; registration reads it and cancels
after the run is registered       | cancel-children has the run and cancels it
after the result, before drained  | the slot is still held, so cancel-children still has it
after the child drained           | nothing to do: it has stopped

=end table

There is no ordering in which nothing happens, and every one of them
ends with the C<task> call settled — as an C<is_error> for a child that
was stopped, and as an ordinary answer for one that had already finished
saying it.

A child that is asked to stop and does not is the one case left, and it
is a bug in that child rather than a race: a cancelled run keeps its
result promptly, so one that has not after thirty seconds is answered
without — an C<is_error> saying its outcome is B<unknown>, in the same
words the loop uses for a tool call it stopped waiting for. The C<task>
call always settles.

=head2 What the transcript records

Two envelope types on the B<parent's> session, both through
C<< Session.append-event >>, so an older L<LLM::Agent> replays them as
unknown types and ignores them:

=begin table

Type              | Payload
==================|===================================================
subagent-spawned  | agent-id, agent-type, prompt, label?, child-path
subagent-settled  | agent-id, outcome, result, spent?

=end table

C<result> is an excerpt (2048 characters) of what the parent model was
given, not the child's whole transcript, and C<child-path> is a
B<pointer>: replaying the parent needs none of the children's files, and
a parent session whose children have been deleted resumes exactly as it
would have with them.

Writing either is B<shielded>. A transcript that cannot take an audit
record must never be the reason a working tool call fails; the failure
becomes a C<Log> event on the run instead.

=head2 Wiring: the loop is deferred

The composer needs the loop (to emit into its run) and the loop needs the
composer (it is the provider). Forward-declare the loop and hand this
class B<a Callable that returns it>:

=begin code :lang<raku>

my $loop;
my $subagents = LLM::Agent::Subagents.new(..., loop => { $loop });
$loop = LLM::Agent::Loop.new(:@backends, provider => $subagents);

=end code

C<< loop => $loop >> with C<$loop> still undefined does not work and
cannot be made to: the value is copied at construction, and what is
copied is C<Any>. C<set-loop> is the same fix for an app that would
rather assign than close over:

=begin code :lang<raku>

my $subagents = LLM::Agent::Subagents.new(...);          # no loop yet
my $loop = LLM::Agent::Loop.new(:@backends, provider => $subagents);
$subagents.set-loop($loop);

=end code

A composer with no loop still works: it spawns, it waits, it answers.
What it cannot do is publish the children's events anywhere, because
there is nothing to publish them onto.

=head2 Grants, and why there are two classes

The loop synchronises a provider's permission grants to the session only
when the provider C<.can('grants')> — so a composer that always had the
method would tell the loop to write grants for a stack that has none, and
one that never had it would B<silently break grant persistence> for an
C<MCP::Client::Policy> underneath it.

So C<.new> returns a C<LLM::Agent::Subagents::WithGrants> — a subclass
whose only content is a C<grants> method delegating to the inner
provider — when the inner provider has grants, and a plain
C<LLM::Agent::Subagents> when it does not. Both are
C<LLM::Agent::Subagents>, so nothing that type-checks or dispatches
notices; C<.can('grants')> answers honestly either way. Construct through
C<.new>, never through C<.bless>.

=head1 SEE ALSO

L<LLM::Agent::Loop> (C<emit-external>, the seam this publishes through),
L<LLM::Agent::Event> (the C<Subagent> event and its two-layer envelope),
L<LLM::Agent::Run>, L<LLM::Agent::Session> (C<append-event>),
L<MCP::Client::Policy> and L<MCP::Client::Registry> (the other two
composers of the same duck-typed pair).

=end pod

use JSON::Fast;

use LLM::Agent::Event;
use LLM::Agent::Loop;
use LLM::Agent::Run;

# LAST, and not alphabetically: this one is a `unit module` under the
# LLM::Agent namespace, and importing it ahead of the sibling classes
# shadows the lexical view of that namespace so that LLM::Agent::Run and
# LLM::Agent::Loop stop resolving by name further down. The same note is
# in LLM::Agent::Loop, where it bites hardest.
use LLM::Agent::Canonical;

# Forward-declared so that `new` can name it. Its real definition is at
# the bottom of the file, because it inherits from the class below.
class LLM::Agent::Subagents::WithGrants { ... }

class LLM::Agent::Subagents {

	#|( The tool the model calls to delegate. Not configurable on purpose:
	    it is a name models have seen in training, and a composer whose
	    tool is called something else in every app is a composer no model
	    has a prior about. )
	our constant TASK-TOOL = 'task';

	# How much of what came back the settle envelope keeps. The full text
	# is in the parent's conversation (and in the child's transcript); this
	# is the audit trail's copy, and an audit trail that stores a 400KB
	# review twice is one nobody greps.
	my constant SETTLE-EXCERPT = 2048;

	#|( Seconds to wait, after a child's result is kept, for its event
	    Supply to finish publishing. The Run keeps the result BEFORE it
	    enqueues the terminal event (see L<LLM::Agent::Run>), so without
	    this wait the terminal — and anything still in the mailbox behind
	    it — would be dropped by closing the tap. Normally microseconds; a
	    bound, not a delay. )
	my constant STREAM-GRACE = 10;

	# How often a child's result is checked while waiting for it, and how
	# long a child that has been asked to stop is given to do so before its
	# task call is answered without it. The poll rate is the loop's own
	# tool poll; the grace is generous on purpose, because the only thing
	# it can cut short is a child that is already misbehaving.
	my constant CANCEL-POLL = 0.05;
	my constant CANCEL-GRACE = 30;

	#| The provider underneath: anything with C<tools-for-llm> and
	#| C<execute-tool-calls>. Every call this composer does not own goes
	#| to it untouched.
	has $.inner is required;

	#| The spawn callback. See L</THE SPAWN CALLBACK>.
	has &.spawn is required;

	#|( The loop whose run the children's events are published onto: an
	    L<LLM::Agent::Loop>, or a Callable returning one (which is what a
	    forward-declared loop needs). Undefined until C<set-loop>, or for
	    ever, is allowed — see L</Wiring: the loop is deferred>. )
	has $.loop;

	#| The B<parent's> session, for the two envelopes. Optional; without
	#| one nothing about a child is durable on the parent's side.
	has $.session;

	#| How many children may run at once before a spawn is refused.
	has Int:D $.max-live = 4;

	#| How many times the same (agent-type, prompt) may be spawned within
	#| the tally's scope. See C<identical-spawn-scope>.
	has Int:D $.max-identical-spawns = 3;

	#|( What C<max-identical-spawns> counts against: C<run> (the default —
	    one tally per parent run, reset when the next run starts) or
	    C<composer> (one tally for this object's whole life).

	    C<run> is the default because the guard is about a model going
	    round in circles B<inside one turn of work>. Three identical
	    delegations across three unrelated runs are three occasions on
	    which a user asked for the same thing, and a fourth being refused
	    because of what happened yesterday is a composer that gets more
	    broken the longer the host stays up. C<composer> is there for a
	    host that means "this much and no more, ever". )
	has Str:D $.identical-spawn-scope = 'run';

	# The one lock, and a strict leaf: the spawn callback, the inner
	# provider, the child's Supply and the loop are all called with it
	# released.
	has Lock:D $!lock .= new;

	# agent-id => { seq, agent-id, agent-type, label, run, session-path }.
	# An entry exists from the moment a spawn is admitted (the slot is
	# reserved under the same lock the backstop counts under) until its
	# task call has settled.
	has %!children;

	# (agent-type, prompt) digest => how many times it has been spawned,
	# within $!counted-scope. Cleared when the scope changes, which under
	# the default (per parent run) is every new run.
	has %!spawn-counts;
	has Str $!counted-scope;

	has Int:D $!counter = 0;
	has Int:D $!seq = 0;

	# The parent run whose cancellation this composer has already hooked.
	# One scalar rather than a set: a loop runs one run at a time, so the
	# only run worth remembering is the current one.
	has Str $!hooked-run-id;

	# Set by set-loop, and preferred over $!loop when it is.
	has $!loop-late;

	has @!types;
	has %!type-index;

	#|( Build a composer. Returns a C<LLM::Agent::Subagents::WithGrants>
	    when the inner provider has grants, and a plain
	    C<LLM::Agent::Subagents> when it does not — see L</Grants, and why
	    there are two classes>. Both are C<LLM::Agent::Subagents>. )
	method new(*%args) {
		my $inner = %args<inner>;
		my $class = ($inner.defined && $inner.can('grants'))
			?? LLM::Agent::Subagents::WithGrants
			!! LLM::Agent::Subagents;
		$class.bless(|%args);
	}

	# `:@types` is caught here rather than declared as a public attribute
	# so that the table can be normalised into plain Hashes on the way in;
	# `*%` is load-bearing, because TWEAK is handed every named argument
	# that reached .new.
	submethod TWEAK(:@types, *%) {
		die 'LLM::Agent::Subagents: the inner provider must have both '
			~ 'tools-for-llm and execute-tool-calls (an MCP::Client, a '
			~ 'Registry, a Policy, or anything shaped like one); got '
			~ ($!inner.defined
				?? 'a ' ~ $!inner.^name
				!! 'the ' ~ $!inner.^name ~ ' type object')
			unless $!inner.defined && $!inner.can('tools-for-llm')
				&& $!inner.can('execute-tool-calls');

		die 'LLM::Agent::Subagents: spawn must be a Callable taking the '
			~ 'spec Hash — it is the whole of how a child gets built'
			unless &!spawn.defined;

		@!types = validate-types(@types);
		%!type-index = @!types.map({ $_<name> => $_ }).Hash;

		die 'LLM::Agent::Subagents: max-live must be at least 1 — a '
			~ 'composer that may never run a child publishes a tool that '
			~ 'always refuses'
			unless $!max-live >= 1;
		die 'LLM::Agent::Subagents: max-identical-spawns must be at least 1'
			unless $!max-identical-spawns >= 1;

		die "LLM::Agent::Subagents: identical-spawn-scope is "
			~ "'{$!identical-spawn-scope}'; it is 'run' (a tally per parent "
			~ "run) or 'composer' (one tally for this object's life)"
			unless $!identical-spawn-scope eq any('run', 'composer');

		die 'LLM::Agent::Subagents: loop must be an LLM::Agent::Loop or a '
			~ 'Callable returning one (which is what a forward-declared '
			~ 'loop needs: `loop => { $loop }`); got a ' ~ $!loop.^name
			if $!loop.defined
				&& !($!loop ~~ Callable || $!loop ~~ LLM::Agent::Loop);

		die 'LLM::Agent::Subagents: a session must be an LLM::Agent::Session '
			~ '(or something with its append-event method); got a '
			~ $!session.^name
			if $!session.defined && !$!session.can('append-event');
	}

	# === The public surface ===

	#| The agent types this composer was built with, as a deep plain-data
	#| copy: safe to render, and safe to hand to a UI that edits what it
	#| is given.
	method types(--> List:D) {
		@!types.map({ $_.Hash }).List;
	}

	#| Just the names, in table order — the enum the C<task> tool
	#| publishes.
	method type-names(--> List:D) {
		@!types.map({ $_<name> }).List;
	}

	#|( Bind the loop after construction, for an app that would rather
	    assign than close over a forward-declared one. Takes an
	    L<LLM::Agent::Loop> or a Callable returning one, and replaces
	    whatever C<loop> was built with. )
	method set-loop($loop --> Nil) {
		die 'LLM::Agent::Subagents.set-loop: expected an LLM::Agent::Loop '
			~ 'or a Callable returning one; got '
			~ ($loop.defined ?? 'a ' ~ $loop.^name
				!! 'the ' ~ $loop.^name ~ ' type object')
			unless $loop.defined
				&& ($loop ~~ Callable || $loop ~~ LLM::Agent::Loop);

		$!lock.protect: { $!loop-late = $loop };
		Nil;
	}

	#|( The children this composer owns, oldest first, as plain data:
	    C<< { agent-id, agent-type, label, session-path, starting,
	    draining } >>. What a UI renders beside the parent's transcript,
	    and what a test asserts the C<max-live> backstop against.

	    An entry spans the whole of a child's life, which is B<wider at
	    both ends> than its C<task> call:

	    =item it appears the moment a spawn is B<admitted>, before the
	    spawn callback has been called, because that is when the
	    C<max-live> slot is taken. C<starting> is True until there is a
	    child run behind it — those are cancellable exactly like the rest
	    (see C<cancel-children>), they just have nothing to render yet;

	    =item it survives the C<task> call's answer and disappears only
	    when the child has B<drained>. C<draining> is True in between: the
	    child answered, the parent has been told, and something the child
	    detached — a tool call it abandoned to a deadline — is still
	    running. It is still this composer's to cancel. )
	method live-agents(--> List:D) {
		$!lock.protect: {
			%!children.values.sort({ $_<seq> }).map({
				my Bool $has-run = $_<run> ~~ LLM::Agent::Run:D;
				%(
					agent-id     => $_<agent-id>,
					agent-type   => $_<agent-type>,
					label        => $_<label>,
					session-path => $_<session-path>,
					starting     => !$has-run,
					# Answered, and still producing: its run is done and its
					# `drained` is not. See cancel-children.
					draining     => $has-run && $_<run>.is-done,
				);
			}).List;
		};
	}

	#|( Ask every child to stop, and answer how many were asked.
	    Idempotent and safe from any thread — C<Run.cancel> is both, and
	    is a total no-op on a child that has already finished.

	    B<It reaches a child that does not exist yet.> A spawn takes its
	    slot before the spawn callback is called, and building a child run
	    is somebody else's code and can take as long as it likes, so
	    "cancel everything" arriving in the middle of one has to mean
	    something. It does: the request is B<recorded on the slot>, and
	    the spawn path cancels the child the moment it has one to cancel —
	    or never starts it at all, if the request got there first. Either
	    way that C<task> call settles as an C<is_error> rather than
	    hanging, which is the property that matters and the one a
	    C<Run:D>-only sweep of the table quietly did not have.

	    The cascade calls this on the parent's cancellation; call it
	    yourself from a shutdown path. It does B<not> wait: each child's
	    C<task> call settles when that child's run ends, which is as long
	    as its tool batch takes. )
	method cancel-children(--> Int:D) {
		# The flag and the snapshot in ONE critical section, so a spawn
		# that registers its run concurrently either lands before this (and
		# is in @runs) or after it (and reads the flag). Cancelled outside
		# the lock: `.cancel` runs the child driver's on-cancel hook, and
		# this lock is a leaf.
		my Int $asked = 0;
		my @runs = $!lock.protect: {
			my @live;
			for %!children.values -> %child {
				%child<cancel-requested> = True;
				$asked++;
				@live.push: %child<run> if %child<run> ~~ LLM::Agent::Run:D;
			}
			@live.List;
		};

		for @runs -> $run {
			try $run.cancel;
		}
		$asked;
	}

	# === The bridge ===

	#|( The inner provider's declarations plus the C<task> tool, whose
	    C<agent-type> enum is this composer's table.

	    An inner provider that publishes a C<task> tool of its own has it
	    B<dropped> from the catalogue rather than published twice: two
	    declarations with one name is a request several providers reject
	    outright, and the composer owns the name it routes on.

	    Throws whatever the inner provider throws while listing. )
	method tools-for-llm(--> List) {
		my @published = $!inner.tools-for-llm.list.grep({
			(tool-name-of($_) // '') ne TASK-TOOL;
		});
		(|@published, self!task-declaration).List;
	}

	#|( Every call, answered: the C<task> calls here, everything else
	    forwarded to the inner provider as one batch, and one result per
	    call in the caller's order.

	    B<Never throws.> A malformed call, an unknown agent type, a guard
	    that refused, a spawn callback that died, a child that failed and
	    an inner provider that threw all come back as C<is_error> results.

	    Within a mixed batch the inner calls are dispatched first, as one
	    batch, and the C<task> calls afterwards in order. The loop
	    dispatches one call at a time, so a mixed batch only reaches here
	    from a caller that batches for itself. )
	method execute-tool-calls(@tool-calls --> List) {
		my @results;
		my @forward;
		my @tasks;

		# THE PARENT RUN, captured ONCE, here, before anything is spawned —
		# and held for the whole batch rather than looked up again later.
		# `Loop.live-run` answers with nothing for a run that has finished,
		# and a cancelled parent finishes while this batch is still being
		# dispatched (the loop detaches the call it cancelled), so a lookup
		# taken any later than this can legitimately come back empty and
		# leave a child with nothing watching it. Captured, it is still the
		# run whose `cancellation` this batch belongs to, done or not.
		my $parent = self!parent-run;

		for @tool-calls.kv -> $index, $call {
			my $id = $call ~~ Associative ?? ($call<id> // '').Str !! '';
			my $name = tool-name-of($call);

			# A call whose name cannot be read is not one this composer can
			# claim, so it goes to the inner provider — which answers it
			# with its own well-formed error rather than a second opinion
			# invented here.
			if $name.defined && $name eq TASK-TOOL {
				@tasks.push: %( :$index, :$id, call => $call );
			}
			else {
				@forward.push: %( :$index, :$id, call => $call );
			}
		}

		if @forward.elems {
			my @calls = @forward.map({ $_<call> }).List;
			my @answers;
			my $failure;
			{
				CATCH { default { $failure = $_ } }
				# `.eager`, and it is not decoration: a provider that hands
				# back a LAZY list has not done the work yet, and reifying
				# it where the results are indexed — below, outside this
				# CATCH — would turn a provider that throws into an
				# exception this method promises never to raise.
				@answers = $!inner.execute-tool-calls(@calls).list.eager;
			}

			for @forward.kv -> $at, %item {
				@results[%item<index>] = $failure.defined
					?? error-result(
						%item<id>,
						'The tool provider failed: '
							~ ($failure.message.lines.head // $failure.^name),
					)
					!! normalized-result(@answers[$at], %item<id>);
			}
		}

		for @tasks -> %item {
			# Belt and braces around a method that already answers rather
			# than throwing: "never throws" is the provider contract, and a
			# future edit that forgets it must not take the run down.
			my $answer;
			my $threw;
			{
				CATCH { default { $threw = $_ } }
				$answer = self!run-task(%item<call>, %item<id>, $parent);
			}

			@results[%item<index>] = $threw.defined
				?? error-result(
					%item<id>,
					'The subagent layer failed: '
						~ ($threw.message.lines.head // $threw.^name),
				)
				!! $answer;
		}

		@results.List;
	}

	# === One task call ===

	# The whole of a delegation: read it, guard it, spawn it, forward its
	# events, wait for it, record it. Answers with a result Hash on every
	# path; the only throws it can make are the ones the caller shields.
	method !run-task($call, Str:D $id, $parent --> Hash:D) {
		my $function = $call ~~ Associative ?? $call<function> !! Any;
		my $arguments = parsed-arguments(
			$function ~~ Associative ?? $function<arguments> !! Str,
		);

		return error-result(
			$id,
			"The arguments to '{TASK-TOOL}' are not a JSON object. Call it "
				~ 'with { "agent-type": "<one of '
				~ self.type-names.join('|') ~ '>", "prompt": "<the whole '
				~ 'task>" }.',
		) without $arguments;

		my $raw-type = $arguments<agent-type>;
		return error-result(
			$id,
			"The '{TASK-TOOL}' call has no agent-type. The agent types are: "
				~ self!catalogue-line ~ '.',
		) unless $raw-type ~~ Str:D && $raw-type.trim.chars;

		my Str $type-name = $raw-type.trim;
		my $type = %!type-index{$type-name};
		return error-result(
			$id,
			"There is no '$type-name' agent. The agent types are: "
				~ self!catalogue-line ~ '.',
		) unless $type ~~ Associative;

		my $raw-prompt = $arguments<prompt>;
		return error-result(
			$id,
			"The '{TASK-TOOL}' call has no prompt. The $type-name agent "
				~ 'starts from a blank conversation and sees nothing of this '
				~ 'one, so the prompt has to carry every fact it needs.',
		) unless $raw-prompt ~~ Str:D && $raw-prompt.trim.chars;

		my Str $prompt = $raw-prompt.Str;
		my Str $label = $arguments<label> ~~ Str:D && $arguments<label>.trim.chars
			?? $arguments<label>.trim
			!! Str;

		# The two guards and the slot reservation, in ONE critical section:
		# two spawns arriving at once must not both see room for the last
		# child, and neither must slip past a cap the other just took.
		my Str $digest = data-digest(
			%( agent-type => $type-name, prompt => $prompt.trim ),
		);
		# The tally's scope. Per parent run by default: three identical
		# spawns are a model going round in circles WITHIN one run, and a
		# fresh run asking the same question is a fresh question — the
		# user has typed something since. `composer` keeps the old
		# behaviour for a host that wants one cap over everything.
		my Str $scope = $!identical-spawn-scope eq 'composer'
			?? ''
			!! ($parent.defined ?? $parent.id !! '');

		my Str $agent-id;
		my Str $refusal;
		$!lock.protect: {
			# Per-run scope keeps ONE run's tally: the previous run's is of
			# no further interest, and a table that grew an entry per run
			# per distinct delegation for the life of a host would be a
			# slow leak.
			if $!identical-spawn-scope ne 'composer'
				&& !($!counted-scope eqv $scope) {
				%!spawn-counts = ();
				$!counted-scope = $scope;
			}

			if %!children.elems >= $!max-live {
				$refusal = "There are already {%!children.elems} subagents "
					~ "running, which is the limit ({$!max-live}). Wait for "
					~ 'one of them to answer before starting another, or do '
					~ 'this piece of work yourself.';
			}
			elsif (%!spawn-counts{$digest} // 0) >= $!max-identical-spawns {
				$refusal = "The $type-name agent has already been given this "
					~ "exact task {$!max-identical-spawns} times, which is "
					~ 'the limit. Starting it again would produce the same '
					~ 'answer: use what it said, change the task, or do the '
					~ 'work here.';
			}
			else {
				%!spawn-counts{$digest}++;
				$agent-id = $type-name ~ '-' ~ ++$!counter;
				# THE SLOT, and it is a cancellation target from this
				# moment on: `run` is filled in later (building a child is
				# somebody else's code and takes as long as it takes), and
				# `cancel-requested` is what a cancel arriving in that gap
				# writes instead of finding nothing to cancel.
				%!children{$agent-id} = %(
					seq              => $!seq++,
					agent-id         => $agent-id,
					agent-type       => $type-name,
					label            => $label,
					run              => LLM::Agent::Run,
					session-path     => '',
					cancel-requested => False,
				);
			}
		};

		return error-result($id, $refusal) if $refusal.defined;

		self!spawn-and-settle(
			$id, $agent-id, $type.Hash, $type-name, $prompt, $label, $parent,
		);
	}

	# The half of a task call that owns a reserved child slot: spawn,
	# forward, wait, record. The slot is released HERE only on the paths
	# where no child was ever started — once one has been, its life is the
	# child's `drained` Promise and nothing else (see !own-child).
	method !spawn-and-settle(
		Str:D $id, Str:D $agent-id, %type, Str:D $type-name, Str:D $prompt,
		$label, $parent,
		--> Hash:D
	) {
		# THE EMITTER, bound to the run this batch belongs to and captured
		# before anything can start: the child may outlive this run, and
		# publishing its events onto whatever run is live when they arrive
		# would put another run's turns in this one's stream. See
		# LLM::Agent::Loop's emitter-for.
		my &emit = self!emitter-for($parent);

		# BEFORE the child is built, not after: the cascade is registered
		# on the run this batch belongs to, and `.then` on a Promise that
		# is ALREADY kept fires immediately — so a parent cancelled before
		# this line and one cancelled after it take the same path.
		self!hook-cancel($parent);

		# The first of the two interception points. A cancel that got here
		# first means the cheapest possible answer: do not start a child at
		# all. (The second is after registration, below — between them they
		# cover every interleaving; see the module Pod.)
		if self!stop-requested($agent-id, $parent) {
			self!release-child($agent-id);
			return self!cancelled-result(
				$id, $agent-id, $type-name, &emit, :!started,
			);
		}

		my $handle;
		my $threw;
		{
			CATCH { default { $threw = $_ } }
			$handle = &!spawn(%(
				agent-id => $agent-id,
				type     => %type.Hash,
				prompt   => $prompt,
				label    => $label,
			));
		}

		if $threw.defined {
			self!release-child($agent-id);
			return error-result(
				$id,
				"The $type-name agent could not be started: "
					~ ($threw.message.lines.head // $threw.^name),
			);
		}

		unless $handle.defined && $handle.can('run')
			&& $handle.can('session-path') {
			self!release-child($agent-id);
			return error-result(
				$id,
				"The $type-name agent could not be started: its spawn "
					~ 'callback answered with '
					~ ($handle.defined ?? 'a ' ~ $handle.^name !! 'nothing')
					~ ', which has no run and session-path.',
			);
		}

		my $child = $handle.run;
		unless $child ~~ LLM::Agent::Run:D {
			self!release-child($agent-id);
			return error-result(
				$id,
				"The $type-name agent could not be started: its handle's "
					~ '.run is '
					~ ($child.defined ?? 'a ' ~ $child.^name !! 'undefined')
					~ ', not a live LLM::Agent::Run.',
			);
		}

		my $raw-path = $handle.session-path;
		my Str $child-path = $raw-path.defined ?? $raw-path.Str !! '';

		# Registration and the second interception point are ONE critical
		# section, and that is the whole of the fix: a `cancel-children`
		# running concurrently either sets the flag before this (and we
		# read it here, and cancel the child ourselves) or after it (and
		# finds the run in the table and cancels it directly). There is no
		# third outcome and therefore no window.
		my Bool $stop = $!lock.protect: {
			if %!children{$agent-id}:exists {
				%!children{$agent-id}<run> = $child;
				%!children{$agent-id}<session-path> = $child-path;
				?%!children{$agent-id}<cancel-requested>;
			}
			else {
				# The slot is gone, which only happens if this call has
				# already been left. Nothing owns the child but us.
				True;
			}
		};

		# THE SLOT'S LIFE, arranged the instant there is a child to hold it
		# for and before anything below can throw: a child is this
		# composer's business until it has stopped PRODUCING, which is
		# `drained` and not `result`. See !own-child.
		self!own-child($agent-id, $child);

		# Outside the lock, and belt-and-braces on the parent as well as on
		# the flag: a parent that was cancelled while the spawn callback
		# was running may have been cancelled before the hook above could
		# see it as anything but Planned.
		$child.cancel if $stop || ($parent.defined && $parent.is-cancelled);

		self!append-envelope('subagent-spawned', %(
			agent-id   => $agent-id,
			agent-type => $type-name,
			prompt     => $prompt,
			label      => $label,
			child-path => $child-path,
		), &emit);

		self!settle-child(
			$child, $id, $agent-id, $type-name, $label, $parent, &emit,
		);
	}

	#|( Hold this child's slot until it has B<drained>, not until it has a
	    result.

	    The two come apart, and the gap is exactly where a subagent is at
	    its most dangerous: a child that abandoned a tool call to a
	    deadline has its C<result> Kept — the parent gets its answer, which
	    is right, a model should not wait on a call nobody is waiting for —
	    while the detached call is still running somewhere, writing files.
	    A composer that let go at C<result> would drop that child from
	    C<live-agents>, free its C<max-live> slot to start another, and
	    leave C<cancel-children> with nothing to cancel: a shutdown that
	    reports everything stopped while a tool call runs on.

	    So the slot — and with it the accounting and the cancellation
	    ownership — is released by the child's own C<drained> Promise, on
	    whatever thread keeps it. See L<LLM::Agent::Run>. )
	method !own-child(Str:D $agent-id, LLM::Agent::Run:D $child --> Nil) {
		$child.drained.then({ try self!release-child($agent-id); True });
		Nil;
	}

	# Let go of one child's slot. Idempotent: the drained hook and the
	# never-started paths can both reach it.
	method !release-child(Str:D $agent-id --> Nil) {
		$!lock.protect: { %!children{$agent-id}:delete };
		Nil;
	}

	# Tap the child, wait for it, and turn what it did into a result. The
	# tap is the child's ONLY one: a Supplier::Preserving delivers its
	# buffer to the first tap and replays nothing to a second, so a child
	# tapped anywhere else has already lost its beginning to whoever got
	# there first.
	method !settle-child(
		LLM::Agent::Run:D $child, Str:D $id, Str:D $agent-id,
		Str:D $type-name, $label, $parent, &emit,
		--> Hash:D
	) {
		my $published = Promise.new;
		my $vow = $published.vow;

		my $tap = $child.events.tap(
			-> $event {
				self!forward($agent-id, $type-name, $label, $event, &emit);
			},
			# `try`, because keeping a vow twice throws and a Supply that
			# somehow did both would take the tap's thread with it.
			done => { try $vow.keep(True) },
			quit => -> $ { try $vow.keep(True) },
		);
		LEAVE { try $tap.close }

		# The ordinary case: wait for the child for as long as it takes —
		# the task call IS the child's runtime, and bounding that would be
		# this layer inventing a deadline the loop already owns one of.
		#
		# The exception is a child that has been ASKED to stop. A cancelled
		# run keeps its result promptly by contract (it does not wait for a
		# detached tool batch), so one still Planned this long after being
		# told is one that waiting longer will not settle — and a task call
		# that hangs for ever on it is strictly worse than a call that says
		# so. See !unstoppable-result.
		my Instant $give-up;
		until $child.result.status !~~ Planned {
			await Promise.anyof($child.result, Promise.in(CANCEL-POLL));
			last if $child.result.status !~~ Planned;

			if self!stop-requested($agent-id, $parent) {
				$give-up //= now + CANCEL-GRACE;
				last if now > $give-up;
			}
		}

		return self!unstoppable-result($id, $agent-id, $type-name, &emit)
			if $child.result.status ~~ Planned;

		# The result is kept BEFORE the terminal event is enqueued (see
		# LLM::Agent::Run), so the stream is still one event behind here.
		# Waiting for its `done` is what makes the terminal reach the
		# parent's stream; the bound is what stops a wedged subscriber
		# holding the parent's tool call open for ever.
		await Promise.anyof($published, Promise.in(STREAM-GRACE));

		my %result = $child.result.result.Hash;
		my Str $outcome = (%result<outcome> // 'failed').Str;
		my Str $final = (%result<final> // '').Str;
		my Str $error = %result<error>.defined ?? %result<error>.Str !! Str;
		my Str $reason = %result<reason>.defined ?? %result<reason>.Str !! Str;

		my Bool $is-error = $outcome ne 'completed';
		my Str $content = do given $outcome {
			when 'completed' {
				$final.trim.chars
					?? $final
					!! "The $type-name agent ($agent-id) finished without "
						~ 'saying anything. There is nothing to act on: run '
						~ 'it again with a more specific task, or do the work '
						~ 'here.';
			}
			when 'cancelled' {
				"The $type-name agent ($agent-id) was cancelled before it "
					~ 'finished, so it produced no answer. Whatever it had '
					~ 'already done still happened.';
			}
			default {
				"The $type-name agent ($agent-id) failed: "
					~ ($error.defined ?? $error !! 'no reason given')
					~ ($reason.defined ?? " (reason: $reason)" !! '');
			}
		};

		my %payload =
			agent-id => $agent-id,
			outcome  => $outcome,
			result   => excerpt($content, SETTLE-EXCERPT),
		;
		# The one conditional key, for the reason the run result's is: a
		# child nobody was counting says nothing rather than a zero it did
		# not measure.
		%payload<spent> = %result<spent>.Hash if %result<spent> ~~ Associative;
		self!append-envelope('subagent-settled', %payload, &emit);

		%(
			role         => 'tool',
			tool_call_id => $id,
			content      => $content,
			is_error     => $is-error,
		);
	}

	#|( One child event, wrapped and published on the stream of the run
	    that spawned it — B<through the emitter captured at spawn time>,
	    never through a fresh lookup.

	    A child outlives its parent often enough for this to be the whole
	    point: it is winding down after a cancel, or it was detached at a
	    deadline and is still working. Its events then arrive when the
	    loop's C<live-run> is a B<different run>, and publishing them there
	    would file one conversation's turns under another. The captured
	    emitter answers False instead and the event is dropped, which is
	    the only honest thing left to do with it. )
	method !forward(
		Str:D $agent-id, Str:D $agent-type, $label, $event, &emit,
		--> Nil
	) {
		return unless $event ~~ LLM::Agent::Event:D;

		&emit(LLM::Agent::Event::Subagent.new(
			:$agent-id, :$agent-type, :$label, inner => $event.to-hash,
		));
		Nil;
	}

	# The run this batch belongs to, or an undefined Run when there is no
	# loop, or no run in flight on it. Called ONCE per batch — see
	# execute-tool-calls on why a later lookup is not the same thing.
	method !parent-run() {
		my $loop = self!resolve-loop;
		$loop.defined ?? $loop.live-run !! LLM::Agent::Run;
	}

	#|( A publisher bound to C<$parent> for the life of one child, or a
	    Callable that always refuses when there is no loop or no run to
	    bind to. Everything this composer emits about a child goes through
	    one of these — see C<!forward>. )
	method !emitter-for($parent --> Callable:D) {
		# The refusing stand-in, which is also what a composer with no loop
		# at all uses: a subagent still runs, it just has nowhere to
		# report. Same answer, same shape, no special case downstream.
		return -> $ { False } unless $parent.defined;

		my $loop = self!resolve-loop;
		return -> $ { False } unless $loop.defined;

		$loop.emitter-for($parent);
	}

	#|( Register the cascade on this parent run's cancellation, once per
	    run. C<.then> on an already-kept Promise fires immediately, so a
	    parent cancelled before this call and one cancelled after it are
	    the same case — which is what lets everything else here be a
	    check of one flag. )
	method !hook-cancel($run --> Nil) {
		return unless $run.defined;

		my Bool $first = $!lock.protect: {
			($!hooked-run-id.defined && $!hooked-run-id eq $run.id)
				?? False
				!! do { $!hooked-run-id = $run.id; True };
		};
		return unless $first;

		# Outside the lock, and `try`-shielded: `.then` schedules our code
		# on somebody else's thread, and a broken Promise nobody awaits is
		# a warning at GC time in a run that ended minutes ago.
		$run.cancellation.then({ try self.cancel-children; True });
		Nil;
	}

	# Whether this child has been told to stop before it could start: by
	# `cancel-children` writing the flag on its slot, or by the parent run
	# this batch belongs to being cancelled.
	method !stop-requested(Str:D $agent-id, $parent --> Bool:D) {
		my Bool $flagged = $!lock.protect: {
			%!children{$agent-id}:exists
				?? ?%!children{$agent-id}<cancel-requested>
				!! True;
		};
		$flagged || ($parent.defined && $parent.is-cancelled);
	}

	# The answer for a child that was cancelled: never started, or started
	# and cancelled before it could say anything. Both are the same fact
	# from the model's side — no answer came back — and neither is a
	# failure of the tool.
	method !cancelled-result(
		Str:D $id, Str:D $agent-id, Str:D $type-name, &emit,
		Bool:D :$started = True,
		--> Hash:D
	) {
		my Str $content = $started
			?? "The $type-name agent ($agent-id) was cancelled before it "
				~ 'finished, so it produced no answer. Whatever it had '
				~ 'already done still happened.'
			!! "The $type-name agent ($agent-id) was cancelled before it "
				~ 'started. It did not run.';

		self!append-envelope('subagent-settled', %(
			agent-id => $agent-id,
			outcome  => 'cancelled',
			result   => $content,
		), &emit);

		error-result($id, $content);
	}

	#|( The answer for a child that was asked to stop and did not. Not a
	    result and not a failure of the work: like the loop's own
	    outcome-unknown tool message, it says the one honest thing —
	    whether the child took effect is not known — because a child run
	    that ignores its own cancellation is a bug in that child, and the
	    parent must neither invent an answer for it nor wait for ever. )
	method !unstoppable-result(
		Str:D $id, Str:D $agent-id, Str:D $type-name, &emit,
		--> Hash:D
	) {
		my Str $content = "The $type-name agent ($agent-id) was asked to stop "
			~ "and did not, so this call was abandoned after {CANCEL-GRACE} "
			~ 'seconds. Whatever it had done, or is still doing, is unknown.';

		self!append-envelope('subagent-settled', %(
			agent-id => $agent-id,
			outcome  => 'outcome-unknown',
			result   => $content,
		), &emit);

		error-result($id, $content);
	}

	# === Seams ===

	# The loop, however it was supplied, or the type object when there is
	# none to be had. NEVER a type object with a method called on it: that
	# is the trap this whole deferred-Callable dance exists to avoid.
	method !resolve-loop() {
		my $candidate = $!lock.protect: { $!loop-late // $!loop };
		return LLM::Agent::Loop unless $candidate.defined;

		my $loop = $candidate;
		if $candidate ~~ Callable {
			# A closure over a forward declaration can be called before the
			# thing it closes over exists, and an app's closure can do
			# anything at all; neither is a reason to fail a tool call.
			$loop = Nil;
			try $loop = $candidate();
		}

		($loop.defined && $loop ~~ LLM::Agent::Loop)
			?? $loop
			!! LLM::Agent::Loop;
	}

	# One envelope on the parent's session, shielded: an audit record that
	# cannot be written must never be the reason a working tool call
	# fails. The failure becomes a Log event on the run instead, which is
	# where somebody will see it.
	method !append-envelope(Str:D $type, %payload, &emit --> Nil) {
		return unless $!session.defined;

		my $threw;
		{
			CATCH { default { $threw = $_ } }
			$!session.append-event(:$type, payload => %payload);
		}
		return unless $threw.defined;

		# Through the child's own emitter, like everything else it says:
		# a warning about run A's transcript has no business appearing in
		# run B's stream either.
		try &emit(LLM::Agent::Event::Log.new(
			level  => 'warning',
			logger => 'llm-agent.subagents',
			data   => %(
				message => "the $type record could not be written to the "
					~ 'transcript; the subagent itself is unaffected',
				agent-id => (%payload<agent-id> // '').Str,
				error    => ($threw.message.lines.head // $threw.^name),
			),
		));
		Nil;
	}

	# === The task declaration ===

	method !task-declaration(--> Hash:D) {
		{
			type     => 'function',
			function => {
				name        => TASK-TOOL,
				description => self!task-description,
				parameters  => {
					type       => 'object',
					properties => {
						agent-type => {
							type        => 'string',
							enum        => self.type-names,
							description => 'Which agent to run.',
						},
						prompt => {
							type        => 'string',
							description => 'The whole task, in full. The '
								~ 'agent starts from a blank conversation '
								~ 'and sees nothing of this one, so every '
								~ 'fact it needs has to be in here.',
						},
						label => {
							type        => 'string',
							description => 'A short name for this piece of '
								~ 'work, shown to the user while it runs.',
						},
					},
					required => ('agent-type', 'prompt'),
				},
			},
		};
	}

	method !task-description(--> Str:D) {
		"Delegate one self-contained piece of work to a subagent and wait "
			~ "for its answer.\n"
			~ "The subagent runs its own tool loop in a conversation of its "
			~ "own: it sees NOTHING of this one, and only its final message "
			~ "comes back — as the result of this call.\n"
			~ "Use it for work that is worth a whole conversation of its "
			~ "own; do small things yourself.\n"
			~ "The agents available are:\n"
			~ @!types.map({ '- ' ~ $_<name> ~ ': ' ~ $_<description> })
				.join("\n");
	}

	method !catalogue-line(--> Str:D) {
		self.type-names.map({ "'$_'" }).join(', ');
	}
}

#|( A composer over a provider that has permission grants — an
    L<MCP::Client::Policy>, or anything else with a C<grants> method.

    Its whole content is that one delegating method, and it exists
    because C<.can('grants')> is what tells L<LLM::Agent::Loop> whether to
    persist grants to the session: a composer that answered True for a
    stack with no grants, or False for one with them, would break that in
    one direction or the other. C<LLM::Agent::Subagents.new> picks
    between the two; do not construct this directly. )
class LLM::Agent::Subagents::WithGrants is LLM::Agent::Subagents {
	#| The inner provider's grant snapshot, untouched. Delegating rather
	#| than caching: the snapshot is a copy already, and a composer that
	#| kept one would answer with what the policy used to think.
	method grants(--> List:D) {
		self.inner.grants.list.List;
	}
}

# === Module-private helpers ===

# The tool name a call or a declaration carries, or an undefined Str for
# anything shaped differently. Deliberately total: everything here is
# handed data that came from a model or from somebody else's provider.
my sub tool-name-of($item --> Str) {
	return Str unless $item ~~ Associative;
	my $function = $item<function>;
	return Str unless $function ~~ Associative;
	$function<name> ~~ Str:D ?? $function<name>.Str !! Str;
}

# Tool-call arguments as a Hash: the JSON object models send, or one
# already decoded. An undefined return means "this could not be read as
# an object", which is a different answer from an empty one.
my sub parsed-arguments($raw) {
	return %() without $raw;
	return $raw.Hash if $raw ~~ Associative;

	my Str $text = $raw.Str.trim;
	return %() unless $text.chars;
	# Only what could be a JSON object is offered to the parser: JSON::Fast
	# builds its parse errors through a deprecated method, so a caught
	# failure still prints a deprecation notice at exit.
	return Nil unless $text.starts-with('{');

	my $parsed;
	my Bool $ok = so try { $parsed = from-json($text); True };
	($ok && $parsed ~~ Associative) ?? $parsed.Hash !! Nil;
}

# The agent-type table, checked once at construction. Every failure here
# is a wiring mistake somebody wants to hear about while they are looking
# at the wiring.
my sub validate-types(@types --> List) {
	die 'LLM::Agent::Subagents: types contains Pairs, which means a single '
		~ "Hash hit Raku's single-argument rule: a lone hash inside square "
		~ 'brackets flattens into that hash\'s pairs. Add a trailing comma — '
		~ 'types => [ %type, ] — or pass a List of two or more hashes.'
		if @types.first({ $_ ~~ Pair });

	die 'LLM::Agent::Subagents: types is empty — a composer with no agent '
		~ 'types publishes a task tool that can never be called'
		unless @types.elems;

	my %seen;
	my @out;

	for @types.kv -> Int $index, $type {
		die "LLM::Agent::Subagents: type $index is a " ~ $type.^name
			~ ', which is not a { name => ..., description => ... } hash'
			unless $type ~~ Associative;

		my %record = $type.Hash;

		die "LLM::Agent::Subagents: type $index has no name — the name is "
			~ 'what the model calls it by'
			unless %record<name> ~~ Str:D && %record<name>.trim.chars;

		my Str $name = %record<name>.Str;

		die "LLM::Agent::Subagents: the '$name' type has no description — "
			~ 'the description is the whole of what the model is told about '
			~ 'when to use it'
			unless %record<description> ~~ Str:D
				&& %record<description>.trim.chars;

		die "LLM::Agent::Subagents: two agent types are both called '$name'; "
			~ 'the name is what a task call names, so it has to be unique'
			if %seen{$name}++;

		@out.push: %record;
	}

	@out.List;
}

# $text, cut to $limit characters with a marker saying how much is gone.
# For the transcript's copy of a result, never for what the model saw.
my sub excerpt(Str:D $text, Int:D $limit --> Str:D) {
	return $text unless $text.chars > $limit;
	my Int $elided = $text.chars - $limit;
	$text.substr(0, $limit) ~ "\n[... $elided characters elided ...]";
}

# The result shapes, matching MCP::Client::Registry's exactly: whatever
# stack a composer is dropped into, an error from this layer has to look
# like an error from the layer underneath it.
my sub error-result($id, Str:D $content --> Hash:D) {
	{
		role         => 'tool',
		tool_call_id => $id,
		content      => $content,
		is_error     => True,
	};
}

my sub normalized-result($answer, $id --> Hash:D) {
	return {
		role         => 'tool',
		tool_call_id => $id,
		content      => 'The tool provider returned no result for this call',
		is_error     => True,
	} without $answer;

	unless $answer ~~ Associative {
		return {
			role         => 'tool',
			tool_call_id => $id,
			content      => ~$answer,
			is_error     => False,
		};
	}

	my %result = $answer.Hash;
	%result<role> = 'tool' unless %result<role>:exists;
	%result<tool_call_id> = $id unless %result<tool_call_id>:exists;
	%result;
}
