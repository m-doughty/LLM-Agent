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
more than C<max-identical-spawns> times B<in the composer's lifetime> is
refused with an C<is_error> saying so. A spawn that failed to start
counts — a model retrying a spawn that cannot work is exactly the loop
this is for.

B<The C<max-live> backstop> refuses a spawn while C<max-live> children
are already running, with a message telling the model to wait for what it
started. It is a backstop and not a queue: the refusal is immediate,
because a model blocked on an invisible queue looks exactly like a model
that has hung.

Both are checked and the child's slot is reserved in B<one> critical
section, so two spawns arriving at once cannot both take the last slot.

=head2 Cancelling, and the cascade

The first spawn of a given parent run registers on that run's
C<cancellation> Promise, so cancelling the parent cancels every live
child. That is a cascade, not a wait: the parent's own cancel path does
not wait for the children, and a child that was mid-tool-call takes as
long to wind down as it takes. Each cancelled child's C<task> call
settles as an C<is_error> — the batch is never left hanging.

C<cancel-children> is the same thing for a shutdown path, and
C<live-agents> is what a UI renders while they run.

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

	#| How many times the same (agent-type, prompt) may be spawned in this
	#| composer's lifetime.
	has Int:D $.max-identical-spawns = 3;

	# The one lock, and a strict leaf: the spawn callback, the inner
	# provider, the child's Supply and the loop are all called with it
	# released.
	has Lock:D $!lock .= new;

	# agent-id => { seq, agent-id, agent-type, label, run, session-path }.
	# An entry exists from the moment a spawn is admitted (the slot is
	# reserved under the same lock the backstop counts under) until its
	# task call has settled.
	has %!children;

	# (agent-type, prompt) digest => how many times it has been spawned.
	# Never pruned: the cap is over the composer's lifetime, and a table
	# with one entry per distinct delegation is not a leak.
	has %!spawn-counts;

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

	#|( The children running right now, oldest first, as plain data:
	    C<< { agent-id, agent-type, label, session-path } >>. What a UI
	    renders beside the parent's transcript, and what a test asserts
	    the C<max-live> backstop against. )
	method live-agents(--> List:D) {
		$!lock.protect: {
			%!children.values.sort({ $_<seq> }).map({
				%(
					agent-id     => $_<agent-id>,
					agent-type   => $_<agent-type>,
					label        => $_<label>,
					session-path => $_<session-path>,
				);
			}).List;
		};
	}

	#|( Ask every live child to stop, and answer how many were asked.
	    Idempotent and safe from any thread — C<Run.cancel> is both, and
	    is a total no-op on a child that has already finished.

	    The cascade calls this on the parent's cancellation; call it
	    yourself from a shutdown path. It does B<not> wait: each child's
	    C<task> call settles as an C<is_error> when that child's run ends,
	    which is as long as its tool batch takes. )
	method cancel-children(--> Int:D) {
		# Snapshotted under the lock, cancelled outside it: `.cancel` runs
		# the child driver's on-cancel hook, and this lock is a leaf.
		my @runs = $!lock.protect: {
			%!children.values.map({ $_<run> })
				.grep({ $_ ~~ LLM::Agent::Run:D }).List;
		};

		my Int $asked = 0;
		for @runs -> $run {
			try $run.cancel;
			$asked++;
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
				$answer = self!run-task(%item<call>, %item<id>);
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
	method !run-task($call, Str:D $id --> Hash:D) {
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
		my Str $agent-id;
		my Str $refusal;
		$!lock.protect: {
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
				%!children{$agent-id} = %(
					seq          => $!seq++,
					agent-id     => $agent-id,
					agent-type   => $type-name,
					label        => $label,
					run          => LLM::Agent::Run,
					session-path => '',
				);
			}
		};

		return error-result($id, $refusal) if $refusal.defined;

		# The slot is held from here on, so the rest is a scope of its own
		# whose LEAVE releases it — rather than a LEAVE up here, which
		# would also fire on the refusal paths above it.
		self!spawn-and-settle($id, $agent-id, $type.Hash, $type-name, $prompt, $label);
	}

	# The half of a task call that owns a reserved child slot: spawn,
	# forward, wait, record — and release the slot on every exit.
	method !spawn-and-settle(
		Str:D $id, Str:D $agent-id, %type, Str:D $type-name, Str:D $prompt,
		$label,
		--> Hash:D
	) {
		LEAVE { $!lock.protect: { %!children{$agent-id}:delete } }

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

		return error-result(
			$id,
			"The $type-name agent could not be started: "
				~ ($threw.message.lines.head // $threw.^name),
		) if $threw.defined;

		return error-result(
			$id,
			"The $type-name agent could not be started: its spawn callback "
				~ 'answered with '
				~ ($handle.defined ?? 'a ' ~ $handle.^name !! 'nothing')
				~ ', which has no run and session-path.',
		) unless $handle.defined && $handle.can('run')
			&& $handle.can('session-path');

		my $child = $handle.run;
		return error-result(
			$id,
			"The $type-name agent could not be started: its handle's .run is "
				~ ($child.defined ?? 'a ' ~ $child.^name !! 'undefined')
				~ ', not a live LLM::Agent::Run.',
		) unless $child ~~ LLM::Agent::Run:D;

		my $raw-path = $handle.session-path;
		my Str $child-path = $raw-path.defined ?? $raw-path.Str !! '';

		$!lock.protect: {
			if %!children{$agent-id}:exists {
				%!children{$agent-id}<run> = $child;
				%!children{$agent-id}<session-path> = $child-path;
			}
		};

		# The cancel cascade, registered on the first spawn of this parent
		# run — before the child is tapped, so a cancel arriving in the
		# next microsecond still reaches it.
		self!hook-cancel;

		self!append-envelope('subagent-spawned', %(
			agent-id   => $agent-id,
			agent-type => $type-name,
			prompt     => $prompt,
			label      => $label,
			child-path => $child-path,
		));

		self!settle-child($child, $id, $agent-id, $type-name, $label);
	}

	# Tap the child, wait for it, and turn what it did into a result. The
	# tap is the child's ONLY one: a Supplier::Preserving delivers its
	# buffer to the first tap and replays nothing to a second, so a child
	# tapped anywhere else has already lost its beginning to whoever got
	# there first.
	method !settle-child(
		LLM::Agent::Run:D $child, Str:D $id, Str:D $agent-id,
		Str:D $type-name, $label,
		--> Hash:D
	) {
		my $published = Promise.new;
		my $vow = $published.vow;

		my $tap = $child.events.tap(
			-> $event {
				self!forward($agent-id, $type-name, $label, $event);
			},
			# `try`, because keeping a vow twice throws and a Supply that
			# somehow did both would take the tap's thread with it.
			done => { try $vow.keep(True) },
			quit => -> $ { try $vow.keep(True) },
		);
		LEAVE { try $tap.close }

		await $child.result;

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
		self!append-envelope('subagent-settled', %payload);

		%(
			role         => 'tool',
			tool_call_id => $id,
			content      => $content,
			is_error     => $is-error,
		);
	}

	# One child event, wrapped and published on the PARENT's stream. A
	# no-op with no loop and with no live run — a child still winding down
	# after its parent ended is the ordinary case, not an error.
	method !forward(Str:D $agent-id, Str:D $agent-type, $label, $event --> Nil) {
		my $loop = self!resolve-loop;
		return unless $loop.defined;
		return unless $event ~~ LLM::Agent::Event:D;

		$loop.emit-external(LLM::Agent::Event::Subagent.new(
			:$agent-id, :$agent-type, :$label, inner => $event.to-hash,
		));
		Nil;
	}

	# Register the cascade on this parent run's cancellation, once per run.
	method !hook-cancel(--> Nil) {
		my $loop = self!resolve-loop;
		return unless $loop.defined;

		my $run = $loop.live-run;
		return unless $run.defined;

		my Bool $first = $!lock.protect: {
			($!hooked-run-id.defined && $!hooked-run-id eq $run.id)
				?? False
				!! do { $!hooked-run-id = $run.id; True };
		};

		# Outside the lock, and `try`-shielded: `.then` schedules our code
		# on somebody else's thread, and a broken Promise nobody awaits is
		# a warning at GC time in a run that ended minutes ago.
		$run.cancellation.then({ try self.cancel-children; True }) if $first;

		# And the case the registration alone cannot cover: a run that was
		# ALREADY cancelled when this child was spawned. The hook fires
		# once, and if an earlier spawn registered it, it has fired
		# already — so the child started after it would never be told.
		self.cancel-children if $run.is-cancelled;
		Nil;
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
	method !append-envelope(Str:D $type, %payload --> Nil) {
		return unless $!session.defined;

		my $threw;
		{
			CATCH { default { $threw = $_ } }
			$!session.append-event(:$type, payload => %payload);
		}
		return unless $threw.defined;

		my $loop = self!resolve-loop;
		return unless $loop.defined;
		try $loop.emit-external(LLM::Agent::Event::Log.new(
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
