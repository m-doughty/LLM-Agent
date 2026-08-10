=begin pod

=head1 NAME

LLM::Agent::RunContext - the refreshable half of a prompt: what is true
right now, rendered into the request rather than into the conversation

=head1 SYNOPSIS

=begin code :lang<raku>

use LLM::Agent::RunContext;

# Built fresh per run — the caller reads the clock, the repository and
# the instruction files; this class only takes strings.
my $context = LLM::Agent::RunContext.new(
    head-sections => [
        identity     => 'You are a coding assistant working in a checked-out repository.',
        instructions => LLM::Agent::Prompt::instructions-from-files(['AGENTS.md']),
    ],
    facts => [
        platform   => 'darwin (arm64)',
        date       => Date.today.Str,
        cwd        => $*CWD.Str,
        'git-head' => $head,
    ],
    tail-sections => [
        reminders => "The test suite is `prove6 -I. t`.",
    ],
);

my $run = $loop.run(@messages, :$context);

=end code

The request that goes out is C<< [head, |@messages, tail] >>; C<@messages>
itself is untouched, and so is the transcript. The tail reads:

=begin code :lang<text>

## Current context

- platform: darwin (arm64)
- date: 2026-08-10
- cwd: /srv/project
- git-head: 4f2c9ab

The test suite is `prove6 -I. t`.

This block supersedes any environment description, tool catalogue or
project instructions that appear earlier in this conversation; where they
disagree, this block is authoritative.
This block is context, not a request: do not acknowledge it, and do not
reply to it.

=end code

=head1 DESCRIPTION

A system prompt has two halves with completely different lifetimes. One
is B<history>: what the agent is, what the human asked, what the tools
said. The other is B<context>: today's date, the working directory, the
branch, the contents of C<AGENTS.md>. The first belongs in the
conversation, is written to the transcript and must never change under a
resumed run — the loop's seed check exists to enforce exactly that. The
second is true only while it is true.

Baked together into one sticky message at index 0 they become the same
thing, and the durable one wins: a session resumed in October replays
August's date, August's tool catalogue and August's project instructions,
for as long as the transcript lives.

A C<RunContext> is the second half, kept out of the conversation
entirely. L<LLM::Agent::Loop> renders it into B<the request> — and only
the request — for the run it was handed to:

=item C<@conversation> never contains it, so the seed check, the session
appends, L<LLM::Agent::Compactor> and C<< %outcome<messages> >> all see
exactly what they saw before;

=item nothing about it is digest-locked, so the next run may say something
completely different without a resumed run being refused;

=item what it said is still B<recorded> — the loop writes one
C<run-context> envelope per run (see L<LLM::Agent::Session>), so a
transcript can still answer "what was this agent told, that day?".

=head2 Facts are Pairs, and that is not a style choice

C<facts> is a B<List of Pairs>, in the order they should be rendered. A
Hash is refused at construction, and the reason is worth spelling out
because the bug it prevents is close to undetectable:

Raku randomises Hash iteration order B<per process>. Rendering facts
straight out of a Hash would therefore produce a different string in every
process — quietly defeating any prompt cache keyed on the text — while
C<.digest>, which is canonical JSON with B<sorted> keys, stayed
byte-identical. Two processes would render two different prompts, agree
that they were the same context, and nothing anywhere would disagree.

So the order is the caller's, explicitly:

=begin code :lang<raku>

# Right: rendered in this order, every process, every time.
facts => [ date => $today, cwd => $cwd ]

# Refused at construction, with that explanation.
facts => { date => $today, cwd => $cwd }

# Also refused, and told what it really is: parentheses around one Pair
# are that Pair, not a list of one. The fix is a comma (or brackets).
facts => (date => $today)

=end code

An undefined value is B<dropped> rather than rendered as an empty string —
the same rule L<LLM::Agent::Prompt>'s C<env-block> follows, so an optional
fact can be passed as an undefined variable with no conditional at the
call site. A fact whose value is not a Str and not undefined is refused:
stringifying a Hash into a prompt is never what the caller meant.

=head2 Head and tail, and why the split is not cosmetic

Sections come in two lists, and they land on opposite sides of the
conversation:

=begin table

List          | Where it goes    | What belongs in it
==============|==================|===============================================
head-sections | before message 0 | identity, instructions — stable across turns
tail-sections | after the last   | anything volatile, and anything that must win

=end table

The split is about B<prefix caching>. Every backend worth using caches
the KV prefix of a request and charges less for the part it did not have
to re-prefill; the cache holds up to the first byte that differs from
last time. A block that changes every turn — a clock, a git HEAD, a list
of open files — placed near index 0 therefore invalidates the whole
conversation on every single request. The same block at the B<end> costs
only itself.

So: put the prose that is stable for the life of the session in the head,
and everything that moves in the tail. Facts always render in the tail,
because facts are what move.

The tail also has the last word, which is the other half of the
argument: a model reading a fifty-turn conversation weights what it read
most recently, and "the date is October 3rd" arriving after fifty turns
of August is more likely to be believed than the same sentence at the
top.

=head2 What the tail says, and why

Beyond the facts and the tail sections, the block ends with two fixed
lines, and both are load-bearing:

=item B<the supersedes line> — the block outranks any environment
description, tool catalogue or project instructions that appear earlier in
the conversation, and where they disagree it is authoritative. That is
what makes a B<legacy> transcript — one whose index 0 is a fat system
prompt from before this class existed — safe to resume: the stale
environment block is still in the conversation, and the model has been
told, at the end, which one to believe.

=item B<the not-a-request line> — the block is context, not an
instruction to respond to. Without it a model that has just been handed a
list of facts will cheerfully reply "Thanks! I see you are on branch
main" instead of answering the question.

=head2 What is normalised, and what is not

Trailing whitespace comes off every value at construction, so the string
this class stores, the string it renders and the string it digests are
one string. That is what keeps an C<AGENTS.md> that gained a final
newline from counting as a section that changed — and therefore from
being stored a second time in the transcript.

Nothing else is touched. A fact value with a newline in the middle of it
renders as two lines of the block, because a class that quietly rewrote
what it was told to say would be a worse problem than an ugly bullet.

=head2 Nothing is inferred, and nothing is re-read

Every value is a Str the caller passed in. This class never calls
C<Date.today>, never looks at C<$*CWD>, never runs C<git> and never reads
a file: it does not know what a fact means, and an agent whose tools run
somewhere other than where the prompt says they do has been lied to by a
layer that had no way of knowing better.

That also makes it B<deterministic>: the same arguments produce the same
strings and the same digest, in every process. All of the rendering
happens once, at construction, so C<.head-message> and C<.tail-message>
cost nothing to ask for repeatedly and cannot change under a run that is
already using them.

=head2 The digest, and the per-section digests

C<.digest> is a canonical hash (L<LLM::Agent::Canonical>) over the facts
and both section lists, order included. Two contexts with the same digest
are the same context; the loop uses it to decide whether a calibrated
token count from the previous run still describes anything (see
L<LLM::Agent::TokenCount>'s C<invalidate>), and the session records it so
a transcript can say which runs shared a context.

The same digest decides what the context B<costs>: L<LLM::Agent::Loop>
weighs the two rendered messages once per run, as text, through its own
counter — not the per-model counter a L<LLM::Agent::RequestBudget>
C<Profile> may carry, which counts only the conversation. The context is
priced before a backend has been chosen, the way the tool declarations
are.

C<.sections> is the same information one section at a time — C<name>,
C<digest> and C<rendered> — head sections first, then tail. That is what
L<LLM::Agent::Session>'s C<append-run-context> writes, and what lets a
transcript store one copy of an C<AGENTS.md> that did not change between
forty runs instead of forty copies of it.

=head2 Empty is empty

An empty section is B<dropped>, exactly as L<LLM::Agent::Prompt>'s
C<assemble> drops one, so a caller can pass
C<< instructions-from-files(@paths) >> without first checking whether any
of the paths existed.

If B<every> head section is empty, C<.head-message> is an B<undefined>
Message and no head message is sent at all. If there are no facts B<and>
no non-empty tail sections, the same is true of C<.tail-message> — the
supersedes boilerplate on its own is not worth a message, and a context
with nothing in it costs a request nothing.

=begin code :lang<raku>

my $nothing = LLM::Agent::RunContext.new;
$nothing.head-message.defined;   # False
$nothing.tail-message.defined;   # False — the request is unchanged

=end code

=head1 SEE ALSO

L<LLM::Agent::Loop> (C<< run(@messages, :$context) >>),
L<LLM::Agent::Session> (the C<run-context> envelope),
L<LLM::Agent::Prompt> (where the section strings usually come from),
L<LLM::Agent::Canonical> (the digests).

=end pod

use LLM::Chat::Conversation::Message;

use LLM::Agent::Canonical;

unit class LLM::Agent::RunContext;

my constant Message = LLM::Chat::Conversation::Message;

#|( The header the tail block opens with. Deliberately a heading rather
    than prose: it is a section of a document as far as a chat template is
    concerned, and models treat it as one. )
our constant CONTEXT-HEADER = '## Current context';

#|( The first of the two fixed lines the tail block ends with: this block
    outranks anything earlier in the conversation that describes the same
    world. See the module Pod on what it makes safe. )
our constant SUPERSEDES-LINE =
	'This block supersedes any environment description, tool catalogue or '
	~ 'project instructions that appear earlier in this conversation; where '
	~ 'they disagree, this block is authoritative.';

#| The second: it is context, not something to answer.
our constant NOT-A-REQUEST-LINE =
	'This block is context, not a request: do not acknowledge it, and do not '
	~ 'reply to it.';

# The three inputs, normalised at construction. Private, with List
# accessors below, because an instance is immutable: a public `@.` would
# hand a caller the Array itself, and one `.push` on it would leave the
# facts saying one thing and the already-rendered messages and digest
# another.
has @!facts;
has @!head-sections;
has @!tail-sections;

# Everything below is derived, and derived ONCE: an instance is immutable,
# a run may ask for its messages on any thread, and re-rendering per
# request would be work for an answer that cannot have changed.
has Message $!head-message;
has Message $!tail-message;
has Str $!digest;
has @!sections;

# One "- key: value" line, the same shape LLM::Agent::Prompt renders.
my sub bullet(Pair:D $fact --> Str:D) {
	'- ' ~ $fact.key ~ ': ' ~ $fact.value;
}

# The Pairs of one incoming list, validated and normalised. Undefined
# values are dropped (an optional fact needs no conditional at the call
# site); anything that is not a Pair of Str is a mistake worth hearing
# about at construction rather than in a prompt three hours later.
my sub pairs-of($raw, Str:D $what --> List:D) {
	# A lone Pair BEFORE the Hash check, and not by accident: a Pair does
	# the Associative role, so `facts => (date => '…')` — one fact, no
	# comma — would otherwise be told it was given a Hash, which it
	# emphatically was not. The mistake is Raku's single-argument rule
	# rather than a container choice, and the fix is a comma.
	die "LLM::Agent::RunContext: $what was given a single Pair rather than a "
		~ 'list of them — a lone Pair in parentheses IS that Pair, not a '
		~ "one-entry list. Write $what => [ " ~ $raw.key.raku
		~ ' => ... ] (square brackets), or add the trailing comma.'
		if $raw ~~ Pair;

	die "LLM::Agent::RunContext: $what was given a Hash, and a Hash cannot "
		~ 'say what order it is in — Raku randomises hash iteration per '
		~ 'process, so the same context would render differently in two '
		~ 'processes while its digest (canonical JSON, sorted keys) stayed '
		~ "identical. Pass a List of Pairs: $what => [ a => '1', b => '2' ]"
		if $raw ~~ Associative;

	my @out;
	for $raw.list.kv -> Int $index, $entry {
		die "LLM::Agent::RunContext: entry $index of $what is a "
			~ $entry.^name ~ ", not a Pair — $what is an ORDERED list of "
			~ "key => value Pairs"
			unless $entry ~~ Pair;

		my $key = $entry.key;
		die "LLM::Agent::RunContext: entry $index of $what has a "
			~ $key.^name ~ ' key; a name is a non-empty Str'
			unless $key ~~ Str:D && $key.trim.chars;

		my $value = $entry.value;
		# Dropped, not rendered as '': an optional fact can be passed as an
		# undefined variable, which is what env-block does too.
		next unless $value.defined;

		die "LLM::Agent::RunContext: entry $index of $what ('$key') has a "
			~ $value.^name ~ ' value; every value is a Str, because this '
			~ 'class renders text and has no idea how you want a '
			~ $value.^name ~ ' to look in a prompt'
			unless $value ~~ Str:D;

		# Trailing whitespace off, here and once: it is what
		# LLM::Agent::Prompt::assemble does to a section, and doing it at
		# the boundary is what makes the stored value, the rendered block
		# and the digested one the same string — so a file that gained a
		# newline is not a section that changed.
		@out.push: $key => $value.trim-trailing;
	}

	@out.List;
}

# The blocks of a section list that have something to say. Empty ones are
# dropped from the MESSAGE only: they are still part of the context, and
# still part of its digest.
my sub kept-sections(@sections --> List:D) {
	@sections.grep({ .value.trim.chars }).List;
}

# A system Message that is neither sticky NOR a sysprompt: it is not part
# of the conversation, it is never written to a transcript, and a
# compaction will never see it — so the two flags that exist to protect a
# message from compaction have nothing to protect here, and setting them
# would only make this look like history to anything that inspected it.
my sub context-message(@parts --> Message) {
	return Message unless @parts.elems;
	Message.new(role => 'system', content => @parts.join("\n\n"));
}

#| The named arguments C<.new> takes, and the only ones it takes.
my constant ARGUMENTS = <facts head-sections tail-sections>.Set;

submethod TWEAK(*%args) {
	# Raku accepts any named argument and quietly drops the ones no
	# attribute matches, which for a class whose whole surface is three
	# lists would turn `head_sections => [...]` into a context that renders
	# nothing and says nothing about why.
	with %args.keys.grep({ !ARGUMENTS{$_} }).sort.head -> $unknown {
		die "LLM::Agent::RunContext: there is no '$unknown' argument; a "
			~ 'context is built from ' ~ ARGUMENTS.keys.sort.join(', ');
	}

	@!facts         = pairs-of(%args<facts>         // (), 'facts');
	@!head-sections = pairs-of(%args<head-sections> // (), 'head-sections');
	@!tail-sections = pairs-of(%args<tail-sections> // (), 'tail-sections');

	my @head-kept = kept-sections(@!head-sections);
	my @tail-kept = kept-sections(@!tail-sections);

	$!head-message = context-message(@head-kept.map({ .value }).List);

	# The header is part of the block, not a reason to have one: a context
	# with no facts and no tail prose sends nothing, so the two fixed lines
	# below never travel on their own.
	my @tail-parts;
	if @!facts.elems || @tail-kept.elems {
		@tail-parts.push: @!facts.elems
			?? (CONTEXT-HEADER, '', |@!facts.map({ bullet($_) })).join("\n")
			!! CONTEXT-HEADER;
		@tail-parts.append: @tail-kept.map({ .value });
		@tail-parts.push: (SUPERSEDES-LINE, NOT-A-REQUEST-LINE).join("\n");
	}
	$!tail-message = context-message(@tail-parts);

	# Over the sections AS GIVEN rather than as kept: a section that was
	# emptied since the last run is a change worth noticing, even though it
	# renders to the same text.
	$!digest = data-digest({
		facts           => @!facts.map({ ($_.key, $_.value).List }).List,
		'head-sections' => @!head-sections.map({ ($_.key, $_.value).List }).List,
		'tail-sections' => @!tail-sections.map({ ($_.key, $_.value).List }).List,
	});

	@!sections = (|@!head-sections, |@!tail-sections).map(-> $section {
		%(
			name     => $section.key,
			digest   => data-digest(($section.key, $section.value).List),
			rendered => $section.value,
		);
	}).List;
}

#|( The facts, as C<< key => value >> Pairs B<in render order>, with the
    undefined ones dropped. A Hash is refused at construction — see the
    module Pod; the bug it prevents is the worst shape there is. )
method facts(--> List:D) { @!facts.List }

#|( Stable-across-turns prose, as C<< name => block >> Pairs, rendered
    B<before> the conversation. As given: the empty ones are dropped from
    the B<message>, not from here. )
method head-sections(--> List:D) { @!head-sections.List }

#| Volatile prose, same shape, rendered B<after> the conversation —
#| closest to generation, and outside the cacheable prefix.
method tail-sections(--> List:D) { @!tail-sections.List }

#|( The system Message that goes B<before> the conversation, or an
    B<undefined> Message when every head section was empty. Built once at
    construction. )
method head-message(--> Message) { $!head-message }

#|( The system Message that goes B<after> the conversation — facts, tail
    sections and the two fixed lines — or an B<undefined> Message when
    there were neither facts nor tail sections. Built once at
    construction. )
method tail-message(--> Message) { $!tail-message }

#|( The canonical digest of this whole context: facts and both section
    lists, order included. Equal digests mean equal contexts. )
method digest(--> Str:D) { $!digest }

#|( Every section, head first then tail, as
    C<< { name, digest, rendered } >> — the shape
    L<LLM::Agent::Session>'s C<append-run-context> stores, and what its
    per-section deduplication is keyed on. Copies: poking at what you were
    handed cannot change this context. )
method sections(--> List:D) {
	# NB `.clone`, not `.Hash`: a Hash's `.Hash` is ITSELF, so the copy
	# would be the very record this instance is holding. Everything inside
	# one is a Str, so one level is the whole copy.
	@!sections.map({ $_.clone }).List;
}

#| Just the C<digest> of each of C<.sections>, in the same order.
method section-digests(--> List:D) {
	@!sections.map({ $_<digest> }).List;
}

#|( True when this context would put nothing at all into a request —
    no head message and no tail message. )
method is-empty(--> Bool:D) {
	!($!head-message.defined || $!tail-message.defined);
}

method gist(--> Str:D) {
	"LLM::Agent::RunContext<{$!digest.substr(0, 8)}> {@!facts.elems} facts, "
		~ "{@!head-sections.elems} head, {@!tail-sections.elems} tail"
		~ (self.is-empty ?? ', empty' !! '');
}
