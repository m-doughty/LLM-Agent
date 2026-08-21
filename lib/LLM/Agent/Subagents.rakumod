=begin pod

=head1 NAME

LLM::Agent::Subagents - a tool provider that spawns child agent runs and
answers with what they said

=head1 SYNOPSIS

=begin code :lang<raku>

use LLM::Agent::CompletionBus;
use LLM::Agent::Subagents;

my $loop;                       # forward-declared: the composer needs it
my $bus = LLM::Agent::CompletionBus.new;    # optional; see below

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

    # Optional, and it changes everything: with a bus a task call
    # acknowledges and returns, and the answer arrives later as a framed
    # turn. Give the SAME bus to the loop. See BACKGROUND DELEGATION.
    completion-bus => $bus,

    max-live             => 4,
	cancel-grace         => 30,
	drain-grace          => 30,
    max-identical-spawns => 3,

    # The question channel's rails: a parent parked on a child is doing
    # nothing, and a host with a concurrency budget wants to know.
    on-child-park   => -> %info { $slots.suspend(%info<agent-id>) },
    on-child-unpark => -> %info { $slots.resume(%info<agent-id>) },
);

# ... and, from the CHILD's ask handler, on the child's own thread: the
# question goes to the parent model rather than to the human, and the
# answer comes back in the shape an elicitation already speaks.
my %outcome = await $subagents.post-question(
    $agent-id, message => 'Which payments module did you mean?',
);

$loop = LLM::Agent::Loop.new(
    :@backends, provider => $subagents, :$session, completion-bus => $bus,
);

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

It publishes two more, C<task_answer> and C<task_wait>, which are the
rest of the same protocol: a child that cannot act on its brief asks the
agent that wrote it, the C<task> call comes back early carrying the
question, and the answer is collected afterwards. See L</The question
channel>; a host that never calls C<post-question> never reaches any of
it.

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

=item The arguments are read and checked B<strictly>: no key the
declaration does not name, an C<agent-type> that is in the table, a
C<prompt> that is not empty, an optional C<label>. See L</Strict
arguments>.

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

=item Unless the child B<asks something> first, in which case the call
comes back early with the question and the child carries on — see
L</The question channel>. That is not an error and not the child's
answer, and the answer is collected afterwards with C<task_wait>.

=item B<...or unless this composer holds a C<completion-bus>>, in which
case the fourth step does not happen at all: the call acknowledges and
returns, and the answer arrives later as a framed turn the loop injects.
See L</Background delegation>, which is the mode most of this Pod's
"waits" stop being true in.

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

A composer B<per delegating child> — which is what an app that wants a
tree rather than a chain builds — works exactly as the single one does,
and the two things that cross levels do so by construction:
C<Event::Subagent> nests (a child composer's wrapper becomes the C<inner>
of the parent's, and C<inner> is plain data all the way down), and a
settled child's spend travels up one level at a time (L</A parent pays
for its children>), so the root's bill is the whole tree's. What does
B<not> cross levels is C<max-live>: bound the tree at the seam where the
app builds children, not here.

=head2 The wrapping contract

A child's events are B<not> merged into the parent's stream: they are
wrapped, one C<LLM::Agent::Event::Subagent> per child event, carrying the
child's C<.to-hash> as C<inner>. The parent Run stamps the wrapper with
its own C<run-id> and C<seq>; the inner hash keeps the child's. See
L<LLM::Agent::Event>'s Pod for why, and for what a consumer does with it.

Every wrapper also carries C<call-id>: the provider's id for the C<task>
call that started this child, constant for its whole life. That is the
only thing joining a delegation's B<tool> events to its B<child> events —
they are three unrelated ids otherwise — and a UI that draws one card per
delegation rather than two needs it.

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

=head2 Strict arguments

A C<task> call may carry B<only> the keys its declaration names —
C<agent-type>, C<prompt>, C<label> — plus C<reason>. Anything else is an
C<is_error> result, checked B<before> C<agent-type> and before
C<prompt>, and nothing is started: no child, no slot, no entry in the
identical-spawn tally.

That is stricter than this layer is anywhere else, and it is strict
because of what the unknown keys turn out to be. A provider generating a
turn full of long briefs can hit its completion cap in the middle of one
of them and B<still> close the JSON: constrained decoding produces valid
syntax at the cap, the finish reason says nothing went wrong, and what
was left of the brief is railroaded into keys of the decoder's own
invention — a key like C<'sh_run. CONTEXT'> whose name is a fragment of
the sentence that was being written. The call parses. C<agent-type> is
there. C<prompt> is there, holding the first hundred characters of a
brief that was meant to be three thousand. Ignore the junk and a
subagent is started on a sentence and a half, with no way for anyone —
child, parent or user — to tell that anything was lost.

So the junk is the diagnosis, not a thing to be dropped. The refusal
names the offending keys (flattened and cut, because they can carry
newlines and a paragraph of the prompt), names the keys that are
allowed, and tells the model what this usually means and what to do:
re-emit the whole call, with the complete task in C<prompt>. That is one
refused turn against a delegation that would have been quietly wrong.

C<reason> is tolerated whether or not anything is producing it. A stack
that has L<MCP::Client>'s reasons layer in it adds that parameter to
every declaration on the way out and strips it from every call on the
way down, so this layer never sees it — but the layer is stacked only
when its host turns reasons on, and a model that has been asked for a
C<reason> on every call for a whole conversation will write one here
too. Refusing a delegation over a habit the harness taught it would be
the check doing harm, so the key is allowed by name (a literal, not an
import: this module does not depend on that stack).

Nothing else this composer publishes is checked this way, and the C<task>
tool is checked this way because it is the one whose arguments are a
whole conversation's worth of instructions. A tool whose arguments are a
path and a line number cannot be silently gutted by a clip; a brief can.

=head3 What the model is told about writing one

The task tool's description carries the doctrine that goes with the
check: independent work batched into B<one> turn is how delegations run
concurrently, and — since a batch of long briefs is exactly the shape
that provokes a clip — B<a brief is worth its length>. It says so: write
it in full, and when several long briefs are queued, splitting the
spawns across turns is fine. Telling a model to batch without telling it
that length is allowed is telling it to compress, and a compressed brief
is the same lost context arrived at deliberately.

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
B<that can still answer> are already running, with a message telling the
model to wait for what it started. It is a backstop and not a queue: the
refusal is immediate, because a model blocked on an invisible queue looks
exactly like a model that has hung.

"Can still answer" is the whole of what changed when wedges became
visible: a child whose result is kept and whose C<drained> never comes
(C<drain-grace>) is still owned and still cancellable, but it no longer
holds a slot — see C<live-count> and C<owned-count>. A composer that let
one wedge refuse work for the rest of a host's life would be an
accounting detail turning into an outage.

Both are checked and the child's slot is reserved in B<one> critical
section, so two spawns arriving at once cannot both take the last slot.
That was true before anything arrived at once and it is what makes the
next section safe.

=head2 Several task calls at once

A batch carrying more than one C<task> call starts B<all of them
together> — one thread per call — and reassembles the answers in the
caller's order. A C<task> call returns only when its child has settled,
so running them one after another would make N delegations take as long
as N children in a row however many the host could really run.

What that changes, and what it does not:

=item B<Order is preserved where order is visible.> The results come back
indexed by the position of their call, assembled on the calling thread,
so the conversation reads exactly as it would have. What is B<not>
ordered is which child starts, asks or finishes first — that is the point
of the exercise.

=item B<Every guard still holds.> C<max-live>, the identical-spawn tally,
the id counter and the slot table are all read and written in one
critical section per spawn, so N concurrent calls mint N distinct ids and
admit exactly as many children as there was room for. The others are
refused in the ordinary words, and the model is told to wait.

=item B<Every permission question arrives up front.> A host that asks a
human before a child may start will now be asked N times at once rather
than one at a time. That is the visible consequence of concurrency and
not a defect — but it is a UX decision, so it is made in the B<caller>:
the loop only hands this provider a batch of C<task> calls when the app
has named C<task> in L<LLM::Agent::Loop>'s C<concurrent-tools>. Left
unnamed, calls arrive one at a time and this section describes nothing
that happens.

=item B<Never throws, still.> Each call's answer is computed inside its
own thread with the same shield the serial code had, and the await that
collects it has one of its own.

An app that wants a smaller number of children actually B<working> at
once bounds it in the spawn callback — that is what the callback is for
(see L</THE SPAWN CALLBACK>), and a queue there is invisible from here:
the C<task> call simply takes longer to answer.

=head2 The question channel

A child that is given a brief it cannot act on has three things it can
do: guess, give up, or ask. The first is how a delegation goes quietly
wrong, the second wastes the run, and the third used to mean asking the
B<human> — who did not write the brief, was not asked to review it, and
is being interrupted about a conversation they cannot see. The agent that
wrote the brief is the one that knows what it meant.

So a host can route a child's question to its B<parent>. This module is
the engine half: it parks the question, hands the parent's waiting
C<task> call back with it, publishes two tools for answering and
collecting, and guarantees that nobody is left blocked whatever happens
next. What it deliberately does not do is decide B<which> questions get
routed — a child's C<user_ask> about a fact is its parent's business, and
a child asking permission to delete something is not (a model must not
consent on a human's behalf). That is the host's call, made at the seam
where it calls C<post-question>.

=head3 The host's side

=begin code :lang<raku>

# in the child's ask handler, on the CHILD's own thread
my %outcome = await $composer.post-question(
    $agent-id, message => $question, schema => %requested-schema,
);

=end code

C<post-question> parks the question and answers with a Promise, and the
child's thread blocks on it — which is exactly what an elicitation is: a
question that suspends the asker. What the Promise is kept with is an
B<elicitation outcome> (C<< { action, content } >>), so a host hands it
straight back to the server that asked.

B<Every refusal is a value.> An agent-id this composer does not own, one
that has already finished, a second question from an agent whose first is
still waiting, an empty question: all of them come back as an
B<already-kept> C<< { action => 'cancel' } >>. Nothing here throws at a
child, and nothing can hand one an C<accept> that nobody wrote. A child
that asks into the void carries on, or gives up, in the same way it would
if a human had dismissed the prompt.

C<pending-questions> is the snapshot beside it, for a UI drawing "waiting
on its parent" against an agent.

=head3 One question releases the whole wave

C<execute-tool-calls> answers a batch with B<one List>. That is the
provider contract, and it is what decides the shape of everything here: a
composer cannot hand back the asking child's call and go on waiting for
the others, because there is no way to return half a batch. So a question
settles B<every> C<task> call parked in that group at once — a wave:

=item the B<asking child's> call carries the question, in full, with what
to do about it;

=item every B<other> parked call says its child is still running and
names the tool that collects it;

=item every one of them lists whatever else is still open, so a parent
that lost track of a turn has the whole picture in front of it.

The alternative — holding the other calls open — would mean a parent that
cannot answer the question until the other children happen to finish,
which is the deadlock the channel exists to avoid. Nothing is lost by
releasing them: a child whose call came back early is still running,
still owned, still cancellable, and still collectable by name.

The same reasoning covers a call that arrives B<afterwards>: while any
question is open — delivered or not, from any child — a C<task> or
C<task_wait> call comes straight back with an interim result rather than
parking. A parent that waits on one child while another is blocked on an
answer only it can give is the same deadlock arriving a moment later, and
the cost of the blunt rule is a turn spent clearing the table, which the
interim result says how to do.

The loop needs to know none of this. An interim result is an ordinary
tool result with C<is_error> False whose content starts C<STATUS:
interim>; C<task_answer> and C<task_wait> are ordinary tool calls. There
is no new event, no new terminal, and no change to the loop at all.

=head3 Delivered in full, exactly once

A question is carried to the parent B<once>. The wave that delivers it
marks it C<delivered>; every interim result after that mentions it as a
line in "questions still waiting" and never repeats the text. A model
that is shown the same question three times will answer it three times,
or decide it is being ignored and stop — and a long question repeated in
every result of every wave is a context window spent on nothing.

Two consequences worth knowing:

=item A question asked while the parent is B<mid-generation> — nothing
parked, nobody to release — stays C<pending> and is delivered at the next
park, which is whichever C<task> or C<task_wait> call comes next.

=item A question from a child B<nobody is waiting on> is delivered by
whichever other waiting call gets there first. That is not an edge case:
a child whose call has already come back interim has nobody parked on it,
and its next question would otherwise sit pending for ever while
interrupting every other wait on every poll.

=head3 The two tools

=begin table

Tool        | What it does
============|=========================================================
task_answer | answers a parked question: agent-id, and answer / fields / decline
task_wait   | collects an agent whose task call came back interim

=end table

C<task_answer> takes C<answer> (prose) for a question that asked in
prose, C<fields> for one that asked for named fields, or
C<< decline => True >> with a C<reason> for one that cannot be answered
at all. A form is validated against the fields it B<required>: a missing
one is an C<is_error> naming it, and B<the question stays parked> —
every refusal on this path leaves the child exactly as blocked as it was,
because a question dropped on a malformed answer strands the agent that
asked it. Answering is not collecting: the child carries on from where it
stopped, and its answer arrives through C<task_wait>.

C<task_wait> answers with exactly what the original C<task> call would
have: the child's final message, or the reason there is none. It is
B<idempotent> — a child that has already been collected answers from a
cache, in the same words, however many times a model asks — and it parks
on a child that is still going, with the same interim, cancel and
unstoppable behaviour the original call had. An id that means nothing
here is an C<is_error> that says what that usually means (a restart, or
an agent already collected) rather than a bare refusal.

Both are checked against their own declarations by the same strict
unknown-key check C<task> uses, and neither is a spawn: they take no
slot, mint no id, and cannot trip the identical-spawn guard. A host
should, though, name them in L<LLM::Agent::Loop>'s
C<identical-call-exempt>: collecting the same agent twice is B<by
design>, and the loop's identical-call guard cannot tell that from a
model going round in circles.

=head3 The settle happens once, whoever was waiting

A child can now be waited on more than once, and can also finish with
nobody waiting at all. Exactly one of those writes the
C<subagent-settled> envelope and absorbs the child's spend:

=item a call that was parked when the child settled records it, and the
others answer from the cache. B<Every> way out of a park counts here, not
just the terminal one: a call released by a question re-reads the child
on its way out and records it if it settled underneath, because the child
it left behind is a child the drain that follows will assume somebody
else was writing;

=item a child that finishes B<uncollected> records itself as it drains,
B<before> its slot is released — otherwise its answer would go with it
and the C<task_wait> the parent was told to make would find no such
agent.

An interim wave writes B<no> settle envelope and absorbs B<no> spend for
a child that is B<still running>: it has not finished, and a transcript
that recorded a settle for it would be recording something that did not
happen.

=head3 Cancelling, and the vows

A parked question is a host thread blocked on a Promise, so every way
this composer can stop caring about a child keeps that vow:
C<cancel-children> sweeps the whole table (every vow C<cancel>), a child
that settles or refuses to stop has its own question swept, and a child
that is released takes its question with it.

The parent's B<terminal> — not just its cancellation — is a cascade too.
A run that ends with a child still going (the model read the interim
result and answered the user instead of answering the child) leaves a
child working for a conversation that is over and a host thread blocked
on a question nobody will ever see; nothing can reach either of them
once the run is finished, so both are ended. When everything settled
normally — which is the common case — the hook finds no children and no
questions and does nothing at all.

=head3 The park rails

C<on-child-park> and C<on-child-unpark> fire when a C<task> or
C<task_wait> call starts and stops waiting on a child, with
C<< { agent-id, call-id, tool } >> and, on the way out, an C<outcome> of
C<interim>, C<final>, C<unstoppable> or C<error>. They are B<balanced on
every path>, shielded, and exist for the host's own accounting: a parent
parked on a child is doing nothing, which for a host with a concurrency
budget is a slot it can lend to somebody else — and the asking child is
itself suspended on its question, so the two of them together hold one
slot rather than two.

They are also the rails the B<next> thing rides on. Interrupting a wait
for a reason other than a question — a steer, a priority change — is the
same mechanism with a different predicate, and a host that has wired the
callbacks for delegation has already wired them for that.

=head2 Background delegation

Everything above describes a C<task> call that B<waits>: the parent's
round does not move until the child answers. That is a real cost, and it
is the cost that makes delegation not worth doing. A parent that cannot
read a file while its fleet works is a parent doing nothing, one slow
child wedges a whole turn, and "delegate and carry on" — the entire point
of having subagents — is not expressible.

Give this composer a C<completion-bus> and it stops waiting.

=begin code :lang<raku>

my $bus = LLM::Agent::CompletionBus.new;

my $subagents = LLM::Agent::Subagents.new(
    ..., completion-bus => $bus,
);
my $loop = LLM::Agent::Loop.new(
    :@backends, provider => $subagents,
    completion-bus => $bus,          # THE SAME ONE. See below.
);

=end code

B<The same bus, both places.> The composer opens operations on it and the
loop parks on it; two different buses would mean children tracked on one
thing and a run waiting on another, which is a run that ends while its
children work — the exact failure the bus exists to prevent.

It cannot be checked at construction (the loop does not exist yet, which
is what the deferred C<loop> Callable is for), so it is checked at the
first delegation and reported as a C<Log> at C<error>: a composer with a
bus whose loop has a different one, or none, says so on B<every>
delegation it affects. That is deliberately noisy, because nothing else
in the system has a symptom — the child works, the transcript records it,
and the conversation simply never hears the answer it was promised.

B<And with no bus, nothing changes.> Not "behaves similarly": a composer
without one takes every path it took before background delegation
existed, down to the words in every tool description. There is one
predicate, and every place the two modes differ asks it.

=head3 What a task call does instead

=item The arguments are read, the guards run and the slot is taken —
B<unchanged>, all of it.

=item The operation is opened on the bus, B<before the child is built>.
Building a child is the app's code and takes as long as it takes; a run
that finished in that gap would finish having promised an answer that
nothing had started producing yet. A bus at C<max-outstanding> refuses
here, and the refusal is a guidance result naming both numbers — the same
shape the C<max-live> refusal beside it has, because they are the same
situation seen from two tables.

=item The child is spawned and tapped exactly as before, and then the
call B<returns an acknowledgement>: a C<STATUS: started> result that says
whose it is, where the real answer will appear, and — the sentence that
does the work — that finishing the turn is B<safe>. A model will not
believe that unless it is told; everything it has been trained on says a
turn ends the conversation.

=item The child reports itself through the paths that already existed for
a child B<nobody was waiting on>: the drain hook, C<!record-uncollected>,
C<!write-terminal>. Nothing new watches a child. The one thing that is
new is the last line of C<!write-terminal> — the settle goes onto the bus
from B<inside> the once-guard that writes the transcript envelope, so the
line in the transcript and the turn the model reads are written by the
same winner and cannot disagree about what a child said.

=head3 Said once, whichever way round it happened

A child can settle while a C<task_wait> is parked on it, or settle first
and be asked for afterwards. Both are ordinary; both must present the
answer B<once>.

=begin table

What happened                        | Where the answer goes
=====================================|====================================
a task_wait was parked when it settled | that call's result. The bus operation closes COLLECTED and enqueues nothing
it settled with nobody waiting        | onto the bus, and the loop injects it as a turn
...and a task_wait asked for it after | that call's result, and the queued turn is WITHDRAWN

=end table

C<:collected> is the whole mechanism, and it withdraws whether or not the
operation was still open — which is what makes the third row work, where
the operation closed some time ago and the turn is sitting in the queue.

The one case it cannot catch is a model that calls C<task_wait> for a
child it has B<already been shown> a turn about: the turn is in the
transcript by then, and taking it back is not a thing an append-only
transcript does. That is C<task_wait>'s documented idempotence — the same
words twice, for a model that asked twice — rather than a double
delivery, and the background C<task_wait> description exists to make it
rare.

=head3 A question, without a call to carry it

In blocking mode a question rides home on a parked C<task> call: the wave
releases every parked call, and the asking child's carries the text. In
background mode there is no parked call to release — the parent is off
doing something else, or nothing at all — so the question goes to it as a
B<turn of its own>, pushed onto the bus as an B<untracked> deliverable.

Untracked is load-bearing. The child asking a question is stopped, not
finished; its operation stays open, the run stays unwilling to end, and
the question is news beside it rather than an answer instead of it.

Two things are unchanged, and both of them are the deadlock rules:

=item B<the question stays in the table until it is ANSWERED>. Delivery
is not an answer. The pending → delivered transition happens inside the
same critical section that parked it, which is what makes "in full,
exactly once" true whichever thread gets there;

=item B<C<!interrupt-pending> stays deliberately blunt.> Any open
question from any child releases any wait — see its Pod, which is the
paragraph to read before touching this. A C<task_wait> on a child whose
delivered question is still waiting for an answer must come back interim
and not hang, because the parent it is waiting on is the parent that owes
the answer.

=head3 Where a background run stops

The bus is what a run parks on, and a child that can never answer would
park it for ever. Three things stop that, and none of them is a timeout
on the work itself:

=item every path that answers the model about a child B<here and now> —
a spawn that failed, a child cancelled before it started, one that was
asked to stop and would not — closes the operation C<:collected>. The
model has been told; a background turn saying it again would read as a
second child;

=item a B<wedged> child closes it too. A wedge is a child whose result is
kept and whose C<drained> never comes (C<drain-grace>): it already stops
counting against C<max-live>, for the reason that it will never answer,
and it stops holding a run open for exactly the same one. Its answer
B<exists> — the wedge is in the drain, not in the work — so what gets
delivered is the real one;

=item and everything else is caught by the loop's own idle valve
(C<park-idle-timeout>), which closes what is left and ends the run
honestly, naming what never came back.

=head2 Cancelling, and the cascade

The first spawn of a batch registers on the parent run's C<cancellation>
Promise, so cancelling the parent cancels every child. That is a cascade,
not a wait: the parent's own cancel path does not wait for the children,
and a child that was mid-tool-call takes as long to wind down as it
takes. Every cancelled child's C<task> call settles as an C<is_error> —
the batch is never left hanging.

C<cancel-children> is the same thing for a shutdown path, and
C<live-agents> is what a UI renders while they run. C<owned-count> and
C<live-count> are the two numbers behind that list: everything this
composer would cancel, and everything that can still answer.

=head2 A parent pays for its children

A child is a whole run of its own, with its own loop and its own bill,
and nothing about that reaches the parent's budget by itself: a
C<max-cost> on the parent would cap the parent's own turns and be blind
to the ten agents it started, which for an agent whose job is delegating
is a cap on the cheapest part of what it spends.

So as each child B<settles>, its C<spent> record is handed to the parent
loop's C<absorb-spend> (L<LLM::Agent::Loop>) — the same numbers the
C<subagent-settled> envelope records, added to the accumulators the
parent's own caps are checked against. The parent's budget is thereby the
budget of its B<whole subtree>, and recursively so: a composer under a
child feeds that child, whose settled record already contains its
children's, and so on up.

Three properties worth relying on:

=item B<It is billed to the run that asked.> The absorb is tagged with
the parent run captured for this batch, so a child settling after its
parent finished — a cancelled parent whose child was still winding down —
is dropped rather than charged to whatever run started next.

=item B<Nothing is refused here.> Absorbing does not check a cap and does
not end anything; the parent's next round or operation boundary does
that, in the ordinary way, with the ordinary C<budget-exhausted> reason.
A child that pushes its parent over is refused on the parent's B<next>
attempt, not retroactively.

=item B<A child nobody counted is not billed for zero.> A run without a
request budget hands back no C<spent> key at all, and that absorbs
nothing — "nobody was counting" survives the trip, as it does everywhere
else in this class.

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

The one thing the slot does not survive is a gap that never closes. Once
C<drain-grace> has passed the child is marked B<wedged>: still owned,
still in C<live-agents>, still reached by C<cancel-children> — and no
longer counted by the C<max-live> admission check, which is
C<live-count>. Holding a slot for a child that will never answer would
mean one abandoned tool call quietly costing the composer a slot for as
long as the host is up.

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

Four envelope types on the B<parent's> session, all through
C<< Session.append-event >>, so an older L<LLM::Agent> replays them as
unknown types and ignores them:

=begin table

Type              | Payload
==================|===================================================
subagent-spawned  | agent-id, agent-type, prompt, label?, call-id, child-path
subagent-question | agent-id, token, call-id?, message, schema
subagent-answered | agent-id, token, call-id, action, content, reason?
subagent-settled  | agent-id, outcome, result, call-id?, spent?

=end table

The two question envelopes are written once each per question — the
C<call-id> on a C<subagent-question> is the call that B<carried> it to
the parent, which is not the call that started the child, and the one on
a C<subagent-answered> is the C<task_answer> that resolved it. C<message>
and C<content> are excerpts, for the reason C<result> is.

A question delivered as a background turn has B<no> C<call-id>: nothing
carried it, which is what a background delivery is, and inventing one
would name a call that never happened.

The C<call-id> on a C<subagent-settled> is a third thing again: the
C<task> call that B<started> this child, the same one its spawn envelope
records. It is what joins a settle found on disk back to the
acknowledgement in the conversation, which is how a result collected
while the process was dying is told from one that was lost. Absent for a
child whose framing this composer no longer holds — a settle that arrived
after the parent run had been replaced — and never invented.

C<call-id> is the provider's id for the C<task> call that started this
child, which is what joins the spawn line to the C<tool-dispatched> line
a few envelopes above it — and, for a UI replaying a transcript, the tool
card to the agent card. A transcript written before the key existed
simply has no C<call-id> on its spawn lines, and replays exactly as it
always did: nothing here reads the key back, and a reader that wants it
treats "absent" as "this pairing is not recorded" rather than as damage.

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
L<LLM::Agent::CompletionBus> (what a background delegation is tracked
on), L<MCP::Client::Policy> and L<MCP::Client::Registry> (the other two
composers of the same duck-typed pair).

=end pod

use JSON::Fast;
use UUID::V4;

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

	#|( The other two tools of the delegation protocol: the one that answers
	    a child's question, and the one that collects a child whose C<task>
	    call has already come back with an interim result. Both are
	    published beside C<task> whenever this composer is, because a
	    catalogue is fixed for the whole of a turn and the protocol has to
	    be visible B<before> the first question rather than after it. )
	our constant ANSWER-TOOL = 'task_answer';
	our constant WAIT-TOOL = 'task_wait';

	# The three names this composer routes on, and therefore the three it
	# drops from the inner catalogue rather than publishing twice.
	my constant OWNED-TOOLS = (TASK-TOOL, ANSWER-TOOL, WAIT-TOOL);

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
	my constant DEFAULT-GRACE = 30;

	# How much of a question survives into the one-line list of what is
	# still open. The full text is delivered once, in full (bounded by
	# SETTLE-EXCERPT); this is the reminder beside it.
	my constant QUESTION-LINE = 200;

	# How much of a label survives into a background acknowledgement, and
	# how much of a prompt into the parenthesis a background turn names its
	# agent with. Both are cut hard: an acknowledgement is read by a model
	# that has eight of them in one batch, and the parenthesis is there to
	# make a turn recognisable, not to repeat the brief.
	my constant ACK-LABEL = 120;
	my constant PROMPT-REFERENCE = 240;

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

	#|( The completion bus this composer reports children on: an
	    L<LLM::Agent::CompletionBus>, or anything with its C<open> /
	    C<settle> pair. B<Its presence is the whole switch> between the
	    two modes this composer has:

	    =item B<Without one> — the default — a C<task> call B<blocks>
	    until its child settles, and everything about this class behaves
	    exactly as it did before background delegation existed. Not
	    approximately: the same waits, the same interim results, the same
	    words in every tool description.

	    =item B<With one> a C<task> call B<acknowledges and returns>. The
	    child goes on working, the parent model goes on working, and the
	    answer arrives later as a framed turn that L<LLM::Agent::Loop>
	    injects at a round boundary. The run will not end while a child is
	    still owed — that is what the bus is for.

	    Give the B<same> bus to the loop (C<completion-bus>), or the
	    children will be tracked on one thing and the run will park on
	    another. See L</Background delegation>. )
	has $.completion-bus;

	#| How many B<non-wedged> children may run at once before a spawn is
	#| refused — the count C<live-count> answers with.
	has Int:D $.max-live = 4;

	#| Seconds a cancelled child gets to produce a result.
	has Real:D $.cancel-grace = DEFAULT-GRACE;

	#|( Seconds after a result before an undrained child is reported as
	    wedged.

	    A wedge changes exactly one thing: it stops counting against
	    C<max-live> admission, because a child that will never answer must
	    not go on refusing work on its behalf. Ownership stays
	    fail-closed — the entry is still in the table, so
	    C<cancel-children>, C<owned-count> and C<live-agents> all still see
	    it, and it is released only when its C<drained> finally keeps. See
	    C<live-count>. )
	has Real:D $.drain-grace = DEFAULT-GRACE;

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

	#|( Called — from the thread that is about to wait — when a C<task> or
	    C<task_wait> call B<starts waiting> on a child, with one Hash:
	    C<< { agent-id, call-id, tool } >>.

	    The rails the host's own accounting rides on. A parent that is
	    parked on a child is not doing anything, which for a host with a
	    concurrency budget is a slot it can lend to somebody else; the
	    matching C<on-child-unpark> is what takes it back. Both are
	    B<shielded>: a callback that throws is a bug in the host and never
	    a reason for a delegation to fail. )
	has &.on-child-park;

	#|( The other half, called when that same call stops waiting, with
	    C<< { agent-id, call-id, tool, outcome } >> — where C<outcome> is
	    C<interim> (released to carry a question), C<final> (the child had
	    a result, whatever it was), C<unstoppable> (asked to stop and did
	    not) or C<error> (the wait itself went wrong).

	    B<Balanced on every path>, including the ones that throw: a park
	    without its unpark would leave a host counting a parent as busy for
	    ever. What does not fire either callback is a C<task> call that
	    never waits at all — a refused one, a spawn that failed, a child
	    cancelled before it started. )
	has &.on-child-unpark;

	# The one lock, and a strict leaf: the spawn callback, the inner
	# provider, the child's Supply and the loop are all called with it
	# released.
	has Lock:D $!lock .= new;

	# agent-id => { seq, agent-id, agent-type, label, run, session-path }.
	# An entry exists from the moment a spawn is admitted (the slot is
	# reserved under the same lock the backstop counts under) until its
	# task call has settled.
	has %!children;

	# agent-id => { agent-id, token, message, schema, vow, status, asked-at }.
	# A child's question, parked here from the moment its host asked it
	# until it is answered, declined, or swept by a cancel. `status` is
	# 'pending' (nobody has been told) or 'delivered' (a task/task_wait
	# call has carried it to the parent model, in full, exactly once).
	has %!questions;

	# agent-id => { content, is_error }: the FINAL answer of a child whose
	# task call has already settled terminally. What makes `task_wait`
	# idempotent — a model that collects the same agent twice gets the same
	# words rather than "no such agent" — and half of the guard that keeps
	# the settle envelope and the spend absorption to exactly one apiece.
	# Scoped to the parent run, like the identical-spawn tally, so a host
	# that stays up for a week does not accumulate one entry per delegation
	# for ever.
	has %!settled;
	has Str $!settled-scope;

	# agent-id => { agent-type, label, call-id, prompt }: what a background
	# deliverable's framing is built from, kept because the deliverable is
	# built LATER than the entry it describes.
	#
	# A child's slot is deleted the moment it drains, and the terminal that
	# a parked call writes on its way out is written after that — so
	# reading the identity off %!children would give a completion turn no
	# name for the agent it is about. That turn has to be self-contained
	# (compaction eats the acknowledgement it answers long before it eats
	# the turn), so the identity outlives the slot. Scoped to the parent
	# run, like %!settled, and for the same reason.
	has %!identities;

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
		die 'LLM::Agent::Subagents: cancel-grace must be positive'
			unless $!cancel-grace > 0;
		die 'LLM::Agent::Subagents: drain-grace must be positive'
			unless $!drain-grace > 0;

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

		# Structurally, the way the inner provider is checked: a bus that
		# is missing half its surface must be found out here and not at
		# the first delegation, with a child already running and the model
		# already told its answer is coming.
		if $!completion-bus.defined {
			my @missing = <open settle>
				.grep({ !$!completion-bus.can($_) });
			die 'LLM::Agent::Subagents: a completion-bus must have '
				~ @missing.join(' / ') ~ ' (an LLM::Agent::CompletionBus '
				~ 'has them, and so does anything shaped like one); got a '
				~ $!completion-bus.^name
				if @missing.elems;
		}
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
	    draining, wedged } >>. What a UI renders beside the parent's transcript,
	    and the whole of what this composer owns.

	    It is B<not> what the C<max-live> backstop counts: that counts the
	    entries which are not C<wedged> — C<live-count> — so a wedged child
	    appears here, and in C<owned-count>, without refusing a spawn.

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
					wedged       => ?($_<wedged> // False),
				);
			}).List;
		};
	}

	#|( How many children can still answer: every owned child that is not
	    wedged. This — not the owned total — is what admission measures
	    against C<max-live>, because a wedged child will never answer, and
	    refusing new work on its behalf starves the composer for the rest
	    of its life. )
	method live-count(--> Int:D) {
		$!lock.protect: {
			%!children.values.grep({ !($_<wedged> // False) }).elems;
		};
	}

	#|( Every child this composer owns, wedged included: the cancellation
	    footprint. C<cancel-children> reaches exactly this many, and a
	    wedge is owned until its C<drained> finally keeps — see
	    C<drain-grace>. )
	method owned-count(--> Int:D) {
		$!lock.protect: { %!children.elems };
	}

	# === The question channel ===

	#|( Park a question from one of this composer's children and answer
	    with the Promise its answer will arrive on.

	    This is the B<host's> side of the child→parent ask channel, and the
	    whole of it. A child that wants to ask something reaches its host's
	    elicitation seam in the ordinary way; a host that would rather the
	    B<parent model> answered than the human calls this from that seam
	    and awaits what it gets back:

	    =begin code :lang<raku>

	    # in the child's ask handler, on the child's own thread
	    my %outcome = await $composer.post-question(
	        $agent-id, message => $question, schema => %requested-schema,
	    );
	    # -> { action => 'accept', content => { ... } }
	    #    { action => 'decline' } / { action => 'cancel' }

	    =end code

	    The Promise is kept with an B<elicitation outcome>: the
	    C<< { action, content } >> shape an MCP C<elicitation/create>
	    answer has, so a host can hand it straight back to the server that
	    asked. C<accept> carries C<content>; C<decline> and C<cancel> carry
	    none, and a decline made with a C<reason> carries that reason as an
	    extra key for a host that wants to tell the child B<why> (the
	    outcome contract ignores keys it does not know).

	    B<Refusals are values, not exceptions.> A question for an agent
	    this composer does not own, for one that has already finished, or
	    one that arrives while an earlier question from the same agent is
	    still waiting, comes back as an B<already-kept>
	    C<< { action => 'cancel', reason => ... } >>. A child asking into
	    the void must carry on (or give up) rather than block for ever on a
	    parent that is never going to be told, and every such answer is
	    fail-closed by construction: nothing here can hand a child an
	    C<accept> it did not get.

	    What happens next is in L</The question channel>: the question is
	    delivered, in full and exactly once, on the next interim wave. )
	method post-question(
		Str:D $agent-id, Str:D :$message!, :%schema,
		--> Promise:D
	) {
		my $promise = Promise.new;
		my $vow = $promise.vow;
		my Str $text = $message.trim;

		# What this call has to carry to the parent itself, filled in
		# under the lock below and acted on outside it. Empty in blocking
		# mode, where the question waits for a park to release rather than
		# going anywhere on its own.
		my %deliver;

		my Str $refusal = $!lock.protect: {
			my $child = %!children{$agent-id}:exists
				?? %!children{$agent-id}
				!! Nil;
			my $run = $child.defined ?? $child<run> !! Nil;

			if !$text.chars {
				'the question was empty, and an empty question cannot be '
					~ 'put to anybody';
			}
			elsif !$child.defined {
				"there is no live agent called '$agent-id' here";
			}
			# Read under the lock on purpose: the terminal sweep below runs
			# AFTER a child's result is kept, so a question that gets in
			# while the run is still going is always swept by it, and one
			# that arrives afterwards is always refused here. There is no
			# third ordering, and therefore no question nobody answers.
			elsif $run ~~ LLM::Agent::Run:D && $run.is-done {
				"the '$agent-id' agent has already finished, so nothing it "
					~ 'asks now can change what it said';
			}
			elsif %!questions{$agent-id}:exists {
				"a question from '$agent-id' is already waiting for an "
					~ 'answer; this channel carries one at a time';
			}
			else {
				%!questions{$agent-id} = %(
					:$agent-id,
					token      => uuid-v4(),
					message    => $text,
					schema     => %schema.Hash,
					:$vow,
					status     => 'pending',
					'asked-at' => now,
				);

				# DELIVERED, decided in the same critical section that
				# parked it. In background mode there is no waiting call
				# to release — the parent is off doing something else, or
				# nothing — so the question goes to it as a turn of its
				# own, and the pending → delivered transition happening
				# HERE is what makes "in full, exactly once" true: only
				# one thread can win it, and an interim wave that arrives
				# a moment later finds a question that is already
				# delivered and mentions it in one line instead.
				#
				# The question STAYS in the table until it is answered.
				# Delivery is not an answer, `!interrupt-pending` is
				# deliberately blunt about any open question at all, and
				# an agent blocked on an answer stays blocked whether or
				# not the parent has been told.
				if self!background-mode {
					%!questions{$agent-id}<status> = 'delivered';
					%deliver = question-data(%!questions{$agent-id});
				}

				Str;
			}
		};

		$vow.keep(%( action => 'cancel', reason => $refusal ))
			if $refusal.defined;

		# Outside the lock: the bus is a leaf, but $!lock is a STRICT leaf
		# and the envelope write below is a file append. Nothing can be
		# lost between the two — the transition above is what makes this
		# call the one and only deliverer, and a `push` after it cannot
		# be raced by a second delivery that does not exist.
		self!deliver-question(%deliver) if %deliver.elems;

		$promise;
	}

	#|( Carry one question to the parent as a background turn: onto the
	    bus, and into the transcript.

	    B<Untracked> on purpose. The child is already a tracked operation
	    and is still outstanding — it is stopped, not finished — so a
	    question must not close anything. C<push> is exactly that: news the
	    run does not park for, delivered at the next round boundary,
	    leaving the child's own operation open for the answer it will
	    eventually produce.

	    Shielded: a bus or a transcript that refuses this must not surface
	    as the child's own C<user_ask> throwing, several layers down on the
	    child's thread. )
	method !deliver-question(%question --> Nil) {
		my Str $agent-id = (%question<agent-id> // '').Str;
		my &report = self!child-emitter($agent-id);

		try $!completion-bus.push(self!question-deliverable(%question));

		# The same envelope an interim wave writes, and written once for
		# the same reason: the transcript records the moment a question
		# reached the parent, which happens once. No `call-id` — nothing
		# carried it, which is what a background delivery IS, and a call
		# id invented here would name a call that never happened.
		self!append-envelope('subagent-question', %(
			:$agent-id,
			token   => %question<token>,
			message => excerpt(%question<message>, SETTLE-EXCERPT),
			schema  => %question<schema>,
		), &report);
		Nil;
	}

	#|( A child's question, as a deliverable for the bus.

	    The same three-way split a settled child gets, and the same reason
	    for it: the question's own words are the only part that may be
	    excerpted, because everything else in the turn is what makes it
	    answerable — who asked, that they are stopped until they are
	    answered, and the exact shape the answer has to take. )
	method !question-deliverable(%question --> Hash:D) {
		my Str $agent-id = (%question<agent-id> // '').Str;
		my %who = self!identity-of($agent-id);

		%(
			kind => 'subagent-question',
			head => self!background-frame ~ "\n\n"
				~ 'The ' ~ %who<agent-type> ~ ' agent '
				~ self!agent-reference($agent-id) ~ ' has a question, and '
				~ 'is stopped until you answer it. STATUS: question — this '
				~ "is not the agent's answer:\n\nQUESTION from $agent-id:",
			body => (%question<message> // '').Str,
			tail => (
				self!question-fields-block(%question),
				self!background-answer-instructions($agent-id, %question),
			).grep({ .chars }).join("\n\n"),
			extras => %(
				'completion-of' => $agent-id,
				'agent-type'    => %who<agent-type>,
				token           => (%question<token> // '').Str,
				|(%who<call-id> ~~ Str:D && %who<call-id>.chars
					?? ('call-id' => %who<call-id>)
					!! ()),
			),
		);
	}

	# What to do about a question that arrived as a background turn. The
	# same doctrine an interim result carries — answer it yourself if you
	# can, escalate WITH the context if you cannot, an agent left waiting
	# is an agent doing nothing — with the one thing that differs in
	# background mode said explicitly: answering is not collecting, and
	# collecting is not something the model has to remember to do.
	method !background-answer-instructions(
		Str:D $agent-id, %question,
		--> Str:D
	) {
		my Bool $form = ?schema-fields(%question<schema>).elems;

		"Answer it with '{ANSWER-TOOL}': "
			~ '{ "agent-id": "' ~ $agent-id ~ '", '
			~ ($form
				?? '"fields": { ... } } — the fields it listed above; or '
				!! '"answer": "<your answer, in full>" } — or ')
			~ '"decline": true with a "reason" when it cannot be '
			~ "answered.\n"
			~ 'Answer it yourself if you can: you have the context the '
			~ 'agent has not. If you cannot — it needs a decision only the '
			~ 'user can make — ask the user yourself, with the whole of the '
			~ "context, and pass what they say back with '{ANSWER-TOOL}'. "
			~ "An agent left waiting is an agent doing nothing.\n"
			~ 'The agent carries on the moment you answer, and what it '
			~ 'finally says will arrive here as another [background event] '
			~ 'turn. You do not have to collect it.';
	}

	#|( Every question this composer is holding, oldest first, as plain
	    data: C<< { agent-id, token, message, status, asked-at } >>, where
	    C<message> is cut to one line and C<asked-at> is seconds (an
	    C<Instant> as a Num). What a UI renders as "this agent is waiting on
	    its parent", and what a host uses to decide that a question has been
	    outstanding for too long.

	    C<status> is C<pending> — parked, and the parent model has not been
	    told yet, because it was mid-generation when the question arrived —
	    or C<delivered>, meaning it has been carried to the parent and is
	    waiting for a C<task_answer>. Never the vow: this is a snapshot to
	    look at, not a handle to answer with. )
	method pending-questions(--> List:D) {
		$!lock.protect: {
			%!questions.values.sort({ $_<asked-at> }).map({
				%(
					agent-id   => $_<agent-id>,
					token      => $_<token>,
					message    => one-line($_<message>, QUESTION-LINE),
					status     => $_<status>,
					'asked-at' => $_<asked-at>.Num,
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
		my @vows;
		my @runs = $!lock.protect: {
			my @live;
			for %!children.values -> %child {
				%child<cancel-requested> = True;
				$asked++;
				@live.push: %child<run> if %child<run> ~~ LLM::Agent::Run:D;
			}

			# THE QUESTIONS GO TOO, and they go as VALUES. A child blocked
			# on an answer from a parent that is being shut down is a child
			# that never stops, so every parked question is answered
			# `cancel` — the outcome its own elicitation contract already
			# has a meaning for — rather than left for a vow nobody is
			# going to keep.
			@vows = %!questions.values.map({ $_<vow> }).List;
			%!questions = ();

			@live.List;
		};

		# Both outside the lock: `.keep` runs somebody else's continuation,
		# and `.cancel` runs the child driver's on-cancel hook.
		for @vows -> $vow {
			try $vow.keep(%( action => 'cancel' ));
		}
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
		my $owned = OWNED-TOOLS.Set;
		my @published = $!inner.tools-for-llm.list.grep({
			!$owned{tool-name-of($_) // ''};
		});
		(
			|@published,
			self!task-declaration,
			self!answer-declaration,
			self!wait-declaration,
		).List;
	}

	#|( Every call, answered: the C<task> calls here, everything else
	    forwarded to the inner provider as one batch, and one result per
	    call in the caller's order.

	    B<Never throws.> A malformed call, an unknown agent type, a guard
	    that refused, a spawn callback that died, a child that failed and
	    an inner provider that threw all come back as C<is_error> results.

	    Within a mixed batch the inner calls are dispatched first, as one
	    batch, then any C<task_answer> calls on this thread, and the
	    C<task> and C<task_wait> calls last — B<all of them at once>, one
	    thread each, reassembled in the caller's order. See L</Several
	    task calls at once>.

	    The answers go before the waits for a reason: a turn that both
	    answers a question and collects the agent that asked it is the
	    obvious one for a model to write, and dispatching it in the order
	    it was written would park on a child that is blocked on an answer
	    sitting two calls to its right. Answering is a table update and
	    returns immediately, so there is nothing to gain by threading it
	    and a deadlock to avoid by not. )
	method execute-tool-calls(@tool-calls --> List) {
		my @results;
		my @forward;
		my @tasks;
		my @answers;

		# THE PARENT RUN, captured ONCE, here, before anything is spawned —
		# and held for the whole batch rather than looked up again later.
		# `Loop.live-run` answers with nothing for a run that has finished,
		# and a cancelled parent finishes while this batch is still being
		# dispatched (the loop detaches the call it cancelled), so a lookup
		# taken any later than this can legitimately come back empty and
		# leave a child with nothing watching it. Captured, it is still the
		# run whose `cancellation` this batch belongs to, done or not.
		my $parent = self!parent-run;

		# The collected-results cache belongs to ONE parent run, and this is
		# the one place that knows which run a batch is for.
		self!scope-settled($parent);

		for @tool-calls.kv -> $index, $call {
			my $id = $call ~~ Associative ?? ($call<id> // '').Str !! '';
			my $name = tool-name-of($call);

			# A call whose name cannot be read is not one this composer can
			# claim, so it goes to the inner provider — which answers it
			# with its own well-formed error rather than a second opinion
			# invented here.
			if $name.defined && ($name eq TASK-TOOL || $name eq WAIT-TOOL) {
				@tasks.push: %( :$index, :$id, :$name, call => $call );
			}
			elsif $name.defined && $name eq ANSWER-TOOL {
				@answers.push: %( :$index, :$id, call => $call );
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

		# ANSWERS FIRST, and on this thread. A batch that both answers a
		# question and collects the agent that asked it — which is the
		# obvious turn for a model to write once it has an answer — would
		# otherwise park on a child that is still blocked on the answer
		# sitting two calls to its right. Answering is a table update and
		# returns immediately, so there is nothing to gain by threading it
		# and a deadlock to avoid by not.
		for @answers -> %item {
			my $answer;
			my $threw;
			{
				CATCH { default { $threw = $_ } }
				$answer = self!run-answer(%item<call>, %item<id>);
			}
			@results[%item<index>] = $threw.defined
				?? error-result(
					%item<id>,
					'The subagent layer failed: '
						~ ($threw.message.lines.head // $threw.^name),
				)
				!! $answer;
		}

		# CONCURRENTLY, and the whole of why: a task call returns only when
		# its child has settled, so running them in a `for` loop made a
		# batch of N delegations strictly serial however many slots the
		# host had free. Started here rather than deeper down because this
		# is the one place that knows the batch is a batch.
		#
		# Nothing else changes: each task still answers for itself, the
		# guards and the slot reservation are still one critical section
		# apiece (see The guards), and the results are still assembled by
		# INDEX, on this thread, in the caller's order.
		my @running = @tasks.map(-> %item {
			start {
				# Belt and braces around a method that already answers
				# rather than throwing: "never throws" is the provider
				# contract, and a future edit that forgets it must not take
				# the run down — nor, now, break a Promise nobody can catch.
				my $answer;
				my $threw;
				{
					CATCH { default { $threw = $_ } }
					$answer = %item<name> eq WAIT-TOOL
						?? self!run-wait(%item<call>, %item<id>, $parent)
						!! self!run-task(%item<call>, %item<id>, $parent);
				}

				$threw.defined
					?? error-result(
						%item<id>,
						'The subagent layer failed: '
							~ ($threw.message.lines.head // $threw.^name),
					)
					!! $answer;
			}
		}).eager;

		for @tasks.kv -> $at, %item {
			# `await` on a Promise that somehow broke throws, and this
			# method promises never to. The block above catches everything
			# `!run-task` can raise, so a break here is the scheduler
			# itself failing — still an answer the model gets rather than an
			# exception the run dies of.
			my $result;
			{
				CATCH {
					default {
						$result = error-result(
							%item<id>,
							'The subagent layer failed: '
								~ (.message.lines.head // .^name),
						);
					}
				}
				$result = await @running[$at];
			}
			@results[%item<index>] = $result;
		}

		@results.List;
	}

	# === One task call ===

	#|( The keys of C<%arguments> that C<@allowed> does not name, sorted so
	    a message built from them is the same message twice.

	    Generic over the allow-list on purpose: every tool this composer
	    publishes checks its own call against its own declaration, and a
	    helper that knew about C<task> would have to be copied for the
	    next one.

	    An B<empty> allow-list answers with nothing. A declaration without
	    C<properties> describes no arguments at all, and taking that to
	    mean "every key is unknown" would turn a tool whose schema this
	    layer failed to read into a tool that refuses every call it is
	    given — the loudest possible failure for the least reliable
	    reason. Matching is exact and case-sensitive: JSON keys are, and a
	    model that wrote C<Agent-Type> wrote a key no schema declared.

	    B<Not API.> It is package-visible so that this module's own tests
	    can pin the empty-allow-list case, which no declaration this
	    composer publishes can reach; treat it as private and expect it to
	    move with the tools that use it. )
	our sub unknown-argument-keys(%arguments, @allowed --> List:D) {
		return () unless @allowed.elems;
		my $known = @allowed.grep({ $_ ~~ Str:D }).map(*.Str).Set;
		%arguments.keys.map(*.Str).grep({ !$known{$_} }).sort.List;
	}

	#|( The parameter L<MCP::Client::Reasons> adds to every declaration on
	    the way out and strips from every call on the way down — published
	    there as C<MCP::Client::Reasons::REASON-PARAM>, and repeated here
	    as a literal rather than imported, because that layer is stacked
	    only when its host turns reasons on and this module must not grow
	    a dependency on a stack it may never be in.

	    Always tolerated, whether or not the layer is there: a model that
	    has been asked for a C<reason> on every call for a whole
	    conversation will write one on this call too, and refusing a
	    delegation over a habit the harness taught it would be the check
	    doing harm. )
	my constant REASON-PARAM = 'reason';

	#|( The keys a C<task> call may carry, in the order the model is told
	    about them: the required ones first, then the rest, read from the
	    declaration itself so the check and the schema cannot drift. )
	method !task-argument-keys(--> List:D) {
		self!declared-argument-keys(self!task-declaration);
	}

	#|( The same, for any declaration this composer publishes: the keys its
	    schema names, required ones first. Read from the declaration itself
	    so a tool's check and its schema cannot drift apart — which is the
	    whole reason the three tools share one helper instead of three
	    hand-written allow-lists. )
	method !declared-argument-keys(%declaration --> List:D) {
		my $parameters = %declaration<function><parameters>;
		my $properties = $parameters ~~ Associative ?? $parameters<properties> !! Nil;
		my @declared = ($properties ~~ Associative ?? $properties.keys !! ())
			.map(*.Str).sort.List;
		my $declared = @declared.Set;

		my $required = $parameters ~~ Associative ?? $parameters<required> !! Nil;
		my @first = ($required ~~ Positional ?? $required.list !! ())
			.grep({ $_ ~~ Str:D }).map(*.Str).grep({ $declared{$_} }).List;
		my $first = @first.Set;

		(|@first, |@declared.grep({ !$first{$_} })).List;
	}

	#|( What the model is told about a call carrying keys no schema
	    declared: which keys, which keys it may use, and — the part that
	    actually recovers the turn — what this almost always means and what
	    to do about it. A refusal that only said "unknown key" would get
	    the key deleted and the stump re-sent.

	    The head is the same for all three tools, because the diagnosis is;
	    C<$tail> is what each one says about the consequence and the
	    re-emission, which is not (nothing is B<started> by a
	    C<task_answer>, and a clipped answer is not a clipped brief). )
	method !unknown-arguments-refusal(
		Str:D $tool, @unknown, @allowed, Str:D $tail,
		--> Str:D
	) {
		"The '$tool' call carries "
			~ (@unknown.elems == 1
				?? 'an argument that is not part of it: '
				!! 'arguments that are not part of it: ')
			~ @unknown.map({ "'{argument-key-label($_)}'" }).join(', ')
			~ ". The arguments a '$tool' call takes are: "
			~ @allowed.map({ "'$_'" }).join(', ')
			~ '. ' ~ $tail;
	}

	# The `task` tail: the clip diagnosis, which is the whole reason this
	# check exists.
	method !task-unknown-tail(--> Str:D) {
		"Nothing was started.\n"
			~ 'Extra keys like these usually mean the call was cut off or '
			~ 'corrupted while it was being written — they read like '
			~ 'fragments of a longer prompt that ran out of room, and the '
			~ "'prompt' that did arrive is a stump of what was meant. "
			~ "Re-emit the whole '{TASK-TOOL}' call in your next turn, with "
			~ "the complete task in 'prompt' and nothing else besides the "
			~ 'declared arguments.';
	}

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

		# STRICT, and checked FIRST — before agent-type, before prompt.
		# A provider that clipped a long brief mid-generation can still
		# close the JSON at the cap: what was left of the prompt gets
		# railroaded into keys of the provider's own invention, the call
		# parses, agent-type and prompt are both there, and a child is
		# started on a sentence and a half. Ignoring the junk spawns that
		# child; complaining about whichever required key the clip
		# happened to eat sends the model looking for a mistake it did not
		# make. Naming the junk is the only answer that describes what
		# actually happened, and it is worth one refused turn.
		my @allowed = self!task-argument-keys;
		my @unknown = unknown-argument-keys(
			$arguments, (|@allowed, REASON-PARAM),
		);
		return error-result(
			$id,
			self!unknown-arguments-refusal(
				TASK-TOOL, @unknown, @allowed, self!task-unknown-tail,
			),
		) if @unknown.elems;

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

			# The LIVE children, not every owned one, and the grep is
			# inlined rather than a call to `live-count` because $!lock is
			# not reentrant. A wedged child is still owned — still
			# cancellable, still rendered — but it will never answer, so
			# counting it here would refuse work on behalf of something
			# that has stopped doing any. The message reports the live
			# count for the same reason: telling a model "there are
			# already 2" when only one of them can ever answer is telling
			# it to wait for something that is not coming.
			my Int $live = %!children.values.grep({ !($_<wedged> // False) }).elems;
			if $live >= $!max-live {
				$refusal = "There are already $live subagents running, which is "
					~ "the limit ({$!max-live}). Wait for one of them to answer "
					~ 'before starting another, or do this piece of work yourself.';
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
					wedged            => False,
					# The run this child is BILLED to, captured with the
					# slot: a child that finishes with nobody waiting is
					# recorded from its own drain thread, which has no
					# batch around it to ask.
					parent           => $parent,
				);

				# THE FRAMING, kept beside the slot rather than in it,
				# because a background completion turn is built after the
				# slot has gone and still has to name what it is about.
				# See %!identities.
				%!identities{$agent-id} = %(
					:$agent-id, agent-type => $type-name, :$label,
					'call-id' => $id, :$prompt,
				);
			}
		};

		return error-result($id, $refusal) if $refusal.defined;

		self!spawn-and-settle(
			$id, $agent-id, $type.Hash, $type-name, $prompt, $label, $parent,
		);
	}

	# === Answering a child, and collecting one ===

	#|( One C<task_answer> call: hand a parked question its answer, keep
	    the vow the child's host is waiting on, and tell the model what
	    happens next.

	    Never spawns, never takes a slot, never touches the identical-spawn
	    tally — by construction rather than by exemption, because this path
	    does not go anywhere near C<!run-task>. Every refusal leaves the
	    question exactly where it was: a model that got the shape wrong
	    must be able to try again, and a question dropped on a malformed
	    answer would strand the child that asked it. )
	method !run-answer($call, Str:D $id --> Hash:D) {
		my $function = $call ~~ Associative ?? $call<function> !! Any;
		my $arguments = parsed-arguments(
			$function ~~ Associative ?? $function<arguments> !! Str,
		);

		return error-result(
			$id,
			"The arguments to '{ANSWER-TOOL}' are not a JSON object. Call it "
				~ 'with { "agent-id": "<the agent that asked>", "answer": '
				~ '"<your answer>" }.',
		) without $arguments;

		my @allowed = self!declared-argument-keys(self!answer-declaration);
		my @unknown = unknown-argument-keys(
			$arguments, (|@allowed, REASON-PARAM),
		);
		return error-result(
			$id,
			self!unknown-arguments-refusal(
				ANSWER-TOOL, @unknown, @allowed,
				"Nothing was answered, and the agent is still waiting.\n"
					~ 'Extra keys like these usually mean the call was cut '
					~ 'off or corrupted while it was being written. Re-emit '
					~ "the whole '{ANSWER-TOOL}' call, with the whole answer "
					~ "in 'answer' (or in 'fields') and nothing else besides "
					~ 'the declared arguments.',
			),
		) if @unknown.elems;

		my $raw-agent = $arguments<agent-id>;
		return error-result(
			$id,
			"The '{ANSWER-TOOL}' call has no agent-id. Answer with the id of "
				~ 'the agent that asked — it is named in the question.',
		) unless $raw-agent ~~ Str:D && $raw-agent.trim.chars;

		my Str $agent-id = $raw-agent.trim;

		# The question as it stands, read once. Nothing is removed here:
		# the checks below can still refuse, and a refusal must leave the
		# child exactly as blocked as it was.
		my %state = $!lock.protect: {
			%(
				question => (%!questions{$agent-id}:exists
					?? question-data(%!questions{$agent-id})
					!! Nil),
				owned    => ?(%!children{$agent-id}:exists),
				settled  => ?(%!settled{$agent-id}:exists),
			);
		};

		without %state<question> {
			return error-result(
				$id,
				(%state<owned> || %state<settled>)
					?? "The $agent-id agent has not asked anything that is "
						~ 'waiting for an answer. It may have been answered '
						~ 'already, or the agent may have stopped waiting. '
						~ "Collect it with '{WAIT-TOOL}' when you want what "
						~ 'it finally said.'
					!! "There is no agent called '$agent-id' here, so there "
						~ 'is nothing of its to answer. Use the agent-id '
						~ 'exactly as the question gave it.',
			);
		}

		my %question = %state<question>;
		my @required = required-fields(%question<schema>);
		my Bool $form = ?schema-fields(%question<schema>).elems;
		my Bool $decline = json-flag($arguments<decline>);
		my Str $reason = $arguments<reason> ~~ Str:D
			&& $arguments<reason>.trim.chars
			?? $arguments<reason>.trim
			!! Str;

		my %outcome;
		my %recorded;

		if $decline {
			%outcome = action => 'decline';
			# Not part of the elicitation outcome contract, which ignores
			# what it does not know — carried anyway, because a host that
			# can tell the child WHY it was refused gives it something to
			# act on instead of a bare no.
			%outcome<reason> = $reason if $reason.defined;
			%recorded = ();
		}
		elsif $form {
			my $fields = $arguments<fields>;
			return error-result(
				$id,
				"The $agent-id agent asked for named fields, so this answer "
					~ "needs 'fields' — a JSON object with "
					~ (@required.elems
						?? @required.map({ "'$_'" }).join(', ') ~ ' in it'
						!! 'the values it asked for')
					~ ". The question is still waiting.\n"
					~ self!form-reminder(%question),
			) unless $fields ~~ Associative;

			my @missing = @required.grep({ !field-given($fields, $_) }).List;
			return error-result(
				$id,
				"The answer to the $agent-id agent is missing "
					~ (@missing.elems == 1 ?? 'a required field: ' !! 'required fields: ')
					~ @missing.map({ "'$_'" }).join(', ')
					~ ". The question is still waiting — send it again with "
					~ "every required field filled in.\n"
					~ self!form-reminder(%question),
			) if @missing.elems;

			%recorded = $fields.Hash;
			%outcome = action => 'accept', content => %recorded;
		}
		else {
			my $answer = $arguments<answer>;
			return error-result(
				$id,
				"The '{ANSWER-TOOL}' call has no answer. Put what the "
					~ "$agent-id agent should be told in 'answer', or "
					~ "decline with \"decline\": true and a 'reason' if it "
					~ 'cannot be answered. The question is still waiting.',
			) unless $answer ~~ Str:D && $answer.trim.chars;

			%recorded = answer => $answer.Str;
			%outcome = action => 'accept', content => %recorded;
		}

		# THE HANDOVER, and the one place a vow is taken out of the table:
		# whoever wins this critical section keeps it, and a second
		# `task_answer` for the same agent finds nothing and says so rather
		# than throwing on a vow that has already been kept.
		my $vow = $!lock.protect: {
			with %!questions{$agent-id} {
				my $taken = $_<vow>;
				%!questions{$agent-id}:delete;
				$taken;
			}
			else {
				Nil;
			}
		};

		without $vow {
			return error-result(
				$id,
				"The $agent-id agent's question was already answered. "
					~ "Collect what it says with '{WAIT-TOOL}'.",
			);
		}

		# Outside the lock: keeping a vow runs somebody else's
		# continuation, and this lock is a leaf.
		try $vow.keep(%outcome);

		self!append-envelope('subagent-answered', %(
			:$agent-id,
			token     => %question<token>,
			'call-id' => $id,
			action    => %outcome<action>,
			content   => excerpt-values(%recorded, SETTLE-EXCERPT),
			|($reason.defined ?? (reason => excerpt($reason, SETTLE-EXCERPT)) !! ()),
		), self!child-emitter($agent-id));

		%(
			role         => 'tool',
			tool_call_id => $id,
			content      => ($decline
				?? "The $agent-id agent has been told that its question "
					~ 'cannot be answered'
					~ ($reason.defined ?? " ($reason)" !! '')
					~ '. It carries on from where it stopped and decides for '
					~ 'itself what to do. ' ~ self!collect-guidance($agent-id)
				!! "Answered. The $agent-id agent carries on from where it "
					~ 'stopped. ' ~ self!collect-guidance($agent-id)),
			is_error     => False,
		);
	}

	#|( What to do about a child that has just been answered, or released
	    with an interim result: one sentence, and which one depends on
	    whether this composer delegates in the background.

	    B<Blocking mode keeps the collect reflex>, because it is true
	    there: nothing else will ever hand that answer over.
	    B<Background mode has to unlearn it.> A model told to collect
	    after every answer collects after every answer, which is a
	    synchronous wait re-introduced one tool call at a time — the exact
	    behaviour the acknowledgement path exists to remove. )
	method !collect-guidance(Str:D $agent-id --> Str:D) {
		return "Collect what it finally says with '{WAIT-TOOL}': "
			~ '{ "agent-id": "' ~ $agent-id ~ '" }.'
			unless self!background-mode;

		'What it finally says will arrive here on its own, as an automated '
			~ '[background event] turn — you do not have to collect it. '
			~ "Use '{WAIT-TOOL}' (" ~ '{ "agent-id": "' ~ $agent-id
			~ '" }) only if you cannot go on without it.';
	}

	# The fields a form question asked for, as a reminder to a model that
	# answered it in the wrong shape. The question itself is delivered once
	# and once only; this is the schema, not the question.
	method !form-reminder(%question --> Str:D) {
		my @fields = schema-fields(%question<schema>);
		return '' unless @fields.elems;

		"The fields it asked for are:\n" ~ @fields.map({
			'- ' ~ $_<name>
				~ ($_<type>.chars ?? " ({$_<type>}" !! ' (')
				~ ($_<required> ?? ($_<type>.chars ?? ', required)' !! 'required)') !! ')')
				~ ($_<description>.chars
					?? ': ' ~ one-line($_<description>, QUESTION-LINE)
					!! '');
		}).join("\n");
	}

	#|( One C<task_wait> call: hand back a child that has already been
	    collected, or park on one that is still going.

	    Three answers and no fourth: the cached final result for a child
	    whose C<task> call has already settled terminally (idempotent, in
	    the same words, however many times a model asks); a fresh wait for
	    a child this composer still owns, with exactly the interim, cancel
	    and unstoppable behaviour the original C<task> call had; and an
	    C<is_error> for an id that means nothing here. )
	method !run-wait($call, Str:D $id, $parent --> Hash:D) {
		my $function = $call ~~ Associative ?? $call<function> !! Any;
		my $arguments = parsed-arguments(
			$function ~~ Associative ?? $function<arguments> !! Str,
		);

		return error-result(
			$id,
			"The arguments to '{WAIT-TOOL}' are not a JSON object. Call it "
				~ 'with { "agent-id": "<the agent to wait for>" }.',
		) without $arguments;

		my @allowed = self!declared-argument-keys(self!wait-declaration);
		my @unknown = unknown-argument-keys(
			$arguments, (|@allowed, REASON-PARAM),
		);
		return error-result(
			$id,
			self!unknown-arguments-refusal(
				WAIT-TOOL, @unknown, @allowed,
				'Nothing was collected, and the agent is untouched: it can '
					~ 'still be waited for. Re-emit the call with just the '
					~ "'agent-id' of the agent you are waiting for.",
			),
		) if @unknown.elems;

		my $raw-agent = $arguments<agent-id>;
		return error-result(
			$id,
			"The '{WAIT-TOOL}' call has no agent-id. Wait for one agent at a "
				~ 'time, by the id its result was given under.',
		) unless $raw-agent ~~ Str:D && $raw-agent.trim.chars;

		my Str $agent-id = $raw-agent.trim;

		# THE CACHE FIRST. A model that collects the same agent twice is
		# not making a mistake — it may have lost the thread, or be
		# re-reading its own turn — and the honest answer is the one it
		# already had, not "no such agent" for a child that answered
		# perfectly well a minute ago.
		my $cached = $!lock.protect: {
			%!settled{$agent-id}:exists ?? %!settled{$agent-id}.Hash !! Nil;
		};
		with $cached -> %hit {
			# COLLECTED HERE, and that is what stops the same answer being
			# said twice. A child that settled with nobody parked on it
			# left its answer on the bus as a turn; the model has now asked
			# for it by name, so this call hands it over and takes the
			# queued turn back with it. (The operation is normally closed
			# already — `:collected` withdraws either way, which is the
			# whole reason it does.)
			self!bus-settle($agent-id, :collected);
			return %(
				role         => 'tool',
				tool_call_id => $id,
				content      => %hit<content>,
				is_error     => %hit<is_error>,
			);
		}

		# A child is registered with its run, its emitter and its tap in
		# one critical section, so all three arrive together or not at all
		# — but the SLOT exists from admission, which is earlier. Waiting
		# for the run to appear covers the window in between; a wait that
		# times out is a spawn callback that is still building, and saying
		# so beats parking on something that does not exist.
		my $deadline = now + STREAM-GRACE;
		my %entry;
		loop {
			%entry = $!lock.protect: {
				%!children{$agent-id}:exists
					?? child-snapshot(%!children{$agent-id})
					!! %();
			};
			last unless %entry.elems;
			last if %entry<run> ~~ LLM::Agent::Run:D;
			last if now > $deadline;
			await Promise.in(CANCEL-POLL);
		}

		return error-result(
			$id,
			"There is no live agent called '$agent-id' here. It may not have "
				~ 'survived a restart, it may already have been collected, '
				~ 'or the id may be wrong — check the id the delegation was '
				~ 'started under.',
		) unless %entry.elems;

		return error-result(
			$id,
			"The $agent-id agent is still starting up and has nothing to "
				~ "wait on yet. Try '{WAIT-TOOL}' again in your next turn.",
		) unless %entry<run> ~~ LLM::Agent::Run:D;

		self!await-child(
			%entry<run>, $id, $agent-id, %entry<agent-type>, $parent,
			%entry<emit>, %entry<published>, WAIT-TOOL,
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

		# THE PROMISE, WRITTEN DOWN, and before the child exists on
		# purpose: from here until this operation settles, the run will not
		# end. Building a child is somebody else's code and takes as long
		# as it takes, and a run that finished in that gap would finish
		# having told the model an answer was coming.
		#
		# Outside the lock the slot was taken under, deliberately: the bus
		# refuses at its own capacity under its own lock, so two spawns
		# arriving at once cannot both take the last place, and $!lock
		# stays the strict leaf the rest of this class relies on.
		if self!background-mode {
			my %admitted = self!bus-open($agent-id, $type-name, $label, $id);
			unless %admitted<ok> {
				self!release-child($agent-id);
				return error-result(
					$id, self!outstanding-refusal(%admitted, $type-name),
				);
			}
			self!warn-bus-mismatch(&emit);
			try &emit(LLM::Agent::Event::BackgroundOpStarted.new(
				op-id   => $agent-id,
				op-kind => 'subagent',
				label   => ($label.defined ?? $label !! Str),
				call-id => $id,
			));
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
			# COLLECTED, not delivered: the model is being told right now,
			# in this call's own result, so a background turn saying the
			# same thing again would be the same news twice.
			self!bus-settle($agent-id, :collected, :&emit);
			self!release-child($agent-id);
			return error-result(
				$id,
				"The $type-name agent could not be started: "
					~ ($threw.message.lines.head // $threw.^name),
			);
		}

		unless $handle.defined && $handle.can('run')
			&& $handle.can('session-path') {
			self!bus-settle($agent-id, :collected, :&emit);
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
			self!bus-settle($agent-id, :collected, :&emit);
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
			# The join to the tool-dispatched line for the `task` call that
			# started this child, and to the tool card a UI drew for it.
			'call-id'  => $id,
			child-path => $child-path,
		), &emit);

		# THE FORK IN THE ROAD, and it is the only one: with a bus the call
		# acknowledges and comes back, and the child reports itself through
		# the paths that already existed for a child nobody was waiting on
		# (`!own-child`'s drain hook, `!record-uncollected`). Without one it
		# waits, exactly as it always has.
		return self!settle-child(
			$child, $id, $agent-id, $type-name, $label, $parent, &emit,
		) unless self!background-mode;

		self!tap-child($child, $id, $agent-id, $type-name, $label, &emit);
		self!ack-result($id, $agent-id, $type-name, $label, $prompt);
	}

	#|( The acknowledgement a background C<task> call answers with. It is
	    B<not> the agent's answer, and every sentence of it is there to
	    stop the model reading it as one.

	    In order: what this is (a status, not an answer), who is working on
	    what, where the real answer will appear and how it will be marked,
	    that finishing the turn is B<safe> — which is the one thing a model
	    will not believe unless it is told, because everything it has ever
	    been trained on says a turn ends the conversation — what to do
	    meanwhile, and the escape hatch for when the very next thing it
	    needs is this result.

	    B<Small by construction.> A background turn can be long because it
	    carries a result; an acknowledgement carries nothing, and a model
	    that starts a fleet of eight gets eight of these in one batch. The
	    only variable-length part is the label, and it is cut. )
	method !ack-result(
		Str:D $id, Str:D $agent-id, Str:D $type-name, $label, Str:D $prompt,
		--> Hash:D
	) {
		my Str $doing = ($label.defined && $label.chars)
			?? one-line($label, ACK-LABEL)
			!! one-line($prompt, ACK-LABEL);

		%(
			role         => 'tool',
			tool_call_id => $id,
			content      => "STATUS: started — this is not the agent's "
				~ "answer. The $type-name agent ($agent-id) is now working "
				~ "in the background on: $doing. Its answer will arrive "
				~ 'later in this conversation as an automated turn marked '
				~ '[background event]. The conversation will not end while '
				~ 'it is still working, so it is safe to finish your turn. '
				~ 'Keep working on everything that does not depend on its '
				~ 'result. If the very next thing you need IS its result, '
				~ "call '{WAIT-TOOL}' with agent-id '$agent-id' to wait for "
				~ 'it here.',
			is_error     => False,
			# The flag the LOOP records on the tool message this becomes:
			# an acknowledged operation whose result is still outstanding
			# looks exactly like a finished tool call otherwise, and a
			# crash repair reading the transcript back has to be able to
			# tell them apart. See LLM::Agent::Loop's `!settle-op`.
			background   => True,
		);
	}

	#|( What the model is told when the bus is full: the numbers, and the
	    two things that actually clear the way. Deliberately the same shape
	    as the C<max-live> refusal beside it — a limit, what it is, and
	    what to do instead — because they are the same situation seen from
	    two different tables. )
	method !outstanding-refusal(%admitted, Str:D $type-name --> Str:D) {
		my Str $reason = (%admitted<reason> // '').Str;

		return "The $type-name agent could not be started: the completion "
			~ "bus already has an operation called that, which should not "
			~ 'be possible. Try again with a different task.'
			if $reason eq 'duplicate';

		# A bus that threw is a host problem, and the model can do nothing
		# about it but not delegate. Saying so beats quoting it two
		# question marks where the numbers should be.
		return "The $type-name agent could not be started: the background "
			~ 'work register could not be reached, so there is no way to '
			~ 'promise you an answer. Do this piece of work here instead.'
			if $reason eq 'threw';

		'There are already ' ~ (%admitted<outstanding> // '?')
			~ ' background operations outstanding, which is the limit ('
			~ (%admitted<max> // '?') ~ '). Their answers arrive on their '
			~ 'own as automated [background event] turns — wait for some of '
			~ "them, or collect one now with '{WAIT-TOOL}' — before starting "
			~ 'another, or do this piece of work yourself.';
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
		$child.drained.then({
			# COLLECTED BEFORE IT IS LET GO, and this is what makes an
			# interim settle safe: a child released with nobody waiting on
			# it would take its answer with it, and the `task_wait` that
			# was told to collect it would find no such agent. Once
			# recorded, the answer is in the cache and the transcript
			# whether anybody asks for it or not.
			try self!record-uncollected($agent-id, $child);
			try self!release-child($agent-id);
			True;
		});
		$child.result.then({
			start {
				await Promise.anyof($child.drained, Promise.in($!drain-grace));
				if $child.drained.status ~~ Planned {
					$!lock.protect: {
						%!children{$agent-id}<wedged> = True
							if %!children{$agent-id}:exists;
					};

					# AND IT LEAVES THE OUTSTANDING COUNT, which is the
					# same argument one table further along: a wedge stops
					# counting against `max-live` because it will never
					# answer, and it has to stop holding a background run
					# open for exactly the same reason. Its result IS kept
					# — the wedge is in the drain, not in the work — so
					# there is a real answer to deliver rather than a
					# silence to invent. `!record-terminal` is the
					# once-guard, so a call that was parked on it and got
					# there first simply makes this a no-op.
					try self!record-uncollected($agent-id, $child);
				}
			}
			True;
		});
		Nil;
	}

	# Let go of one child's slot. Idempotent: the drained hook and the
	# never-started paths can both reach it.
	#
	# The tap goes with it, and any question of the child's still parked
	# here: a child this composer has let go of will never be told
	# anything, and a host thread blocked on an answer it is never getting
	# is worse than a refused one.
	#
	# The tap is closed when the child's stream has finished PUBLISHING,
	# not when this runs. `drained` can keep with the terminal event still
	# in flight, and a tap closed there takes the child's own ending off
	# the parent's stream — which is the one event a consumer is most
	# likely to be waiting for.
	method !release-child(Str:D $agent-id --> Nil) {
		my %taken = $!lock.protect: {
			my %entry = (%!children{$agent-id}:exists)
				?? %(
					tap       => %!children{$agent-id}<tap>,
					published => %!children{$agent-id}<published>,
				)
				!! %();
			%!children{$agent-id}:delete;
			%entry;
		};

		with %taken<tap> -> $tap {
			if %taken<published> ~~ Promise:D {
				%taken<published>.then({ try $tap.close; True });
			}
			else {
				try $tap.close;
			}
		}

		self!sweep-questions($agent-id);
		Nil;
	}

	# Tap the child and wait for it. The tap is the child's ONLY one: a
	# Supplier::Preserving delivers its buffer to the first tap and replays
	# nothing to a second, so a child tapped anywhere else has already lost
	# its beginning to whoever got there first.
	#
	# It therefore belongs to the CHILD and not to this call: an interim
	# settle hands the task call back while the child goes on producing,
	# and a later `task_wait` must find the same tap rather than open a
	# second one that would see nothing. It is closed on the terminal path
	# and, as a backstop, when the child is released.
	method !settle-child(
		LLM::Agent::Run:D $child, Str:D $id, Str:D $agent-id,
		Str:D $type-name, $label, $parent, &emit,
		--> Hash:D
	) {
		my %tapped = self!tap-child(
			$child, $id, $agent-id, $type-name, $label, &emit,
		);
		my $tap = %tapped<tap>;
		my Bool $orphan = %tapped<orphan>;
		LEAVE { try $tap.close if $orphan }

		self!await-child(
			$child, $id, $agent-id, $type-name, $parent, &emit,
			%tapped<published>, TASK-TOOL,
		);
	}

	#|( Open the child's single tap and register it, answering
	    C<< { tap, published, orphan } >>.

	    Split out of C<!settle-child> because a B<background> C<task> call
	    taps and does not wait: the tap belongs to the child and not to the
	    call, which was already true for a call released by a question and
	    is now true for every call in background mode.

	    C<orphan> is True when the slot had already gone by the time the
	    registration ran, which means this call has been left and nothing
	    will ever close this tap but its caller. The blocking path closes
	    it in a C<LEAVE>; the background path closes it here, because there
	    is no wait to leave. )
	method !tap-child(
		LLM::Agent::Run:D $child, Str:D $id, Str:D $agent-id,
		Str:D $type-name, $label, &emit,
		--> Hash:D
	) {
		my $published = Promise.new;
		my $vow = $published.vow;

		my $tap = $child.events.tap(
			-> $event {
				self!forward(
					$agent-id, $type-name, $label, $id, $event, &emit,
				);
			},
			# `try`, because keeping a vow twice throws and a Supply that
			# somehow did both would take the tap's thread with it.
			done => { try $vow.keep(True) },
			quit => -> $ { try $vow.keep(True) },
		);

		my Bool $orphan = $!lock.protect: {
			if %!children{$agent-id}:exists {
				%!children{$agent-id}<tap> = $tap;
				%!children{$agent-id}<published> = $published;
				%!children{$agent-id}<emit> = &emit;
				False;
			}
			else {
				# The slot has already gone, which means this call has been
				# left. Nothing will ever close this tap but us.
				True;
			}
		};

		# The background path has no LEAVE to hang this on: it returns the
		# acknowledgement and the call is over, so an orphaned tap has to
		# be closed on the spot or it is never closed at all.
		try $tap.close if $orphan && self!background-mode;

		%( :$tap, :$published, :$orphan );
	}

	#|( Wait on one child for one call — the shared body of a C<task>
	    call's own wait and of every C<task_wait> after it.

	    Three ways out, and the caller cannot tell which without reading
	    the result: the child settled (its answer, the settle envelope and
	    its spend, each exactly once however many calls were waiting), a
	    question interrupted the wait (an interim result, and the child
	    carries on), or the child was asked to stop and did not.

	    The park callbacks bracket the whole of it, on every path including
	    a throw: a host counting parked parents must never be left counting
	    one that came back. )
	method !await-child(
		LLM::Agent::Run:D $child, Str:D $id, Str:D $agent-id,
		Str:D $type-name, $parent, &emit, $published, Str:D $tool,
		--> Hash:D
	) {
		# 'error' until something better is known: the LEAVE below fires
		# whatever happens, and a wait that died still stopped waiting.
		my Str $outcome-kind = 'error';

		self!mark-parked($agent-id, 1);
		self!fire-child-callback(
			&!on-child-park, %( :$agent-id, 'call-id' => $id, :$tool ),
		);
		LEAVE {
			self!mark-parked($agent-id, -1);

			# THE TERMINAL THAT A DEFERRAL WOULD OTHERWISE LOSE, and the
			# other half of C<!record-uncollected>'s contract.
			#
			# A child can settle while a call is parked on it and STILL
			# come out of that call some way other than terminally: the
			# poll reads the result before the question table, so a child
			# whose result keeps between those two reads is left behind by
			# a call that comes back interim. The drain hook that follows
			# defers to this call (it is parked, so it is assumed to be
			# writing the terminal itself) and then releases the child —
			# and without this line nobody would ever write it. No settle
			# envelope, no spend on the parent's bill, nothing in the
			# collected cache, and the `task_wait` the interim just told
			# the model to make would answer "no such live agent" for a
			# child that finished perfectly well.
			#
			# So: whatever the way out, a child whose result is kept gets
			# its terminal written here. `!record-terminal` is the single
			# once-guard, so a drain hook that got there first simply
			# makes this a no-op — and `$parent`/`&emit` are this call's
			# own, because the entry they would otherwise be read from is
			# exactly what has just been deleted.
			if $outcome-kind ne 'final'
				&& $child.result.status !~~ Planned {
				try self!write-terminal(
					$agent-id,
					self!child-answer($agent-id, $type-name, $child),
					$parent, &emit,
				);
			}

			self!fire-child-callback(
				&!on-child-unpark,
				%( :$agent-id, 'call-id' => $id, :$tool,
					outcome => $outcome-kind ),
			);
		}

		my Str $status = self!park-on-child($child, $agent-id, $parent);

		if $status eq 'interrupt' {
			$outcome-kind = 'interim';
			return self!interim-result(
				$id, $agent-id, $type-name, &emit,
			);
		}

		if $status eq 'unstoppable' {
			$outcome-kind = 'unstoppable';
			# A child that will not stop cannot answer anything either.
			self!sweep-questions($agent-id);
			return self!unstoppable-result($id, $agent-id, $type-name, &emit);
		}

		$outcome-kind = 'final';

		# The result is kept BEFORE the terminal event is enqueued (see
		# LLM::Agent::Run), so the stream is still one event behind here.
		# Waiting for its `done` is what makes the terminal reach the
		# parent's stream; the bound is what stops a wedged subscriber
		# holding the parent's tool call open for ever.
		await Promise.anyof($published, Promise.in(STREAM-GRACE))
			if $published ~~ Promise:D;
		self!close-child-tap($agent-id);

		# A child that has stopped is not going to be told anything, so a
		# question of its still parked here is answered `cancel` rather
		# than left for a host that is blocked on it.
		self!sweep-questions($agent-id);

		my %answer = self!child-answer($agent-id, $type-name, $child);
		# COLLECTED. This call is about to hand the model the answer
		# itself, so the background operation closes with nothing to
		# deliver: one presentation, not two. Every other way out of this
		# method — the LEAVE above, the drain hook — enqueues instead,
		# because on those paths nobody has told the model anything.
		self!write-terminal($agent-id, %answer, $parent, &emit, :collected);

		%(
			role         => 'tool',
			tool_call_id => $id,
			content      => %answer<content>,
			is_error     => %answer<is-error>,
		);
	}

	#|( What a settled child's run result means to the parent model: the
	    text of the answer, and whether it is one.

	    Shared by the two places that can be first to read it — a call that
	    was waiting, and the release that follows draining — so the words a
	    C<task_wait> answers with and the words the transcript records
	    cannot come apart. )
	method !child-answer(
		Str:D $agent-id, Str:D $type-name, LLM::Agent::Run:D $child,
		--> Hash:D
	) {
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

		%( :%result, :$outcome, :$content, is-error => $is-error );
	}

	#|( The settle envelope and the spend absorption, ONCE PER CHILD
	    whatever reached it first.

	    A child can be waited on more than once — its C<task> call, and any
	    number of C<task_wait> calls after an interim — and can also finish
	    with nobody waiting at all. A settle envelope written twice would
	    put one child's answer in the transcript twice, and a spend
	    absorbed twice would bill the parent twice for one bill. See
	    C<!record-terminal> for why the guard is in two places. )
	method !write-terminal(
		Str:D $agent-id, %answer, $parent, &emit, Bool:D :$collected = False,
		--> Nil
	) {
		return
			unless self!record-terminal(
				$agent-id, %answer<content>, %answer<is-error>,
			);

		my %who = self!identity-of($agent-id);
		my %result = %answer<result>;
		my %payload =
			agent-id => $agent-id,
			outcome  => %answer<outcome>,
			result   => excerpt(%answer<content>, SETTLE-EXCERPT),
		;
		# The join back to the `task` call that started this child — the
		# same one the spawn envelope carries. It is what lets a repair
		# match a settle it found on disk to the acknowledgement in the
		# conversation, which is the whole of how a result collected while
		# the process was dying is told from one that was lost. Absent for
		# a child whose framing this composer no longer holds (a settle
		# that arrived after the parent run was replaced), never invented.
		%payload<call-id> = %who<call-id>
			if %who<call-id> ~~ Str:D && %who<call-id>.chars;
		# The one conditional key, for the reason the run result's is: a
		# child nobody was counting says nothing rather than a zero it did
		# not measure.
		%payload<spent> = %result<spent>.Hash if %result<spent> ~~ Associative;
		self!append-envelope('subagent-settled', %payload, &emit);

		# AND ONTO THE PARENT'S BILL. What a child spent was spent by this
		# run — it asked for it — so it goes into the accumulators the
		# parent's own caps are checked against. See "A parent pays for its
		# children" and LLM::Agent::Loop's `absorb-spend`.
		self!absorb-child-spend($parent, %result<spent>);

		# AND OFF THE COMPLETION BUS. Inside the once-guard on purpose: the
		# transcript's guard and the bus's are ONE path, so the envelope
		# above and the turn the model will read are written by the same
		# winner and can never disagree about what a child said.
		self!bus-settle($agent-id, %answer, :$collected, :&emit);
		Nil;
	}

	# === The completion bus ===

	#|( Whether this composer delegates in the background. One question,
	    asked in every place the two modes differ, so "no bus means
	    exactly today's behaviour" is a property of one predicate rather
	    than of a dozen scattered conditionals. )
	method !background-mode(--> Bool:D) { $!completion-bus.defined }

	#|( Track a child on the bus, and answer what it said —
	    C<< { ok, outstanding, max, reason? } >>. A bus that throws is a
	    refusal rather than an exception: the guards above it have already
	    taken a slot, and a delegation that dies here would die after the
	    model was charged for it. )
	method !bus-open(
		Str:D $agent-id, Str:D $type-name, $label, Str:D $call-id,
		--> Hash:D
	) {
		my %admitted;
		my $threw;
		{
			CATCH { default { $threw = $_ } }
			%admitted = $!completion-bus.open(
				$agent-id,
				kind  => 'subagent',
				|($label.defined && $label.chars ?? (:$label) !! ()),
				meta  => %(
					'agent-type' => $type-name, 'call-id' => $call-id,
				),
			).Hash;
		}

		return %(
			ok => False, reason => 'threw',
			outstanding => '?', max => '?',
		) if $threw.defined;

		%admitted;
	}

	#|( Say so, loudly, when this composer is tracking children on a bus
	    the loop is not parking on.

	    B<The one wiring mistake background delegation cannot survive.> A
	    composer with a bus acknowledges a C<task> call and promises the
	    model an answer later; a loop without the SAME bus has nothing
	    telling it to wait for one, so it ends the run at the next quiet
	    turn and the answer arrives on a bus nobody is reading. Every
	    delegation is then silently a lie, on every run, and nothing else
	    in the system has a symptom — the child works, the transcript
	    records it, and the conversation simply never hears.

	    It cannot be a construction-time check: the loop does not exist
	    when the composer is built (that is what the deferred C<loop>
	    Callable is for), and the bus is not something either of them can
	    hand the other. So it is checked at the first moment both objects
	    exist, and reported as a C<Log> at C<error> on every delegation
	    it affects — a wiring bug that should be impossible to miss rather
	    than one refusal the model would work around. )
	method !warn-bus-mismatch(&emit --> Nil) {
		my $loop = self!resolve-loop;
		return unless $loop.defined && $loop.can('completion-bus');

		my $theirs = $loop.completion-bus;
		# `===`, object identity: two buses that happen to hold the same
		# things are still two buses, and the loop is only ever going to
		# drain its own.
		return if $theirs.defined && $theirs === $!completion-bus;

		try &emit(LLM::Agent::Event::Log.new(
			level  => 'error',
			logger => 'llm-agent.subagents',
			data   => %(
				message => 'this composer delegates in the background but '
					~ 'its loop is '
					~ ($theirs.defined
						?? 'parked on a DIFFERENT completion bus'
						!! 'not watching a completion bus at all')
					~ ', so the run will end without waiting for this child '
					~ 'and its answer will be delivered to nobody. Give the '
					~ 'SAME LLM::Agent::CompletionBus to both the composer '
					~ "and the loop, or neither.\n"
					~ 'Every delegation is affected, and nothing else has a '
					~ 'symptom: the child works, the transcript records it, '
					~ 'and the conversation never hears.',
			),
		));
		Nil;
	}

	#|( Close a child's background operation, and — unless it was collected
	    by whoever is calling — leave the answer on the bus for the loop to
	    deliver as a framed turn.

	    C<:collected> is every path where the model is being told about
	    this child B<in the result of the call it is making right now>: a
	    C<task_wait> that was parked when the child settled, one that
	    answered from the cache, a spawn that failed, a child cancelled
	    before it started. The same news twice is worse than useless — the
	    second copy reads as a second child.

	    Shielded end to end. The bus is the app's object, and a settle that
	    throws must not take down a tool call that has already done its
	    work; what it costs is a run that parks until its idle valve, which
	    is exactly what the valve is for. )
	method !bus-settle(
		Str:D $agent-id, %answer?, Bool:D :$collected = False, :&emit,
		--> Nil
	) {
		return unless self!background-mode;

		my &report = &emit.defined ?? &emit !! self!child-emitter($agent-id);

		my Bool $closed = False;
		my $threw;
		{
			CATCH { default { $threw = $_ } }
			$closed = ?($collected
				?? $!completion-bus.settle($agent-id, :collected)
				!! $!completion-bus.settle(
					$agent-id,
					deliverable => self!settled-deliverable($agent-id, %answer),
				));
		}

		if $threw.defined {
			try &report(LLM::Agent::Event::Log.new(
				level  => 'error',
				logger => 'llm-agent.subagents',
				data   => %(
					message => 'the completion bus refused a settle, so this '
						~ "agent's answer will not be delivered as a "
						~ 'background turn; the run will stop waiting for it '
						~ 'at its park-idle-timeout',
					agent-id => $agent-id,
					error    => ($threw.message.lines.head // $threw.^name),
				),
			));
			return;
		}

		# Only the once-guard's winner says so. A second settle for the
		# same child closed nothing and has nothing to announce.
		return unless $closed;

		try &report(LLM::Agent::Event::BackgroundOpSettled.new(
			op-id => $agent-id, op-kind => 'subagent', :$collected,
		));
		Nil;
	}

	#|( Everything a background turn needs to name the agent it is about,
	    or as much of it as this composer still holds. See C<%!identities>:
	    the entry outlives the child's slot precisely because the turn is
	    built after the slot has gone. )
	method !identity-of(Str:D $agent-id --> Hash:D) {
		my %who = $!lock.protect: {
			%!identities{$agent-id}:exists
				?? %!identities{$agent-id}.Hash
				!! %();
		};
		%who<agent-type> = 'subagent'
			unless %who<agent-type> ~~ Str:D && %who<agent-type>.chars;
		%who;
	}

	#|( How a background turn refers to an agent:
	    C<(reviewer-1, "the billing review", task call c1, asked to: ...)>.

	    Everything that is known, and nothing that is not. It is long for a
	    parenthesis and that is the point: the turn has to stand on its
	    own, because the acknowledgement it answers is one of the first
	    things a compaction eats and a completion that referred back to it
	    would then be an answer to a question nothing in the conversation
	    asked. )
	method !agent-reference(Str:D $agent-id --> Str:D) {
		my %who = self!identity-of($agent-id);
		my @parts = $agent-id;
		@parts.push: '"' ~ one-line(%who<label>, ACK-LABEL) ~ '"'
			if %who<label> ~~ Str:D && %who<label>.chars;
		@parts.push: 'task call ' ~ %who<call-id>
			if %who<call-id> ~~ Str:D && %who<call-id>.chars;
		@parts.push: 'asked to: ' ~ one-line(%who<prompt>, PROMPT-REFERENCE)
			if %who<prompt> ~~ Str:D && %who<prompt>.chars;

		'(' ~ @parts.join(', ') ~ ')';
	}

	#|( The frame every background turn opens with, verbatim and
	    unconditional.

	    It is three sentences where one would do, and each of them is
	    answering a way a model gets this wrong. The first says what the
	    turn is. The second says who did NOT say it, because a user-role
	    message is a user-role message however it is framed and every prior
	    a model has says somebody is talking to it. The third says what not
	    to do about it — thanking the user for a review they never asked
	    for is the exact failure. )
	method !background-frame(--> Str:D) {
		'[background event] This is an automated notification from the '
			~ 'system, not the user speaking. The user has said nothing '
			~ 'here; do not reply to it as if they had.';
	}

	#|( A settled child, as a deliverable for the bus: the frame and the
	    identity in C<head>, the agent's own words in C<body>, and what to
	    do next in C<tail>.

	    The three-way split is what keeps the excerpt seam honest. The loop
	    routes C<body> — and only C<body> — through it, so a child that
	    answered with a megabyte lands as an excerpt with the rest in an
	    artifact file, while the words that say this is an automated event
	    survive at any size. See L<LLM::Agent::CompletionBus>. )
	method !settled-deliverable(Str:D $agent-id, %answer --> Hash:D) {
		my %who = self!identity-of($agent-id);
		my Str $status = %answer<is-error>
			?? 'STATUS: final — the agent produced no answer, and this is '
				~ 'why:'
			!! "STATUS: final — this is the agent's answer:";

		%(
			kind => 'subagent-settled',
			head => self!background-frame ~ "\n\n"
				~ 'The ' ~ %who<agent-type> ~ ' agent '
				~ self!agent-reference($agent-id) ~ " has finished. $status",
			body => (%answer<content> // '').Str,
			tail => 'Incorporate this result and continue your work. If '
				~ 'nothing else remains, you may conclude.',
			extras => %(
				'completion-of' => $agent-id,
				'agent-type'    => %who<agent-type>,
				outcome         => (%answer<outcome> // 'unknown').Str,
				|(%who<call-id> ~~ Str:D && %who<call-id>.chars
					?? ('call-id' => %who<call-id>)
					!! ()),
			),
		);
	}

	#|( Record the answer of a child that finished with nobody waiting on
	    it — which, once a question can hand a C<task> call back early, is
	    an ordinary way for a delegation to end rather than an edge.

	    Without this the child's slot would be released on draining and its
	    answer would go with it: the C<task_wait> the parent was told to
	    make would find no such agent, and the only record of what a child
	    did would depend on somebody having happened to be waiting. Called
	    B<before> the release, so the cache is filled before the entry it
	    is derived from disappears. )
	method !record-uncollected(
		Str:D $agent-id, LLM::Agent::Run:D $child,
		--> Nil
	) {
		# A run that drained without a result is not a thing LLM::Agent::Run
		# produces, but reading `.result.result` on one would throw on the
		# drain thread, which is nobody's idea of a good place for it.
		return if $child.result.status ~~ Planned;

		# A CALL THAT IS WAITING GETS TO WRITE IT, and this defers to it
		# rather than racing it. Both would produce the same envelope and
		# the once-guard would drop one of them, but which one wins decides
		# WHEN it is written: a waiting call writes it before it answers,
		# so the record is in the transcript by the time the model sees
		# the result, while this thread could get there a moment later.
		#
		# The deferral is safe because the call being deferred to always
		# writes it. Not because it always settles terminally — it does
		# not: the poll reads the result before the question table, so a
		# child that settles between those two reads hands its call back
		# interim and leaves this one deferring to a wait that has already
		# decided not to settle. What closes that window is the other end
		# of the contract, in C<!await-child>'s LEAVE: a call that comes
		# out of a park any way at all re-reads the child's result and
		# writes the terminal itself if one is owed. Whichever of the two
		# gets there, C<!record-terminal> makes it exactly once.
		my %entry = $!lock.protect: {
			(%!children{$agent-id}:exists
				&& !((%!children{$agent-id}<parked> // 0) > 0))
				?? child-snapshot(%!children{$agent-id})
				!! %();
		};
		return unless %entry.elems;

		self!write-terminal(
			$agent-id,
			self!child-answer($agent-id, %entry<agent-type>, $child),
			%entry<parent>, %entry<emit>,
		);
		Nil;
	}

	#|( The poll a waiting call sits in, and the three ways it comes out:
	    C<settled> (the child has a result), C<interrupt> (a question needs
	    the parent, and this call is released to carry it) or
	    C<unstoppable> (asked to stop, and did not).

	    The ordinary case waits for the child for as long as it takes — the
	    C<task> call IS the child's runtime, and bounding that would be
	    this layer inventing a deadline the loop already owns one of.

	    The first exception is a child that has been ASKED to stop. A
	    cancelled run keeps its result promptly by contract (it does not
	    wait for a detached tool batch), so one still Planned this long
	    after being told is one that waiting longer will not settle — and a
	    task call that hangs for ever on it is strictly worse than a call
	    that says so. See C<!unstoppable-result>.

	    The second is a question, and it is checked B<before> the stop
	    check and B<after> the result: a child that has already answered is
	    settled rather than interrupted, and a parent that is needed
	    somewhere else is released as soon as it is needed.

	    A bare timer rather than an anyof over the child's result: each
	    anyof pass registers a continuation on that result which the
	    runtime keeps until it settles, so a child that runs for an hour
	    accumulated an hour's worth of them — twenty a second — on the one
	    promise nothing else was going to clear. The result is a state this
	    loop reads, so waiting on it buys nothing but a CANCEL-POLL of
	    latency it already accepts for the stop check. )
	method !park-on-child(
		LLM::Agent::Run:D $child, Str:D $agent-id, $parent,
		--> Str:D
	) {
		my Instant $give-up;
		loop {
			last if $child.result.status !~~ Planned;
			return 'interrupt' if self!interrupt-pending;

			if self!stop-requested($agent-id, $parent) {
				$give-up //= now + $!cancel-grace;
				last if now > $give-up;
			}

			await Promise.in(CANCEL-POLL);
		}

		$child.result.status ~~ Planned ?? 'unstoppable' !! 'settled';
	}

	#|( Whether a waiting call should hand itself back now: B<any> open
	    question, from any child, whether or not it has been delivered yet.

	    The blunt predicate is the correct one, and the narrower ones are
	    all deadlocks. An UNDELIVERED question obviously needs the parent.
	    A question already delivered and not yet answered still needs it —
	    an agent blocked on an answer stays blocked, and a call that parked
	    after the delivery would be waiting for a child that cannot make
	    progress until the parent it is holding gets around to answering.
	    That is the deadlock the whole channel exists to avoid, and it does
	    not care which child asked or which child is being waited for.

	    The cost is that a parent with an unanswered question cannot wait
	    for anything at all: every C<task> and C<task_wait> call comes
	    straight back with an interim result until the table is empty.
	    That is the intended trade. Clearing the questions is cheap, the
	    interim result says exactly how, and an agent left blocked while
	    its parent waits on something else is how a delegation tree stops
	    dead.

	    It cannot spin: a call that comes back does not park again, and the
	    text it comes back with names the tool that empties the table. )
	method !interrupt-pending(--> Bool:D) {
		$!lock.protect: { so %!questions.elems };
	}

	#|( The answer a released call gives: the child is still running, here
	    is what it (or another agent) wants to know, and here is how to get
	    back to it.

	    Not an error. Nothing failed — a delegation that has to ask
	    something is a delegation working exactly as intended — and an
	    C<is_error> result would teach a model to treat a question as a
	    problem with the tool. It starts C<STATUS: interim> so that the one
	    thing a model must not do with it — treat it as the child's answer
	    — is refused by the first four words. )
	method !interim-result(
		Str:D $id, Str:D $agent-id, Str:D $type-name, &emit,
		--> Hash:D
	) {
		my %wave = self!claim-questions($agent-id);

		# One envelope per question this result DELIVERS, and none for the
		# ones it merely lists again: the transcript records the moment a
		# question reached the parent, which happens once.
		for %wave<delivered>.list -> %question {
			self!append-envelope('subagent-question', %(
				agent-id  => %question<agent-id>,
				token     => %question<token>,
				'call-id' => $id,
				message   => excerpt(%question<message>, SETTLE-EXCERPT),
				schema    => %question<schema>,
			), &emit);
		}

		%(
			role         => 'tool',
			tool_call_id => $id,
			content      => self!interim-content($agent-id, $type-name, %wave),
			is_error     => False,
		);
	}

	#|( What this wave of one call delivers, and what it merely mentions.

	    A question is delivered B<in full exactly once>, and this is the
	    critical section that decides who does it: the asking child's own
	    waiting call if it has one, and otherwise whichever other waiting
	    call gets here first. That second case is not an edge — a child
	    whose call has already come back with an interim has nobody parked
	    on it, and a question it asks afterwards would otherwise be pending
	    for ever while every other wait was interrupted by it on every
	    poll.

	    Everything still open and not delivered here comes back as a
	    reminder line, so a parent that lost track has the whole picture in
	    front of it on every interim result. )
	method !claim-questions(Str:D $agent-id --> Hash:D) {
		$!lock.protect: {
			my @delivered;

			with %!questions{$agent-id} {
				if $_<status> eq 'pending' {
					$_<status> = 'delivered';
					@delivered.push: question-data($_);
				}
			}

			# The orphans: pending questions from children nobody is
			# waiting on. Sorted, so a wave that delivers two of them
			# delivers them in the same order twice.
			for %!questions.keys.sort -> $other {
				next if $other eq $agent-id;
				my $question = %!questions{$other};
				next unless $question<status> eq 'pending';
				next if %!children{$other}:exists
					&& (%!children{$other}<parked> // 0) > 0;

				$question<status> = 'delivered';
				@delivered.push: question-data($question);
			}

			my $claimed = @delivered.map({ $_<agent-id> }).Set;
			my @open = %!questions.values
				.grep({ !$claimed{$_<agent-id>} })
				.sort({ $_<asked-at> })
				.map({ question-data($_) })
				.List;

			%( delivered => @delivered.List, open => @open );
		};
	}

	# The words of an interim result: what happened, the questions it
	# carries, what is still open, and what to do about all of it.
	method !interim-content(
		Str:D $agent-id, Str:D $type-name, %wave,
		--> Str:D
	) {
		my $own = %wave<delivered>.list.first({ $_<agent-id> eq $agent-id });
		my @parts;

		@parts.push: $own.defined
			?? "STATUS: interim — the $type-name agent ($agent-id) is still "
				~ 'running, and it has asked you a question. It is waiting '
				~ 'for your answer and will not go any further without one.'
			!! "STATUS: interim — the $type-name agent ($agent-id) is still "
				~ 'running. This call came back early so that you can answer '
				~ 'a question from another agent; nothing of what '
				~ "$agent-id is doing was lost or interrupted.";

		@parts.push: self!question-block($_) for %wave<delivered>.list;

		if %wave<open>.list.elems {
			@parts.push: "Questions still waiting for an answer:\n"
				~ %wave<open>.list.map({
					'- ' ~ $_<agent-id> ~ ': '
						~ one-line($_<message>, QUESTION-LINE);
				}).join("\n");
		}

		@parts.push: self!interim-instructions($agent-id, %wave);
		@parts.join("\n\n");
	}

	# One delivered question, in full: who is asking, what they asked, and
	# the shape the answer has to take when they asked for one.
	method !question-block(%question --> Str:D) {
		my Str $block = "QUESTION from {%question<agent-id>}:\n"
			~ excerpt(%question<message>, SETTLE-EXCERPT);

		my Str $fields = self!question-fields-block(%question);
		$fields.chars ?? $block ~ "\n\n" ~ $fields !! $block;
	}

	#|( The shape a form question's answer has to take, or the empty string
	    for one that asked in prose.

	    Shared by the interim wave and the background turn rather than
	    written twice: a model shown one list here and a differently-worded
	    one there would be learning that the two are different questions. )
	method !question-fields-block(%question --> Str:D) {
		my @fields = schema-fields(%question<schema>);
		return '' unless @fields.elems;

		"It asked for named fields, so answer it with 'fields':\n"
			~ @fields.map({
				'- ' ~ $_<name>
					~ ' ('
					~ ($_<type>.chars ?? $_<type> !! 'value')
					~ ($_<required> ?? ', required)' !! ')')
					~ ($_<description>.chars
						?? ': ' ~ one-line($_<description>, QUESTION-LINE)
						!! '');
			}).join("\n");
	}

	# What to do next, which is the half of an interim result that decides
	# whether the delegation recovers or stalls.
	method !interim-instructions(Str:D $agent-id, %wave --> Str:D) {
		my @asking = (
			|%wave<delivered>.list.map({ $_<agent-id> }),
			|%wave<open>.list.map({ $_<agent-id> }),
		).unique.List;

		# The example is the shape the FIRST open question actually asked
		# for: a model copies what it is shown, and showing it prose for a
		# question that wants fields is teaching it the refusal it is
		# about to get.
		my $named = (|%wave<delivered>.list, |%wave<open>.list)
			.first({ $_<agent-id> eq (@asking.head // '') });
		my Bool $form = $named.defined && ?schema-fields($named<schema>).elems;

		my Str $answering = @asking.elems
			?? "Answer with '{ANSWER-TOOL}': "
				~ '{ "agent-id": "' ~ @asking.head ~ '", '
				~ ($form
					?? '"fields": { ... } } — the fields it listed above; or '
					!! '"answer": "<your answer, in full>" } — or ')
				~ '"decline": true with a "reason" when it cannot be '
				~ "answered.\n"
				~ 'Answer it yourself if you can: you have the context the '
				~ 'agent has not. If you cannot — it needs a decision only '
				~ 'the user can make — ask the user yourself, with the whole '
				~ 'of the context, and pass what they say back with '
				~ "'{ANSWER-TOOL}'. An agent left waiting is an agent doing "
				~ 'nothing.'
			!! '';

		my Str $collecting = self!background-mode
			?? "This call has not answered $agent-id, and what it finally "
				~ 'says will arrive here on its own as an automated '
				~ "[background event] turn. Use '{WAIT-TOOL}' ("
				~ '{ "agent-id": "' ~ $agent-id ~ '" })'
				~ ' only if you cannot go on without it.'
			!! "Collect what $agent-id finally says with "
				~ "'{WAIT-TOOL}': " ~ '{ "agent-id": "' ~ $agent-id ~ '" }'
				~ ' — this call has not answered it, and nothing else will.';

		($answering.chars ?? ($answering, $collecting) !! ($collecting,))
			.join("\n");
	}

	#|( Record a child's terminal answer, and say whether this call is the
	    one that has to write it down. True exactly once per child.

	    The guard is in B<two> places on purpose, because neither is enough
	    on its own. The cache is scoped to the parent run, so it cannot
	    speak for a child that outlived one; the flag on the child's entry
	    disappears when the child drains, which can happen between a
	    result being kept and this line reading it. A second wait can only
	    exist while the child is still owned — which is exactly when the
	    flag is there — and a second wait within one run is caught by the
	    cache whether the child still exists or not. )
	method !record-terminal(
		Str:D $agent-id, Str:D $content, Bool:D $is-error,
		--> Bool:D
	) {
		$!lock.protect: {
			my Bool $already = (%!settled{$agent-id}:exists)
				|| (%!children{$agent-id}:exists
					&& ?(%!children{$agent-id}<settled-recorded> // False));

			%!settled{$agent-id} = %( :$content, is_error => $is-error );
			%!children{$agent-id}<settled-recorded> = True
				if %!children{$agent-id}:exists;

			!$already;
		};
	}

	# Answer any question from this child with `cancel`, because the child
	# is past the point of being told anything. Keeping the vow is what
	# unblocks the host thread that asked it.
	method !sweep-questions(Str:D $agent-id --> Nil) {
		my $vow = $!lock.protect: {
			with %!questions{$agent-id} {
				my $taken = $_<vow>;
				%!questions{$agent-id}:delete;
				$taken;
			}
			else {
				Nil;
			}
		};

		try $vow.keep(%( action => 'cancel' )) with $vow;
		Nil;
	}

	# The child's single tap, closed once and from wherever gets there
	# first: the terminal wait, or the release that follows draining.
	method !close-child-tap(Str:D $agent-id --> Nil) {
		my $tap = $!lock.protect: {
			with %!children{$agent-id} {
				my $taken = $_<tap>;
				$_<tap> = Nil;
				$taken;
			}
			else {
				Nil;
			}
		};

		try $tap.close with $tap;
		Nil;
	}

	# One waiting call, counted on the child it is waiting on. What tells
	# an interim wave which pending questions have nobody to deliver them.
	method !mark-parked(Str:D $agent-id, Int:D $delta --> Nil) {
		$!lock.protect: {
			with %!children{$agent-id} {
				my Int $count = ($_<parked> // 0) + $delta;
				$_<parked> = $count > 0 ?? $count !! 0;
			}
		};
		Nil;
	}

	# A host callback, shielded. A host that throws out of one of these has
	# a bug; a delegation that failed because of it would have two.
	method !fire-child-callback(&callback, %info --> Nil) {
		return unless &callback.defined;
		try &callback(%info);
		Nil;
	}

	# The emitter a child was spawned with, or a refusing stand-in for a
	# child that has none (or has gone). Everything this composer says
	# about a child goes through one of these — see !emitter-for.
	method !child-emitter(Str:D $agent-id --> Callable:D) {
		my $emit = $!lock.protect: {
			with %!children{$agent-id} { $_<emit> } else { Nil }
		};
		($emit ~~ Callable:D) ?? $emit !! -> $ { False };
	}

	# The collected-results cache belongs to one parent run: the previous
	# run's is of no further interest, and a table that grew an entry per
	# delegation for the life of a host would be a slow leak. Called once
	# per batch, with the run that batch belongs to.
	method !scope-settled($parent --> Nil) {
		my Str $scope = $parent.defined ?? $parent.id !! '';
		$!lock.protect: {
			unless $!settled-scope.defined && $!settled-scope eq $scope {
				%!settled = ();
				# The framing table goes with it: an identity is only ever
				# read to build a turn for the run that asked for the
				# child, and a table that kept one entry per delegation
				# for the life of a host would be the same slow leak.
				%!identities = ();
				$!settled-scope = $scope;
			}
		};
		Nil;
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
		Str:D $agent-id, Str:D $agent-type, $label, $call-id, $event, &emit,
		--> Nil
	) {
		return unless $event ~~ LLM::Agent::Event:D;

		&emit(LLM::Agent::Event::Subagent.new(
			:$agent-id, :$agent-type, :$label, :$call-id,
			inner => $event.to-hash,
		));
		Nil;
	}

	#|( One settled child's bill, added to the parent run's. The whole of
	    "a parent's budget caps its subtree", and it is three lines because
	    L<LLM::Agent::Loop> owns the accumulators and the caps; this only
	    knows which run to bill.

	    Shielded and duck-typed, like everything else this composer says
	    about a child: a loop from before the seam existed, a stand-in in
	    a test, or an accumulator that has moved on to another run all
	    answer the same way — nothing happens, and the C<task> call that
	    was about to return still returns. A child nobody was counting
	    (no C<spent> key at all) is not billed for zero, it is not billed. )
	method !absorb-child-spend($parent, $spent --> Nil) {
		return unless $spent ~~ Associative && $spent.elems;

		my $loop = self!resolve-loop;
		return unless $loop.defined && $loop.can('absorb-spend');

		try $loop.absorb-spend(
			$spent.Hash,
			|($parent.defined ?? (run-id => $parent.id) !! ()),
		);
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

		# AND ON ANY TERMINAL, not just a cancel. A parent that finished
		# without collecting a child it started — because a question came
		# back as an interim result and the model answered the user
		# instead of calling task_wait — leaves a child running for a
		# conversation nobody is having any more, and (worse) a host
		# thread blocked for ever on a question the parent will never see.
		# Cancelling here is not a policy decision about long-running
		# children: nothing can reach them once their run is over.
		#
		# The empty case is the common one and is deliberately a no-op:
		# every child settled and drained before the run ended, there is
		# nothing to cancel, and this hook never touches a thing.
		$run.result.then({
			my Bool $anything = $!lock.protect: {
				?(%!children.elems || %!questions.elems);
			};
			try self.cancel-children if $anything;
			True;
		});
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

		# Off the bus, and COLLECTED: this call's own result is where the
		# model hears about it, and the run must not go on parking for a
		# child that was stopped.
		self!bus-settle($agent-id, :collected, :&emit);

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
			~ "and did not, so this call was abandoned after {$!cancel-grace} "
			~ 'seconds. Whatever it had done, or is still doing, is unknown.';

		# Off the bus, COLLECTED, for the reason a cancelled child is: the
		# model is being told here. A child that ignores its own
		# cancellation must not also be able to hold a run open for ever
		# while it does.
		self!bus-settle($agent-id, :collected, :&emit);

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

	method !answer-declaration(--> Hash:D) {
		{
			type     => 'function',
			function => {
				name        => ANSWER-TOOL,
				description => self!answer-description,
				parameters  => {
					type       => 'object',
					properties => {
						'agent-id' => {
							type        => 'string',
							description => 'The agent that asked, exactly as '
								~ 'the question named it.',
						},
						answer => {
							type        => 'string',
							description => 'The answer, in full and in your '
								~ 'own words. The agent sees this and '
								~ 'nothing else of your conversation, so it '
								~ 'has to carry every fact it needs.',
						},
						fields => {
							type        => 'object',
							description => 'For a question that asked for '
								~ 'named fields: an object with those fields '
								~ 'in it. Use this instead of answer when '
								~ 'the question listed fields.',
						},
						decline => {
							type        => 'boolean',
							description => 'True when the question cannot be '
								~ 'answered at all. The agent is told, and '
								~ 'decides for itself what to do.',
						},
						reason => {
							type        => 'string',
							description => 'Why it was declined, for the '
								~ 'agent to act on.',
						},
					},
					required => ('agent-id',),
				},
			},
		};
	}

	method !wait-declaration(--> Hash:D) {
		{
			type     => 'function',
			function => {
				name        => WAIT-TOOL,
				description => self!wait-description,
				parameters  => {
					type       => 'object',
					properties => {
						'agent-id' => {
							type        => 'string',
							description => 'The agent to wait for, by the id '
								~ 'its result was given under.',
						},
					},
					required => ('agent-id',),
				},
			},
		};
	}

	method !answer-description(--> Str:D) {
		return self!background-answer-description if self!background-mode;

		"Answer a question an agent you started has asked you.\n"
			~ "An agent that finds its brief incomplete, contradictory or "
			~ "impossible asks YOU rather than the user: its question comes "
			~ "back as the interim result of the '{TASK-TOOL}' call that "
			~ "started it, and the agent is stopped until you answer.\n"
			~ 'Answer it yourself when you can — you have the context it has '
			~ 'not. When you genuinely cannot, ask the user, give them the '
			~ 'whole context, and pass their answer on with this tool; when '
			~ 'it cannot be answered at all, decline with a reason and the '
			~ "agent will decide what to do.\n"
			~ 'Answering does not collect the agent: it carries on from '
			~ "where it stopped, and you collect it with '{WAIT-TOOL}'.";
	}

	method !background-answer-description(--> Str:D) {
		"Answer a question an agent you started has asked you.\n"
			~ 'An agent that finds its brief incomplete, contradictory or '
			~ 'impossible asks YOU rather than the user: its question '
			~ 'arrives as an automated turn marked [background event], and '
			~ "the agent is stopped until you answer.\n"
			~ 'Answer it yourself when you can — you have the context it has '
			~ 'not. When you genuinely cannot, ask the user, give them the '
			~ 'whole context, and pass their answer on with this tool; when '
			~ 'it cannot be answered at all, decline with a reason and the '
			~ "agent will decide what to do.\n"
			~ 'Answering does not collect the agent, and you do not have to: '
			~ 'it carries on from where it stopped, and what it finally says '
			~ 'arrives as another [background event] turn.';
	}

	method !wait-description(--> Str:D) {
		return self!background-wait-description if self!background-mode;

		"Wait for an agent you started and collect what it finally says.\n"
			~ "Use it for an agent whose '{TASK-TOOL}' call came back with an "
			~ 'interim result — one that says the agent is still running — '
			~ "which happens when it asked a question, or when another "
			~ "agent did.\n"
			~ 'It answers with exactly what the original call would have: the '
			~ "agent's final message, or the reason it produced none. "
			~ 'Collecting an agent twice is harmless and answers the same '
			~ 'thing twice.';
	}

	method !background-wait-description(--> Str:D) {
		"The synchronous join: stop and wait here for an agent you started, "
			~ "and answer with what it finally says.\n"
			~ 'You rarely need it. An agent\'s answer arrives on its own, as '
			~ 'an automated turn marked [background event], and the '
			~ 'conversation will not end while one is still working — so use '
			~ 'this ONLY when the very next thing you have to do depends on '
			~ 'that agent, and otherwise let the notification come to '
			~ "you.\n"
			~ 'It answers with the agent\'s final message, or the reason it '
			~ 'produced none. Waiting for an agent that has already answered '
			~ 'is harmless and hands back the same words.';
	}

	method !task-description(--> Str:D) {
		return self!background-task-description if self!background-mode;

		"Delegate one self-contained piece of work to a subagent and wait "
			~ "for its answer.\n"
			~ "The subagent runs its own tool loop in a conversation of its "
			~ "own: it sees NOTHING of this one, and only its final message "
			~ "comes back — as the result of this call.\n"
			~ "Independent pieces of work run IN PARALLEL when you make "
			~ "several task calls in the SAME turn — one call per task, all "
			~ "in one message. Calls made in later turns wait for the "
			~ "earlier results, so batching independent work is how agents "
			~ "run concurrently.\n"
			~ "A brief is worth its length — write it in full; when several "
			~ "long briefs are queued, splitting the spawns across turns is "
			~ "fine.\n"
			~ "An agent that finds its brief incomplete or contradictory ASKS "
			~ "YOU rather than guessing, and its question comes back as an "
			~ "INTERIM result of this call: the agent is still running, and "
			~ "is stopped until you answer it with '{ANSWER-TOOL}'. An "
			~ "interim result is never the answer to the task — collect that "
			~ "with '{WAIT-TOOL}' once you have answered.\n"
			~ "Use it for work that is worth a whole conversation of its "
			~ "own; do small things yourself.\n"
			~ "The agents available are:\n"
			~ self!catalogue-block;
	}

	method !background-task-description(--> Str:D) {
		"Delegate one self-contained piece of work to a subagent. Starts "
			~ 'the agent and returns IMMEDIATELY: the result of this call '
			~ "is an acknowledgement, never the agent's answer.\n"
			~ 'The subagent runs its own tool loop in a conversation of its '
			~ 'own: it sees NOTHING of this one, and only its final message '
			~ 'comes back — later, as an automated turn marked [background '
			~ "event].\n"
			~ 'Delegate, then keep working. The conversation will not end '
			~ 'while an agent is still working, so it is safe to finish your '
			~ "turn; only call '{WAIT-TOOL}' when you cannot proceed without "
			~ "the answer.\n"
			~ 'Independent pieces of work run IN PARALLEL: one task call per '
			~ 'piece of work, and there is no reason to wait for one before '
			~ "starting the next.\n"
			~ 'A brief is worth its length — write it in full; when several '
			~ 'long briefs are queued, splitting the spawns across turns is '
			~ "fine.\n"
			~ 'An agent that finds its brief incomplete or contradictory ASKS '
			~ 'YOU rather than guessing, and its question arrives as a '
			~ '[background event] turn of its own: the agent is stopped until '
			~ "you answer it with '{ANSWER-TOOL}'.\n"
			~ 'Use it for work that is worth a whole conversation of its own; '
			~ "do small things yourself.\n"
			~ "The agents available are:\n"
			~ self!catalogue-block;
	}

	method !catalogue-block(--> Str:D) {
		@!types.map({ '- ' ~ $_<name> ~ ': ' ~ $_<description> }).join("\n");
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

# $text on one line, cut to $limit characters. For a reminder line beside
# something whose full text was delivered elsewhere — a question already
# carried in full, a key that is really a fragment of a clipped brief.
my sub one-line(Str:D $text, Int:D $limit --> Str:D) {
	my Str $flat = $text.subst(/\s+/, ' ', :g).trim;
	$flat.chars > $limit
		?? $flat.substr(0, $limit) ~ '...'
		!! $flat;
}

# One offending argument key, fit to be quoted inside a one-line refusal.
# Whitespace is flattened and a long key is cut, because the keys this is
# for are not really keys: they are what a clipped brief turned into, and
# an unmodified one can carry newlines and a paragraph of the prompt. The
# model needs to recognise it, not read it back.
my constant KEY-LABEL = 80;
my sub argument-key-label(Str:D $key --> Str:D) {
	one-line($key, KEY-LABEL);
}

# A parked question as plain data: everything about it except the vow,
# which is a handle to answer with and not a thing to render.
my sub question-data($question --> Hash:D) {
	%(
		agent-id   => $question<agent-id>,
		token      => $question<token>,
		message    => $question<message>,
		schema     => ($question<schema> ~~ Associative
			?? $question<schema>.Hash !! %()),
		status     => $question<status>,
		'asked-at' => $question<asked-at>,
	);
}

# What one waiting call needs to know about the child it is waiting on,
# read out of the table in one critical section so nothing downstream
# reads a live entry without the lock.
my sub child-snapshot($child --> Hash:D) {
	%(
		agent-id     => $child<agent-id>,
		agent-type   => $child<agent-type>,
		label        => $child<label>,
		run          => $child<run>,
		published    => $child<published>,
		parent       => $child<parent>,
		emit         => ($child<emit> ~~ Callable:D
			?? $child<emit> !! -> $ { False }),
	);
}

# The fields a requested schema asks for, as plain data, sorted by name so
# that one question renders the same way twice. An absent or unreadable
# schema describes no fields, which is what makes a question FREE-FORM.
my sub schema-fields($schema --> List:D) {
	return () unless $schema ~~ Associative;
	my $properties = $schema<properties>;
	return () unless $properties ~~ Associative;

	my $required = $schema<required>;
	my $names = ($required ~~ Positional
		?? $required.list.grep({ $_ ~~ Str:D }).map(*.Str)
		!! ()).Set;

	$properties.keys.map(*.Str).sort.map(-> $name {
		my $spec = $properties{$name};
		%(
			name        => $name,
			type        => ($spec ~~ Associative && $spec<type> ~~ Str:D
				?? $spec<type>.Str !! ''),
			description => ($spec ~~ Associative
				&& $spec<description> ~~ Str:D
				?? $spec<description>.Str !! ''),
			required    => ?$names{$name},
		);
	}).List;
}

# Just the names a form question REQUIRES, in the same order.
my sub required-fields($schema --> List:D) {
	schema-fields($schema).grep({ $_<required> }).map({ $_<name> }).List;
}

# Whether an answer really gave a field. A key that is there with an empty
# string in it is a field the model skipped, not a field it answered, and
# a required one is required.
my sub field-given($fields, Str:D $name --> Bool:D) {
	return False unless $fields ~~ Associative;
	return False unless $fields{$name}:exists;
	my $value = $fields{$name};
	return False without $value;
	$value ~~ Str ?? ?$value.trim.chars !! True;
}

# A JSON-ish flag as a Bool. `?$value` is not enough: a model that wrote
# "false" as a STRING would have written something true, which for a
# decline is the difference between an agent told no and an agent told
# nothing.
my sub json-flag($value --> Bool:D) {
	return False without $value;
	return ?$value if $value ~~ Bool;
	return ?$value if $value ~~ Numeric;
	so $value.Str.trim.lc eq any('true', 'yes', '1');
}

# An answer's content, bounded for the transcript's copy of it. The full
# text went to the child; this is the audit trail, and an audit trail that
# stores a 40KB answer is one nobody greps.
my sub excerpt-values(%content, Int:D $limit --> Hash:D) {
	%content.keys.map(-> $key {
		$key => (%content{$key} ~~ Str:D
			?? excerpt(%content{$key}, $limit)
			!! %content{$key});
	}).Hash;
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
