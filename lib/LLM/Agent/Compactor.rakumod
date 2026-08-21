=begin pod

=head1 NAME

LLM::Agent::Compactor - summarize the middle of a conversation before it
outgrows the context window

=head1 SYNOPSIS

=begin code :lang<raku>

use LLM::Agent::Compactor;
use LLM::Agent::TokenCount;

my $counter = LLM::Agent::TokenCount::Usage.new;

my $compactor = LLM::Agent::Compactor.new(
    backend        => @backends[0],   # a cheap model is a fine summarizer
    counter        => $counter,       # the SAME instance the loop uses
    context-budget => 128_000,
);

# The loop does this for you; this is what it does.
if $compactor.needs-compaction(@conversation) {
    my %result = $compactor.compact(@conversation, cancelled => { $run.is-cancelled });

    @conversation = %result<messages>.list;

    note "compacted {%result<dropped>} messages, "
       ~ "{%result<tokens-before>} -> {%result<tokens-after>} tokens"
       ~ (%result<fallback> ?? ' (HARD TRIM — the summarizer was unreachable)' !! '');
}

=end code

=head1 DESCRIPTION

A tool-using agent fills a context window fast: one C<fs_read> of a
600-line file is most of a small model's budget, and a round of six of
them is most of a large one's. The choices are to stop, to truncate
blindly, or to trade the middle of the conversation for a summary of it.
This is the third.

The shape is fixed and deliberately boring:

=begin code :lang<text>

    [ system prompt + anything sticky ]   kept, always, wherever it was
    [ ...the middle... ]                  replaced by ONE summary message
    [ the last keep-recent turns ]        kept verbatim

=end code

Nothing about that shape is negotiable at runtime, because
L<LLM::Agent::Session> has to be able to reproduce it exactly from the
transcript months later. C<compact> and session replay implement the same
transformation, and the C<cut-index> in the result is what ties them
together.

=head2 The cut, and why it moves

The recent window starts C<keep-recent> messages from the end — and is
then B<extended backwards> while its first message is a C<tool> result,
so an assistant turn that asked for three tools and the three results
that answered it are never separated. Splitting them produces a
conversation that most providers reject outright ("tool_call_id did not
match a preceding tool_calls"), so this is a correctness rule and not a
nicety.

Everything before the cut that is not B<sticky> (C<sticky>, C<sysprompt>
or C<depth> — C<Message.is-sticky>) is what gets summarized. Sticky
messages stay exactly where they were: an agent's own instructions are
the last thing that should be compressed into "the user wanted some
refactoring".

If there is nothing between the sticky prefix and the recent window, the
compaction is a B<no-op> — C<dropped> is 0, no backend call is made, and
the conversation comes back unchanged. That happens when C<keep-recent>
is bigger than the conversation, and it means the budget is too small
for the window rather than that anything went wrong.

=head2 Observation aging: the cheap first resort

Summarizing costs a request, a model and a wait. Most of what fills an
agent's context does not need any of them: it is B<old tool results>. A
600-line C<fs_read> from twenty rounds ago is bulk the model has already
extracted what it wanted from, and the odds it goes back to re-read the
raw bytes are close to nil — it would re-run the call instead, which is
cheaper for it and cheaper for everybody.

So with C<< age-observations => True >>, a compaction pass tries B<elision>
before it tries summarization: the C<content> of a fat C<tool> message is
replaced, B<in place>, with a deterministic one-line stub —

=begin code :lang<text>

    [elided by the harness: 41062-char fs_read result; re-run the call if you need it again]

=end code

— and B<nothing else about the message changes>. Same position, same
C<role>, same C<tool_call_id>. That is the whole reason this is safe:
there is no pair alignment to get wrong, no assistant turn left holding
C<tool_calls> that nothing answers, and no provider with an opinion about
it. Compare dropping the turn, which is all of those risks at once.

=head3 The two ways a pass gets entered

=item B<A reclaimable-batch epoch.> C<needs-compaction> answers True —
below the trigger — as soon as the eligible pool reaches
C<age-reclaim-min> characters. That pass is B<elision only>: it never
summarizes, never calls a backend, and never drops a message. One epoch
reclaims one batch, and the pool is empty afterwards, so the next epoch is
a long way off.

=item B<The compaction trigger.> A conversation over the trigger is aged
B<first>, and then recounted. If that was enough — the conversation is
back under the trigger, or under the C<:$target> a caller named — the pass
ends there, with no backend call and no summary message. If it was not,
the summarizer runs as it always did, over the B<stubbed> middle (so one
enormous C<fs_read> no longer dominates the transcript it is asked to
summarize, and C<tool-result-cap> rarely has anything left to bite on).

=head3 Why epochs, and not "a bit every round"

Providers cache the prompt prefix, and a cache hit is an order of
magnitude cheaper than a miss. B<Any> change to the conversation below the
tail invalidates that prefix, so eliding one result per round would pay a
full cache miss every round to reclaim a few thousand characters. A floor
turns that into one miss per batch: the pass waits until there is
C<age-reclaim-min> worth of dead weight and takes it all at once. Elision
epochs are compaction epochs, and an elision-only epoch is strictly the
cheapest kind — no summarizer request at all.

=head3 What is eligible, and what is protected

A message is eligible only if it is a C<tool> result in the B<middle
region> — after the sticky prefix, before the recent window, the exact
same cut the summarizer works from — and then:

=item its content is longer than C<age-min-chars>. Stubbing something
small saves nothing and costs a cache epoch.

=item at least C<age-reclaim-min> characters of conversation content come
B<after> it (the B<trailing grace>). The recent window is positional and
one tool-heavy round can push eight messages, so "recent" is measured in
B<content> instead: the model has to have demonstrably moved a whole
epoch's worth of work past a result before its raw bytes are taken away.

=item it is not already a stub, and it is not the B<newest> result of a
call identity that appears more than once.

That last rule is the loop breaker. Elision is a bet, and when it loses
the model re-runs the call — which is fine once and pathological in a
cycle (stub it, it re-reads, the fresh copy ages out, it re-reads again),
because every cycle pays for a full tool result B<and> a cache epoch. So
call identity — the tool's name plus its canonicalised arguments, joined
back through C<tool_call_id> to the assistant turn that asked — is
counted: where the same call appears twice, the B<newest> answer is
protected from then on, permanently, and every B<older> copy of it becomes
eligible regardless of size or grace distance (a stale duplicate of a
result that exists in full later in the conversation is pure dead weight).
A result whose assistant turn is not in the conversation any more — an
earlier compaction summarized it away — simply has no identity and gets
the ordinary rules.

=head3 What the caller gets back

C<< %result<elisions> >> is a list of C<< { index, stub } >>, where
C<index> is a position in the B<input> array. L<LLM::Agent::Loop> turns
those indices into envelope ids and writes one C<elision> line, exactly as
it turns C<cut-index> into a C<replaces-through-id>; L<LLM::Agent::Session>
replays them by id. The stub text is a pure function of the content length
and the tool name, so two runs of the same conversation produce the same
bytes.

Elision changes the conversation, so the usage counter's calibration
digest stops matching and the next billed round recalibrates — the same
path a summarizing compaction has always taken. Nothing new is needed for
it.

C<age-observations> defaults to B<False>: with it off, every number and
every byte of this class's behaviour is what it was before elision
existed.

=head2 What the summarizer is asked for

One blocking C<chat-completion> against C<$.backend>, with a fixed
instruction: goals, decisions, files and commands, and what is still
unresolved — in that order, no preamble, no invented facts, exact
identifiers over paraphrase. The transcript it summarizes is the middle
rendered as plain text, with every tool result — and the arguments of
every tool B<call> — truncated to C<tool-result-cap> characters. Both
truncations leave a marker saying how many characters went, so the
summarizer reads a transcript it can tell was cut rather than one that
looks whole and stops mid-word.

That cap applies B<only to the summarizer's input>. It is there because a
compaction triggered by one enormous C<fs_read> would otherwise send that
same enormous read to the summarizer and fail for exactly the reason it
was invoked. What the model was told during the real conversation is not
altered.

C<$.backend> is a separate attribute rather than "the loop's first
backend" because summarization is a different job: it is not
latency-sensitive, it does not need tools, and a small cheap model does
it well. Pointing it at C<@backends[0]> is perfectly reasonable, and
pointing it somewhere cheaper is usually better.

=head2 A compaction has to prove it compacted

C<compact> does not accept a summary just because the model produced
one. After assembling the new conversation it counts it, and requires
C<< tokens-after < tokens-before >>. A model that answers a request for a
summary with something as long as the transcript has not compacted
anything, and taking it would mean the next round asks for a compaction
again over a conversation that has not moved — forever.

An B<elision-only> pass proves the same thing by construction: it is
returned only when the stubbed conversation is under the number the pass
was aiming at, and a pass with nothing eligible produces no elisions and
falls straight through to the summarizer. The floor is what keeps the
epoch path from spinning — a pass spends the pool, and C<needs-compaction>
answers False again until a new batch of dead observations has
accumulated.

A summary that fails that test gets B<one> retry, with the instruction
saying in as many words that the previous attempt was too long, and the
retry is accepted only if it is both smaller than the conversation B<and>
smaller than the first attempt. Otherwise it is the hard trim, which is
arithmetic and cannot fail to shrink anything.

(The retry tightens with words rather than with a completion cap on
purpose: L<LLM::Chat> keeps that limit on a backend's C<Settings>, which
this compactor normally shares with the loop that owns it — turning it
down here would turn it down for the conversation as well, from a thread
the conversation knows nothing about.)

=head2 When even a hard trim is not enough

There is a floor: the trim never eats into the recent window, so a
conversation whose sticky prefix plus recent window is B<itself> bigger
than the budget cannot be made to fit. One 400KB C<fs_read> in the last
turn does it.

Rather than hand back a conversation whose next request is guaranteed to
fail, C<compact> says so: C<< exhausted => True >> in the result. It is a
marker, not an exception — the C<messages> are still the best available
version, and L<LLM::Agent::Loop> still writes them to the session before
ending the run with C<RunFailed> and a C<reason> of C<context-exhausted>.
A no-op compaction over a conversation that is already past the B<budget>
(as opposed to merely past the trigger) is marked the same way, for the
same reason: there was nothing to summarize, so there is nothing left to
try.

=head2 When the summarizer fails

It will. The context is large, the call is a single one with no fallback
chain, and it happens at the least convenient moment. The policy:

=item The failure is classified with L<LLM::Chat::Retry>'s
C<classify-error>. An B<abort> bucket — 400, 401, 402, 403, 404 — means a
configuration or account problem that will not heal in eight seconds, so
it goes straight to the hard trim without burning a retry.

=item Anything else is retried, up to C<max-attempts> B<in total>
(default 3), with C<retry-backoff> waits served through
C<sleep-with-cancel> so a cancelled run does not sit out the last one.
There is one backend here, so C<retry-same> and C<advance> are the same
action; only the wait distinguishes them, and both get it.

=item A summarizer that succeeds but returns nothing is treated as a
failure of the C<response> class. An empty summary is worse than no
compaction: it silently deletes the middle of the conversation.

=item Still failing: B<hard trim>. The oldest non-sticky messages are
dropped — pair-aligned, so tool results never outlive the assistant turn
that asked for them — until the conversation fits in
C<target-ratio × context-budget>, and the result comes back with
C<< fallback => True >>.

The hard trim is the whole point of the design: B<the loop always makes
progress>. A compaction that could fail would turn an unreachable
summarizer into a run that can never take another turn, and an agent that
stops working because a summarizer is down is worse than an agent that
forgot what happened an hour ago.

The trim is bounded by the cut: it will not eat into the recent window,
even if that leaves the conversation above target. Trimming the last few
turns removes the very context the next turn needs, and a conversation
whose sticky prefix plus recent window does not fit the budget is a
configuration problem (C<keep-recent> too large, budget too small) that
silently discarding the user's last message would hide rather than fix.

C<fallback> is on the C<CompactionDone> event and in the transcript, so
"the model seems to have forgotten everything" is answerable after the
fact.

=head2 Compacting to somebody else's number

C<compact> normally aims at C<target> — C<target-ratio> of the budget —
and reports C<exhausted> against C<context-budget>. Both are this class's
own numbers, and both are wrong for one caller: L<LLM::Agent::Loop>'s
per-attempt preflight, which knows something this class does not. A
backend's usable room is its window B<minus> the tokens reserved for the
answer, B<minus> a safety margin, B<minus> the tool declarations the
request carries — and in a fallback chain it is the B<largest> such
number across the backends that are still worth trying.

C<< compact(@messages, :$target, :$counter) >> is how that number gets in.
C<:$target> overrides C<target> and C<:$counter> overrides C<$.counter>
for the one invocation. The override is required when the target came
from a backend whose tokenizer is not the compactor's normal tokenizer:
a number produced in one tokenizer's units must never be proved, trimmed
or reported in another's. The loop's override is also allowed to be a
complete-request adapter: it keeps that backend's runtime context and tools
attached while C<Compactor> supplies each candidate conversation. Four
things follow the pair through:

=item the B<hard trim> aims at it rather than at C<target>;

=item a B<summary> is accepted only if it gets under it — a summary that
shrank the conversation but left it too big for the backend that asked
is not an answer, and falling through to the trim that would have fitted
is;

=item C<exhausted> is judged against it rather than against
C<context-budget>, so "I did everything and it still will not fit" means
what the caller asked rather than what this class assumes.

=item every before/after, summary-acceptance and hard-trim count uses the
invocation counter, including the counts returned to the caller.

Without the overrides every one of those is exactly as it was.

=head2 The result

C<compact> returns a C<Map>:

=begin table

Key           | Meaning
==============|=================================================================
messages      | The new conversation. Hand it to the loop; hand it to the model.
summary       | The synthetic message's B<full content>, header line included.
dropped       | How many messages were replaced.
cut-index     | Index, in the INPUT array, of the last message replaced.
tokens-before | The counter's answer before.
tokens-after  | The counter's answer after.
fallback      | True when this was a hard trim rather than a summary.
exhausted     | True when even that could not make the conversation fit.
elisions      | The observations stubbed in place: C<< [ { index, stub }, ... ] >>.

=end table

C<elisions> is empty unless C<age-observations> is on, and its C<index>
values are positions in the B<input> array — see
L</Observation aging: the cheap first resort>. An B<elision-only> pass is
the one result that has C<< dropped => 0 >> and a C<messages> array that
is not the input: nothing was replaced, but some of it weighs less.

C<summary> is the whole content rather than just the model's prose so
that a transcript can store one string and replay it into a byte-identical
message. C<cut-index> is what a caller turns into a
C<replaces-through-id>; it is C<-1> for a no-op compaction.

The synthetic message is C<< role => 'user' >> (the role every provider
accepts arbitrary text in, including the ones that allow exactly one
system message) and is B<not> sticky, so a later compaction can fold it
into a newer summary. Summaries of summaries are how a very long session
stays finite.

=head2 The counter

C<$.counter> should be the B<same instance> the loop holds. It is the
loop's counter that has been calibrated against what the provider
actually billed; a fresh one would fall back to arithmetic at the exact
moment an accurate number matters most.

=head1 SEE ALSO

L<LLM::Agent::TokenCount>, L<LLM::Agent::Session> (which replays what
this produces), L<LLM::Chat::Retry> (the classification and the backoff).

=end pod

use LLM::Chat::Conversation::Message;
use LLM::Chat::Retry;

use LLM::Agent::TokenCount;
use LLM::Agent::Canonical;

unit class LLM::Agent::Compactor;

#| The header the synthetic summary message always opens with, so a model
#| reading the conversation can tell a summary from something a human
#| said. L<LLM::Agent::Session> stores the whole content, header included.
our constant SUMMARY-HEADER = '[Conversation summary — earlier turns compacted]';

#| What the summarizer is asked for. Fixed on purpose: a compaction whose
#| prompt varies per app produces summaries that vary per app, and the
#| loop's behaviour after a compaction stops being reproducible.
our constant INSTRUCTION = q:to/END/.trim;
	You are compacting the middle of a long agent conversation so that what
	remains fits in a smaller context window. Write a dense, factual summary
	of the transcript below, under these headings, in this order:

	1. GOALS — what the user asked for, including any constraint or
	   preference they stated.
	2. DECISIONS — what was decided or established as true, and why.
	3. FILES AND COMMANDS — every file path read or written, and every
	   command run, with its outcome.
	4. UNRESOLVED — what is still outstanding, failing, or deferred.

	Omit a heading that has nothing under it. No preamble, no sign-off, no
	invented facts. Prefer exact identifiers — paths, function names, error
	strings — over paraphrase. You are writing notes for the assistant that
	continues this conversation, not a report for a human.
	END

#|( Added to C<INSTRUCTION> for the one retry a summary that made no
    progress gets.

    B<Why an instruction rather than a cap:> the completion limit in
    L<LLM::Chat> lives on a backend's C<Settings> and applies to every
    call that backend serves. This one is shared — the summarizer is
    normally the loop's own backend — so turning it down here would turn
    it down for the conversation too, from a thread the conversation
    knows nothing about. An instruction reaches only this request, and
    the result is checked rather than trusted: a retry that is not
    smaller than the first attempt is discarded. )
our constant TIGHTEN = q:to/END/.trim;
	YOUR PREVIOUS ATTEMPT WAS TOO LONG. It was no shorter than the
	conversation it was meant to replace, which makes it useless — the
	entire point is to make the conversation smaller.

	Write it again, drastically shorter: at most a quarter of the length
	of the transcript below, and shorter still if you can manage it. Cut
	detail, not headings; keep exact identifiers, drop the prose around
	them. One dense line per fact is the target.
	END

#|( The backend that writes the summaries. Typically a cheaper model than
    the one running the conversation; C<@backends[0]> is fine. )
has $.backend is required;

#| The loop's counter instance. See the Pod — sharing it is the point.
has LLM::Agent::TokenCount:D $.counter is required;

#| The context window this conversation has to fit inside, in tokens.
has Int:D $.context-budget is required;

#| Compact once the conversation passes this fraction of the budget.
has Real:D $.trigger-ratio = 0.8;

#| How many messages at the end are always kept verbatim (extended back
#| so a tool-call/tool-result group is never split).
has Int:D $.keep-recent = 6;

#| Characters per tool result in the SUMMARIZER'S INPUT only. What the
#| conversation itself contains is never altered.
has Int:D $.tool-result-cap = 2_000;

#| What a hard trim aims for, as a fraction of the budget. Lower than
#| C<trigger-ratio> so a trim buys several rounds rather than one.
has Real:D $.target-ratio = 0.4;

#| Total summarization attempts before falling back to a hard trim.
has Int:D $.max-attempts = 3;

#|( Replace old tool results with stubs before reaching for the
    summarizer, and reclaim a batch of them as soon as there is one worth
    reclaiming. Off by default: with it off this class behaves exactly as
    it did before elision existed. See
    L</Observation aging: the cheap first resort>. )
has Bool:D $.age-observations = False;

#| A tool result has to be longer than this, in characters, to be worth
#| stubbing. Below it the stub saves nothing and the cache epoch is real.
has Int:D $.age-min-chars = 2_048;

#|( The size of an epoch, in characters, and it does two jobs: the
    eligible pool has to reach it before an aging pass is entered below the
    trigger, and a result has to have that much conversation content
    B<after> it before it is eligible at all (the trailing grace — the
    model has to have moved a whole epoch's work past a result before its
    bytes are taken away). One knob, because the two are the same
    statement about how much work an epoch is. )
has Int:D $.age-reclaim-min = 49_152;

submethod TWEAK {
	die 'LLM::Agent::Compactor: context-budget must be positive'
		unless $!context-budget > 0;
	die 'LLM::Agent::Compactor: keep-recent cannot be negative'
		if $!keep-recent < 0;
	die 'LLM::Agent::Compactor: tool-result-cap must be positive'
		unless $!tool-result-cap > 0;
	die 'LLM::Agent::Compactor: trigger-ratio must be greater than 0'
		unless $!trigger-ratio > 0;
	die 'LLM::Agent::Compactor: target-ratio must be greater than 0'
		unless $!target-ratio > 0;
	die 'LLM::Agent::Compactor: target-ratio must be below trigger-ratio, '
		~ 'or a compaction would leave the conversation still needing one'
		unless $!target-ratio < $!trigger-ratio;
	die 'LLM::Agent::Compactor: age-min-chars must be positive — a stub of '
		~ 'nothing reclaims nothing and costs a cache epoch'
		unless $!age-min-chars > 0;
	die 'LLM::Agent::Compactor: age-reclaim-min must be positive — it is the '
		~ 'size of an epoch, and an epoch of nothing would age one result per '
		~ 'round and pay a prefix cache miss for each'
		unless $!age-reclaim-min > 0;
	die 'LLM::Agent::Compactor: the backend must be able to '
		~ 'chat-completion; got '
		~ ($!backend.defined ?? 'a ' !! 'the type object ') ~ $!backend.^name
		unless $!backend.defined && $!backend.can('chat-completion');
}

#| The token count at which a conversation wants compacting.
method trigger(--> Int:D) { ceiling($!context-budget * $!trigger-ratio) }

#| The token count a hard trim aims to get under.
method target(--> Int:D) { ceiling($!context-budget * $!target-ratio) }

#|( Whether a compaction pass is worth making. The loop asks this at the
    top of every round, before it spends a request on a conversation that
    will not fit — and it is B<the> per-round decision, so every reason
    there is to make a pass is answered here rather than half here and half
    at the call site.

    There are two. C<@messages> has outgrown C<trigger>, which is what this
    has always meant; or C<age-observations> is on and there is an epoch's
    worth — C<age-reclaim-min> characters — of stubbable observation in the
    middle of it, which is worth a pass B<below> the trigger because that
    pass is free (see L</Observation aging: the cheap first resort>).

    C<:$tokens> is the count of C<@messages> when the caller has one
    already, or knows a bigger number that has to fit the same window: the
    loop's rendered run context is real weight on every request and is
    counted towards the trigger, without being part of the conversation
    this class works on. )
method needs-compaction(@messages, Int :$tokens --> Bool:D) {
	return True if ($tokens // $!counter.count-messages(@messages)) > self.trigger;

	# The floor, and the only reason to act below the trigger. Cheap to ask
	# when aging is off, which is the common case: the flag short-circuits
	# before the conversation is walked at all.
	so $!age-observations
		&& self!reclaimable-chars(@messages) >= $!age-reclaim-min;
}

#|( Compact C<@messages>. Never throws and never returns an unusable
    conversation: see the failure policy in the Pod. C<:&cancelled> is
    polled during the backoff between summarization attempts, and a
    cancelled compaction hard-trims rather than hanging on.

    C<:$target> overrides C<target> B<for this invocation only>, and is
    how L<LLM::Agent::Loop> asks for a compaction against a number this
    class does not know: the largest request that would actually fit
    the selected backend (window minus completion reserve and safety
    margin). C<:$counter> carries that backend's tokenizer and, from the
    loop, its fixed context/tool framing through every candidate count. See
    L</Compacting to somebody else's number>. )
method compact(
	@messages, :&cancelled, Int :$target,
	LLM::Agent::TokenCount :$counter,
	--> Map
) {
	my LLM::Agent::TokenCount:D $active-counter = $counter // $!counter;
	my Int $tokens-before = $active-counter.count-messages(@messages);
	my Int $cut = self!cut-index(@messages);

	# Nothing between the sticky prefix and the recent window: a no-op,
	# and — importantly — no backend call. Nothing is elidable either: the
	# region elision works in is the region this says is empty.
	return self!unchanged(@messages, $tokens-before, $target)
		if $cut < 0 || !self!middle(@messages, $cut).elems;

	# The first resort, and the cheap one: fat observations in the middle
	# become stubs, in place. Everything below this line works on the
	# result — including the summarizer, which is why one enormous read
	# stops dominating the transcript it is asked to summarize.
	my @elisions = self!elisions(@messages, $cut);
	my @aged = @elisions.elems
		?? apply-elisions(@messages, @elisions)
		!! @messages.List;
	my Int $tokens-aged = @elisions.elems
		?? $active-counter.count-messages(@aged)
		!! $tokens-before;

	# And when that was enough, the pass ends here: no request, no summary
	# message, nothing dropped. `trigger` rather than `context-budget` is
	# the untargeted line to clear, because it is the line that decides
	# whether the next round asks for a pass again.
	return self!elided(@aged, @elisions, $tokens-before, $tokens-aged)
		if @elisions.elems && $tokens-aged <= ($target // self.trigger);

	my $summary = self!summarize(@aged, $cut, :&cancelled);

	if $summary.defined {
		my %summarized = self!summarized(
			@aged, $cut, $summary, $tokens-before, $active-counter, :@elisions,
		);
		# NB the comparison is against the AGED count, not the count the
		# result reports: a summary has to beat the conversation it is
		# actually replacing, which elision has already made smaller.
		return %summarized.Map
			if self!good-enough(%summarized<tokens-after>, $tokens-aged, $target);

		# A summary that is not smaller than what it replaced is not a
		# compaction, it is a rewrite — and accepting it means the next
		# round asks for one again, over a conversation that has not
		# moved. One more try, told in as many words to be shorter, and
		# only accepted if it really is.
		my $tighter = self!attempt-summary(
			self!summarizer-input(@aged, $cut, :tighten),
		);
		if $tighter<ok> {
			my %retried = self!summarized(
				@aged, $cut, $tighter<summary>, $tokens-before, $active-counter,
				:@elisions,
			);
			return %retried.Map
				if self!good-enough(%retried<tokens-after>, $tokens-aged, $target)
					&& %retried<tokens-after> < %summarized<tokens-after>;
		}
	}

	self!trim(
		@aged, $cut, $tokens-before, $active-counter, $target, :@elisions,
	);
}

#|( Is a summary worth keeping? Smaller than what it replaced — always —
    and, when a caller named a C<$target>, actually under it.

    The second half only exists for the targeted call. A summary that
    shrank the conversation but left it too big for the backend that
    asked for the compaction has not solved the caller's problem, and
    accepting it would mean handing back a conversation whose next
    request is still guaranteed to fail while a hard trim that would have
    fitted was one line away. )
method !good-enough(Int:D $after, Int:D $before, Int $target --> Bool:D) {
	so ($after < $before && (!$target.defined || $after <= $target));
}

# The result of accepting C<$summary>: the same Hash `compact` returns,
# built before anybody has decided whether it is good enough to return.
method !summarized(
	@messages, Int:D $cut, Str:D $summary, Int:D $tokens-before,
	LLM::Agent::TokenCount:D $counter,
	:@elisions,
	--> Hash:D
) {
	my $content = SUMMARY-HEADER ~ "\n" ~ $summary;
	my @result = self!assemble(@messages, $cut, $content);

	%(
		messages        => @result.List,
		summary         => $content,
		dropped         => self!middle(@messages, $cut).elems,
		'cut-index'     => $cut,
		'tokens-before' => $tokens-before,
		'tokens-after'  => $counter.count-messages(@result),
		fallback        => False,
		exhausted       => False,
		elisions        => @elisions.List,
	);
}

#|( The result of a pass that stubbed observations and needed nothing else:
    the same shape, with nothing replaced.

    C<dropped> is 0 and C<cut-index> is -1 — no message was taken out of
    the conversation, so there is no cut for a transcript to name — and
    C<exhausted> is False by construction: this is returned only when the
    aged conversation is under the number the pass was aiming at. The
    C<messages> are B<not> the input, which is what separates this from the
    no-op C<!unchanged>. )
method !elided(
	@aged, @elisions, Int:D $tokens-before, Int:D $tokens-after,
	--> Map
) {
	%(
		messages        => @aged.List,
		summary         => '',
		dropped         => 0,
		'cut-index'     => -1,
		'tokens-before' => $tokens-before,
		'tokens-after'  => $tokens-after,
		fallback        => False,
		exhausted       => False,
		elisions        => @elisions.List,
	).Map;
}

# === Choosing what to replace ===

# The index of the last message the compaction replaces: one before the
# recent window, with the window extended backwards so it never opens on
# a tool result whose assistant turn would be left behind.
method !cut-index(@messages --> Int) {
	my Int $start = max(0, @messages.elems - $!keep-recent);
	while $start > 0 && @messages[$start].role eq 'tool' {
		$start--;
	}
	$start - 1;
}

# The messages in 0..$cut that a compaction is allowed to take.
method !middle(@messages, Int:D $cut --> List) {
	return () if $cut < 0;
	@messages[0 .. $cut].grep({ !.is-sticky }).List;
}

#|( The conversation with everything non-sticky through C<$cut> replaced
    by one message carrying C<$content>.

    B<This is the transformation L<LLM::Agent::Session> replays.> Keep
    them in step: sticky messages through the cut in their original
    order, then the synthetic message, then everything after the cut,
    untouched. )
method !assemble(@messages, Int:D $cut, Str:D $content --> List) {
	my @result = @messages[0 .. $cut].grep({ .is-sticky });
	@result.push: LLM::Chat::Conversation::Message.new(
		role    => 'user',
		content => $content,
	);
	@result.append: @messages[$cut + 1 .. *-1] if $cut + 1 < @messages.elems;
	@result.List;
}

method !unchanged(@messages, Int:D $tokens-before, Int $target? --> Map) {
	%(
		messages        => @messages.List,
		summary         => '',
		dropped         => 0,
		'cut-index'     => -1,
		'tokens-before' => $tokens-before,
		'tokens-after'  => $tokens-before,
		fallback        => False,
		# A no-op over a conversation that is merely past the TRIGGER is
		# fine — the next request still fits. A no-op over one past the
		# BUDGET (or past the caller's own target) is the end of the road:
		# there was nothing to summarize, so there is nothing left to try.
		exhausted       => $tokens-before > ($target // $!context-budget),
		# There is no middle, so there was nothing elision could have taken
		# either — the two work from the same cut.
		elisions        => (),
	).Map;
}

# === Aging: elision in place ===

#|( The marker every stub opens with. It is what keeps a pass from stubbing
    its own stubs — and therefore what keeps an aging pass that has nothing
    left to do from reporting that it did something. )
our constant ELISION-PREFIX = '[elided by the harness: ';

#|( One stub, and B<only> a function of its inputs: two runs over the same
    conversation produce the same bytes, so a digest over the result means
    something. The tool name is included when the result can be joined back
    to the call that produced it, and omitted when it cannot — a model that
    is told which call it can re-run does not have to guess. )
my sub elision-stub(Int:D $chars, Str $tool --> Str:D) {
	ELISION-PREFIX ~ $chars ~ '-char '
		~ (($tool.defined && $tool.chars) ?? $tool ~ ' ' !! '')
		~ 'result; re-run the call if you need it again]';
}

# The conversation with every elision applied. `.clone` rather than a fresh
# Message: role, tool-call-id, the stickiness flags and anything a later
# version of LLM::Chat adds ride along untouched, which is the whole safety
# argument for elision — the message is the same message, and only its
# content is lighter. The checksum is explicitly cleared: it is a memo of
# the content that has just gone.
my sub apply-elisions(@messages, @elisions --> List) {
	my %stub = @elisions.map({ $_<index> => $_<stub> }).Hash;
	@messages.kv.map(-> Int $index, $message {
		(%stub{$index}:exists)
			?? $message.clone(content => %stub{$index}, checksum => Str)
			!! $message;
	}).List;
}

#|( Where every tool result in C<@messages> came from, keyed by the
    C<tool_call_id> the assistant's call carried: C<< { tool, identity } >>.

    C<identity> is the tool's name and its B<canonicalised> arguments, so
    the same read issued twice — with the keys in a different order, or
    with different whitespace — is one call made twice rather than two
    different ones. It is the key the loop's identical-call guard compares
    by, through the same L<LLM::Agent::Canonical> function.

    First writer wins: a provider that reuses a call id is describing one
    call, and the earlier turn is the one whose result came first. )
my sub call-origins(@messages --> Hash:D) {
	my %origins;

	for @messages -> $message {
		for $message.tool-calls.list -> $call {
			next unless $call ~~ Associative;
			my $id = $call<id>;
			next unless $id ~~ Str:D && $id.chars;
			next if %origins{$id}:exists;

			my $function = $call<function>;
			next unless $function ~~ Associative;
			my Str $tool = ($function<name> // '').Str;
			%origins{$id} = %(
				tool     => $tool,
				identity => $tool ~ "\0"
					~ canonical-arguments($function<arguments>),
			);
		}
	}

	%origins;
}

# The identity of the call a tool result answers, or an undefined Str when
# it cannot be joined to one — no tool-call-id, or an assistant turn a
# previous compaction summarized away. An unjoinable result gets neither
# duplicate protection nor duplicate eligibility; the ordinary rules still
# apply to it.
my sub identity-of(%origins, $message --> Str) {
	my $id = $message.tool-call-id;
	return Str unless $id ~~ Str:D && $id.chars;
	(%origins{$id}:exists) ?? %origins{$id}<identity> !! Str;
}

# How much conversation content follows each position: @trailing[$i] is the
# characters of content in @messages[$i + 1 .. *-1]. Built from the back, so
# a conversation of N messages costs one walk rather than N.
my sub trailing-chars(@messages --> List) {
	my @trailing = 0 xx @messages.elems;
	my Int $last = @messages.elems - 2;
	for 0 .. $last -> Int $offset {
		my Int $index = $last - $offset;
		@trailing[$index] =
			@trailing[$index + 1] + (@messages[$index + 1].content // '').chars;
	}
	@trailing.List;
}

#|( The elisions an aging pass would make over C<@messages>, as
    C<< [ { index, stub }, ... ] >> in position order — empty when aging is
    off, when there is no middle region, or when nothing in it qualifies.

    The rules, and the order they are applied in, are in the Pod under
    L</What is eligible, and what is protected>. )
method !elisions(@messages, Int:D $cut --> List) {
	return () unless $!age-observations;
	return () if $cut < 0;

	my %origins  = call-origins(@messages);
	my @trailing = trailing-chars(@messages);

	# Every call identity that was answered more than once, and where its
	# newest answer is. Counted over the WHOLE conversation, including the
	# recent window: a fresh copy in the window is exactly the copy the
	# protection is for.
	my %count;
	my %newest;
	for @messages.kv -> Int $index, $message {
		next unless $message.role eq 'tool';
		my $identity = identity-of(%origins, $message);
		next without $identity;
		%count{$identity}++;
		%newest{$identity} = $index;
	}

	my @elisions;
	for 0 .. $cut -> Int $index {
		my $message = @messages[$index];

		# A tool result, and nothing else. An assistant turn is the
		# reasoning the conversation is built on, a user turn is what was
		# asked for, and a sticky message is the one thing a compaction of
		# any kind never touches.
		next unless $message.role eq 'tool';
		next if $message.is-sticky;

		my Str $content = ($message.content // '').Str;
		# Already a stub. Stubbing one again would report an elision that
		# changed nothing, and a pass that claims to have acted when it has
		# not is how a compaction loop starts.
		next if $content.starts-with(ELISION-PREFIX);

		my $identity = identity-of(%origins, $message);
		my Bool $dup = $identity.defined && (%count{$identity} // 0) > 1;

		# The loop breaker: the newest answer to a call that was made more
		# than once is protected outright, so a model that re-ran a call
		# after its result was stubbed keeps what it went and fetched.
		next if $dup && %newest{$identity} == $index;

		# ...and every older copy is dead weight whatever its size or its
		# age, because the whole of it exists again further down the
		# conversation.
		unless $dup {
			next unless $content.chars > $!age-min-chars;
			# The trailing grace. Positional recency is too weak — one
			# tool-heavy round can push eight messages — so recency is
			# measured in content instead: an epoch's worth of work has to
			# have happened since, or the model is probably still using it.
			next unless @trailing[$index] >= $!age-reclaim-min;
		}

		@elisions.push: %(
			index => $index,
			stub  => elision-stub(
				$content.chars,
				$identity.defined
					?? %origins{$message.tool-call-id}<tool>
					!! Str,
			),
		);
	}

	@elisions.List;
}

# The characters an aging pass would reclaim from C<@messages> right now:
# the content of everything eligible, which is exactly what the epoch floor
# is compared against. It is ~0 once a pass has taken the batch — a stub is
# not eligible, and stubbing shortens the trailing content the results
# before it are measured against — which is what makes the floor
# self-resetting rather than a switch that stays on.
method !reclaimable-chars(@messages --> Int) {
	my Int $cut = self!cut-index(@messages);
	return 0 if $cut < 0;

	[+] self!elisions(@messages, $cut).map({
		(@messages[$_<index>].content // '').chars;
	});
}

# === Summarizing ===

# The two messages the summarizer is asked with. `:tighten` adds the
# second-chance instruction; everything else is identical, deliberately —
# the retry summarizes the same transcript, not a different one.
method !summarizer-input(@messages, Int:D $cut, Bool :$tighten --> List) {
	(
		LLM::Chat::Conversation::Message.new(
			role    => 'system',
			content => $tighten ?? INSTRUCTION ~ "\n\n" ~ TIGHTEN !! INSTRUCTION,
		),
		LLM::Chat::Conversation::Message.new(
			role    => 'user',
			content => "<transcript>\n"
				~ self!render(self!middle(@messages, $cut))
				~ "\n</transcript>",
		),
	);
}

# The model's summary, or an undefined Str when every attempt failed.
method !summarize(@messages, Int:D $cut, :&cancelled --> Str) {
	my @input = self!summarizer-input(@messages, $cut);

	my Int $attempt = 0;
	my Str $summary;

	while $attempt < $!max-attempts {
		$attempt++;

		my %try = self!attempt-summary(@input);
		if %try<ok> {
			$summary = %try<summary>;
			last;
		}

		# A configuration or account failure will not heal inside three
		# backoffs; stop spending them on it. NB the `// Str` / `// Int`:
		# a hash key that was never set reads as an `Any` type object,
		# which is not an acceptable value for a `Str` or `Int` parameter.
		last if classify-error(
			error-class  => %try<error-class>  // Str,
			error-status => %try<error-status> // Int,
		) eq 'abort';

		last if $attempt >= $!max-attempts;

		# One backend, so there is nothing to advance to: every
		# non-abort bucket waits and tries the same one again. A cancel
		# during the wait ends the retries, and the caller hard-trims.
		last unless sleep-with-cancel(retry-backoff($attempt), :&cancelled);
	}

	$summary;
}

# One blocking call, with every way it can go wrong flattened into the
# same shape a Response failure has.
method !attempt-summary(@input --> Hash:D) {
	my $resp;
	my $threw;
	{
		CATCH { default { $threw = $_ } }
		$resp = $!backend.chat-completion(@input);
	}

	return %(
		ok            => False,
		error         => 'the summarization backend threw: '
			~ ($threw.message.lines.head // $threw.^name),
		'error-class' => Str,
	) if $threw.defined;

	return %(
		ok            => False,
		error         => ($resp.err // 'the summarization call failed').Str,
		'error-class' => $resp.error-class,
		'error-status' => $resp.error-status,
	) unless $resp.defined && $resp.is-success;

	my Str $text = ($resp.msg // '').Str;

	# An empty summary is worse than no compaction: it deletes the middle
	# of the conversation and says nothing in its place.
	return %(
		ok            => False,
		error         => 'the summarizer returned an empty summary',
		'error-class' => 'response',
	) unless $text.trim.chars;

	%( ok => True, summary => $text.trim );
}

# The middle as plain text for the summarizer, with tool results capped.
method !render(@middle --> Str:D) {
	@middle.map(-> $message {
		my $role = $message.role.Str;
		my $body = ($message.content // '').Str;

		if $role eq 'tool' && $body.chars > $!tool-result-cap {
			$body = $body.substr(0, $!tool-result-cap)
				~ "\n... [{$body.chars - $!tool-result-cap} more characters "
				~ 'of tool output, truncated for summarization]';
		}

		my @lines = "[$role]";
		@lines.push: $body if $body.chars;
		for $message.tool-calls.list -> $call {
			next unless $call ~~ Associative;
			my $function = $call<function>;
			next unless $function ~~ Associative;
			my $arguments = $function<arguments> // '';
			$arguments = $arguments.Str;
			# Marked, exactly as the tool result above is: a call whose
			# arguments stop mid-JSON with nothing said about it reads to
			# the summarizer like a call the model really made that way,
			# and "the model wrote a truncated tool call" is precisely the
			# kind of thing a summary then repeats as fact.
			if $arguments.chars > $!tool-result-cap {
				my Int $elided = $arguments.chars - $!tool-result-cap;
				$arguments = $arguments.substr(0, $!tool-result-cap)
					~ "\n... [$elided more characters of tool-call "
					~ 'arguments, truncated for summarization]';
			}
			@lines.push: "-> calls {$function<name> // 'unknown'}($arguments)";
		}
		@lines.join("\n");
	}).join("\n\n");
}

# === The fallback ===

#|( Drop the oldest non-sticky messages until the conversation is under
    C<target>, pair-aligned, never past C<$cut>. The result has the same
    shape a summarized compaction has — sticky prefix, one synthetic
    message, tail — because L<LLM::Agent::Session> replays both the same
    way. )
method !trim(
	@messages, Int:D $cut, Int:D $tokens-before,
	LLM::Agent::TokenCount:D $counter, Int $aim?, :@elisions,
	--> Map
) {
	my Int $target = $aim // self.target;
	my Int $chosen = $cut;
	my @result;
	my Str $content;

	# Walk the possible cuts from least destructive to most, and stop at
	# the first one that fits. Every candidate index is a real drop, so a
	# conversation of N messages costs at most N counts.
	for self!candidate-cuts(@messages, $cut) -> Int $candidate {
		my $dropped = self!middle(@messages, $candidate).elems;
		my $try-content = self!trim-content($dropped);
		my @try = self!assemble(@messages, $candidate, $try-content);

		if $counter.count-messages(@try) <= $target {
			$chosen  = $candidate;
			@result  = @try;
			$content = $try-content;
			last;
		}
	}

	unless @result.elems {
		# Nothing fits: take the whole middle. That is the floor — see
		# the Pod on why the recent window is never eaten into.
		$chosen  = $cut;
		$content = self!trim-content(self!middle(@messages, $cut).elems);
		@result  = self!assemble(@messages, $cut, $content);
	}

	my Int $tokens-after = $counter.count-messages(@result);

	%(
		messages        => @result.List,
		summary         => $content,
		dropped         => self!middle(@messages, $chosen).elems,
		'cut-index'     => $chosen,
		'tokens-before' => $tokens-before,
		'tokens-after'  => $tokens-after,
		fallback        => True,
		# The last word. A hard trim is the floor of what this class can
		# do, so a trim that did not shrink the conversation — or that
		# shrank it and still left it over the window (or over the target
		# a caller named, which is the same statement about a number this
		# class was handed) — is the end of the line, and saying so is
		# worth more than handing back a conversation whose next request
		# cannot succeed.
		exhausted       => $tokens-after >= $tokens-before
			|| $tokens-after > ($aim // $!context-budget),
		elisions        => @elisions.List,
	).Map;
}

# Every cut a hard trim may stop at, smallest first: an index that really
# drops something, and never one that would orphan a tool result from the
# assistant turn that asked for it.
method !candidate-cuts(@messages, Int:D $cut --> List) {
	my @cuts;
	for 0 .. $cut -> Int $index {
		next if @messages[$index].is-sticky;

		# Extend forward over the tool results answering this turn, so a
		# cut never lands between an assistant's tool-calls and them.
		my Int $end = $index;
		while $end + 1 <= $cut && @messages[$end + 1].role eq 'tool' {
			$end++;
		}
		@cuts.push: $end unless @cuts.elems && @cuts.tail >= $end;
	}
	@cuts.List;
}

method !trim-content(Int:D $dropped --> Str:D) {
	SUMMARY-HEADER ~ "\n"
		~ "The summarizer could not be reached, so $dropped earlier "
		~ 'message(s) were dropped from this conversation without being '
		~ 'summarized. Their content is not available; ask the user rather '
		~ 'than guessing at what they said.';
}
