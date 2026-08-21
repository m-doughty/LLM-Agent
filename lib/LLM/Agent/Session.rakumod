=begin pod

=head1 NAME

LLM::Agent::Session - a durable, resumable JSONL transcript of an agent run

=head1 SYNOPSIS

=begin code :lang<raku>

use LLM::Agent::Session;

# A new transcript. The file is created and the meta line written now.
my $session = LLM::Agent::Session.create(
    path => "$*HOME/.local/state/sadna/2026-08-09-refactor.jsonl",
    meta => { agent => 'sadna', model => 'kimi-k2', cwd => $*CWD.Str },
);

# The loop writes every message it is handed that this does not already
# have, in order — so a FIRST run appends nothing itself. (Appending the
# user turn here would put it in the file ahead of the system prompt, and
# the loop refuses a run that contradicts its transcript.)
my $loop = LLM::Agent::Loop.new(:@backends, :$provider, :$session);
await $loop.run([$system, $user-message]).result;

$session.close;

# ... a day later, in a new process:
my $resumed = LLM::Agent::Session.load(path => $path);

my @messages = $resumed.messages;            # Message objects, compaction applied
my $policy   = MCP::Client::Policy.new(      # the human is not asked twice
    :$provider, :&on-ask, grants => $resumed.grants,
);

my $next = user-message('and now the tests');
$resumed.append-message($next);
$loop = LLM::Agent::Loop.new(:@backends, provider => $policy, session => $resumed);
$loop.run([|@messages, $next]);

=end code

=head1 DESCRIPTION

An agent run is long, expensive and interruptible: the process is killed,
the laptop sleeps, the model runs out of context, the human closes the
terminal. A session is the answer to "and then what?" — one append-only
JSONL file that is complete after every line, so a run can be picked up
from wherever it stopped by a different process, on a different day.

It is deliberately B<not> a database and B<not> a cache. It is a
transcript: things that happened, in the order they happened, each as one
self-describing line.

=head2 Durability: one handle, flushed

C<create> and C<load> open the file once, in append mode, and hold a
single C<JSONL::Writer> in handle mode with C<:flush> for the life of the
session. Every C<append-*> writes one line and flushes it to the OS
before returning, so a C<kill -9> one instruction later loses nothing
that a method call had already returned from.

What it deliberately does B<not> do:

=item B<Never> C<JSONL::Editor>, and never path-mode C<write-all>: both
rewrite the file in place, and an in-place rewrite is a window in which a
crash loses the whole transcript rather than the last line. (The crash
repair below B<does> rewrite — into a second file, swapped in by one
atomic rename, which is precisely the window this avoids.)

=item B<No> C<fsync>. The line is out of the process and in the kernel;
surviving a power cut as well as a crash costs a synchronous disk write
per round, which is not a trade a transcript should make for you.

=head2 The envelope

Every line is the same four-key envelope with a per-type payload:

=begin code :lang<json>

{"id":"6f1c...","payload":{...},"ts":"2026-08-09T13:10:08.542283Z","type":"message","v":1}

=end code

=begin table

Key     | Meaning
========|=============================================================
v       | Envelope version. 1. A line with any other version is fatal.
type    | What the payload is; see the types below.
id      | UUID v4, unique per line. Compaction refers to messages by it.
ts      | When it was appended: ISO-8601 UTC, microseconds, C<Z> suffix.
payload | The type's own data.

=end table

The C<ts> format is byte-identical to L<LLM::Agent::Event>'s C<to-hash>,
so an event forwarded to a transcript needs no conversion. Keys are
serialised in sorted order (JSONL's default), which makes two transcripts
of the same run diffable.

=head3 type: session-meta

Always the first line, written by C<create>. The payload is the C<:%meta>
hash exactly as it was given — nothing is added, so whatever an app wants
to know when it finds this file six months later is entirely up to the
app. Read it back with C<.meta>.

=head3 type: message

One committed conversation message.

=begin table

Key          | From
=============|==========================================================
role         | C<$message.role>
content      | C<$message.content>
tool-calls   | C<$message.tool-calls>, when there are any
tool-call-id | C<$message.tool-call-id>, when defined
sticky       | C<$message.sticky>, when True
sysprompt    | C<$message.sysprompt>, when True
depth        | C<$message.depth>, when defined
...          | anything in C<:%extra>

=end table

C<:%extra> is how the loop records the things that are worth reading but
are not part of what gets sent back to a model:

=begin table

Extra         | On           | What it is
==============|==============|=================================================
reasoning     | assistant    | the thinking trace, when the model exposed one
finish-reason | assistant    | how the provider said generation ended ('stop', 'tool_calls', …)
usage         | assistant    | what the provider billed for the turn
is-error      | tool result  | True when the tool answered with a failure

=end table

C<finish-reason> is the provider's own account of why the turn stopped,
kept because a transcript is the only place a truncation nobody caught
can still be seen afterwards. A turn only reaches the transcript once the
loop's clip gate has cleared it (see L<LLM::Agent::Loop>), so the reason
recorded here is one the billed tokens agree with.

They are B<replay-visible> —
C<events> shows them — and B<dropped when rebuilding Messages>, because a
Message has nowhere to put them and inventing somewhere would change what
the next request looks like.

A message key always wins over an extra of the same name: an extra cannot
quietly rewrite the conversation.

=head3 type: grants

The B<whole> grant snapshot as the policy reports it, every time it
changes — not a delta. Last line wins, which makes C<grants> a single
lookup and makes a truncated transcript degrade to an older, smaller set
of permissions rather than a corrupt one. Feed it straight back:
C<< MCP::Client::Policy.new(:$provider, grants => $session.grants) >>.

=head3 type: compaction

The record that turns N earlier messages into one summary: C<summary>,
C<replaces-through-id> (the envelope id of the last message it replaces),
C<tokens-before>, C<tokens-after>, C<fallback> (True when the summarizer
could not be reached and the middle was hard-trimmed instead).

=head3 type: elision

The record that replaces the B<content> of messages already in this
transcript with stubs, and changes nothing else about them:
C<< items => [ { id, stub }, ... ] >>, where C<id> is the envelope id of
the message being stubbed.

This is what L<LLM::Agent::Compactor>'s observation aging produces — old
tool results elided in place rather than summarized away, at a fraction of
the cost and with no risk to C<tool_calls> pairing (see that class's Pod).
The message stays where it is, keeps its role, its C<tool_call_id> and its
stickiness flags, and only its content is lighter.

Unlike a compaction, an elision B<adds and removes nothing>: C<messages>
has the same length afterwards, and C<message-ids> is untouched. It is
therefore the one envelope that rewrites something the file already said,
which is exactly why it names ids rather than positions — and why an id it
cannot resolve is fatal, for the same reason a compaction's
C<replaces-through-id> naming nothing is.

The original result is B<still in the file>, on the C<message> line it was
written on. A transcript is a record of what happened; the elision is a
record of what the model was shown afterwards, and reading the file tells
you both.

=head3 type: tool-dispatched / tool-settled

The two halves of one B<tool operation> (see
L<LLM::Agent::ToolOperation>): the moment a call was prepared for provider
dispatch, and the moment the loop found out — or gave up finding out — what
it did. C<tool-dispatched> does B<not> prove the provider received the call:
the envelope is deliberately durable immediately before the call crosses that
boundary, and a process death between those operations is indistinguishable
from one immediately after it. It therefore means “may have reached the
provider”, never “definitely ran”.

C<tool-dispatched> carries C<call-id> (the model's C<tool_calls> id),
C<tool>, C<arguments> (canonicalised), C<arguments-digest>,
C<idempotency>, C<run-id> and C<round>. B<Its envelope id is the
operation id>, which is what C<tool-settled> names and what a UI joins
on.

C<tool-settled> carries C<op-id>, C<outcome> (C<completed>, C<failed> or
C<outcome-unknown>), and optionally C<reason>, C<duration> (seconds),
C<result-digest>, C<artifact> and C<error>.

C<artifact> — C<< { file, digest, bytes, chars, elided-chars } >> — is
there when the result was too big to live in the conversation and the
full bytes went to a file instead (see L<LLM::Agent::Artifacts>).
C<file> is a B<basename> in the C<< <stem>.artifacts/ >> directory
beside this transcript, never a path, because transcripts get moved. The
C<tool> message holds the excerpt the model actually saw, and
C<result-digest> is over B<that> — so this transcript replays byte for
byte whether or not the artifact still exists.

Neither line is a conversation message, and neither touches C<messages>:
the model's view of a tool call is the C<tool> message the loop writes
beside these, exactly as before. What these add is the B<state> of the
call, which is the thing a C<SIGKILL> can leave in three different
places:

=begin table

What the file has                      | What it means
=======================================|==========================================
an assistant turn, no dispatch line    | never dispatched — it did not run
dispatch, no settle                    | it was running when the process died
dispatch, no settle, but a tool message| it completed and the settle never landed

=end table

That last row is why the loop writes the tool B<message> before the
C<tool-settled> envelope, and the ordering is load-bearing: it is what
makes "completed but unpersisted" a distinguishable state rather than one
that looks exactly like "still running".

An operation may be settled B<once>. A settle naming an operation this
transcript does not have — or one that has already settled — is refused
before the line is written, for the same reason a compaction naming a
message that is not there is.

Applications read the surviving state back with
C<pending-tool-operations> and close it with C<resolve-tool-operation>
(both below); the loop itself writes both lines as it goes.

=head3 type: run-context

What the run was B<told about the world> — the
L<LLM::Agent::RunContext> the loop rendered into the request, one line
per run that had one.

=begin table

Key      | What it is
=========|==========================================================
run-id   | the run this context was rendered for
digest   | the context's own digest; equal digests are equal contexts
facts    | C<< [[key, value], ...] >>, in the order they were rendered
sections | one record per section: C<< { name, digest, rendered? | rendered-in? } >>

=end table

The facts are B<lists, not an object>, because their order is part of what
was rendered and a JSON object has no order to preserve.

A run context is B<not a conversation message> and never becomes one. It
is not in C<messages>, not in C<message-ids>, and a compaction cannot
touch it — which is the whole point of it living out here: the model is
told today's date, today's branch and today's C<AGENTS.md> on every run,
without any of that fossilising in the conversation the seed check locks
down.

=head4 Sections are stored once

The volatile half of a context changes every run, so whole-blob
deduplication would never fire. Per B<section> it fires almost always: an
identity block and a project instruction file are usually the same bytes
for a hundred runs in a row.

So a section carries its C<rendered> text only if B<no earlier
C<run-context> envelope in this transcript> already carries a section with
that digest. Otherwise it carries C<rendered-in>: the envelope id of the
line that does. Two identical sections in one envelope resolve the same
way, the second pointing at its own line.

Read the body back with C<run-context-section($digest)>, which follows the
pointer for you — and which answers with an B<undefined Str> when the
carrying line is not there any more. That is not an error: a crash-tail
repair can have removed it, and a transcript is a conversation first and
an audit trail second. Same posture as a missing artifact file (see
L<LLM::Agent::Artifacts>) — replay never needs either.

=head2 What is NOT stored, and why

=item B<Token deltas.> They are re-derivable from the committed message
and would multiply the file size by the number of fragments.

=item B<Attempt telemetry.> Which backend failed how many times is
operational data with a different lifetime than a conversation; send the
C<AttemptFailed> events to a log.

=item B<The contents of permission questions.> A transcript that recorded
every ask would record what the model was about to do to the user's
files, in a file the user may well paste into a bug report. Only the
resulting grants are kept.

=item B<Forwarded server logs.> Same reason as telemetry.

=item B<Where the file should live.> The caller passes a path. There is
no XDG lookup, no default directory and no filename convention here — an
app owns its own state layout.

=head2 Replay, and the one crash it tolerates

Before it decodes anything, C<load> looks at the end of the file as
B<bytes>. A crash mid-C<say> leaves half a line there, and half a line
can stop in the middle of a multi-byte character — which is a file that
C<.lines> cannot read at all, so anything that turns the file into
C<Str>s first dies before C<:lenient> ever gets a chance.

If that last line is not one whole JSON value, it is B<physically
removed> rather than merely skipped:

=item the good prefix of the file is copied B<verbatim> — byte for byte,
nothing re-serialised, because the part that survived is not this class's
to rewrite — into a C<.repair> file beside it;

=item which is then C<rename>d over the original. The rename is the only
mutation and it is atomic, so a crash during the repair leaves the
original exactly as it was. A leftover C<.repair> file is deleted by the
next C<load>.

The line that went is recorded in C<.warnings>, so an app can say so.
Removing it is the whole point: skipping it in memory and then appending
after it would write the next line I<inside> the garbage — a transcript
that loads, appends and closes without complaint, and then refuses to
load at all.

A malformed line is tolerated B<only> as the very last one. If the line
before it is malformed too, C<load> B<dies> instead of repairing:
healing one line per load would eat a damaged file backwards, a line per
resume, and call the result a conversation. A malformed line anywhere
else means the file has been damaged in a way that no crash produces — a
bad merge, a concurrent writer, a truncated copy — and C<load> dies for
the same reason. Silently skipping it would hand back a conversation
with a hole in it, and the hole would be invisible.

The repair runs before replay, so a transcript that then fails to load
for some other reason has still lost its tail. That tail was garbage
either way, and leaving it there would only mean repairing it on the
load after the one that fixed the real problem.

What replay does B<not> repair is a transcript whose last assistant turn
asked for tools that nothing answered — which is what a C<SIGKILL>
between a tool call being committed and its result arriving leaves
behind. L<LLM::Agent::Loop> closes those off itself when it is
I<cancelled>, so the only way to get one is a process that died outright;
an app that wants to be bulletproof against that should check
C<pending-tool-operations> (and the tail of C<messages>) before resuming.
It is not repaired here because a silent repair is a silent change to a
conversation, and the only honest options — drop the turn or answer it
with a lie — are the app's to choose between. What this class does is
tell the app B<exactly> what state each interrupted call was left in; see
C<pending-tool-operations>.

Blank lines are ignored anywhere. An unknown C<type> is preserved in
C<events> and skipped by C<messages> and C<grants>, so a transcript
written by a newer LLM::Agent still replays as far as this one
understands it. An unknown C<v> is fatal: the envelope itself is the one
thing that cannot be guessed at.

=head2 Reading one without opening it

C<load> is for carrying a conversation on: it repairs the crash tail,
replays every envelope, and keeps an append handle. Two callers want
neither half of that.

=item A B<crash repair> reading a I<child's> transcript to find out
whether the agent that was working when the lights went out ever
finished. It has no business appending to somebody else's file, and a
transcript it cannot parse is a fact to report rather than an exception
to throw.

=item A B<viewer> watching a transcript that is B<still being written>.
Repairing that file would truncate the line its own writer is halfway
through, and a second append handle on one transcript is how a
conversation ends up interleaved with itself.

C<peek> is for those: C<< Session.peek(:$path) >> reads the bytes, parses
what parses, and answers
C<< { path, size, meta, envelopes, messages, warnings, error? } >>
without writing a byte. C<envelopes> is every line that parsed, in the
shape C<events> gives; C<messages> is the C<message> lines as Messages.

B<In file order, with no replay>: a compaction is not applied, an elision
is not applied, and a malformed line is skipped with a warning rather
than being cut off the end of the file. C<load> answers "what would the
model be sent next?"; C<peek> answers "what does this file actually
say?", which is the question a repair and a viewer are both asking.

=head2 How compaction replays

C<messages> is not "every message line". Applying a compaction means:

=item keep every entry up to and including C<replaces-through-id> that is
B<sticky> (C<sticky>, C<sysprompt> or C<depth> — i.e.
C<Message.is-sticky>);

=item splice in one synthetic C<user> message carrying the summary, at
the cut point, under the B<compaction envelope's own id>;

=item keep everything after the cut point untouched.

Later compactions run over that result, so they compose: a compaction may
name a previous compaction's summary as its C<replaces-through-id> and
fold it into the new one. This is exactly the transformation
L<LLM::Agent::Compactor> applies to the live conversation, which is what
makes C<messages> after a resume equal the array the loop was working
with when it stopped.

A compaction whose C<replaces-through-id> names nothing is fatal, for the
same reason a mid-file malformed line is.

=head3 ...and how an elision replays beside it

An C<elision> line replaces the content of the messages its C<items> name,
by B<id>, wherever they are in the conversation as it stands B<at that
point in the file>. Both kinds of envelope are applied in B<file order>,
which is what makes them compose in either direction:

=item an elision, then a compaction: the compaction summarizes a middle
that already holds the stubs, which is precisely what the live run's
summarizer was shown;

=item a compaction, then an elision: the elision may name a message the
compaction kept — including, in principle, the summary itself, which
replays under the compaction envelope's own id.

An elision naming an id the live message set does not have is B<fatal>,
with the same posture and for the same reason as a compaction naming
nothing: the alternative is a resumed conversation that silently differs
from the one the run was working with. Note that this is a statement about
the messages that are B<still there> — an id that a later compaction
replaced is gone, so an elision must be written B<before> it, which is the
order L<LLM::Agent::Loop> writes them in.

=head2 Ids, and why you may want them

C<message-ids> is C<messages>'s parallel list of envelope ids.
L<LLM::Agent::Loop> uses it to keep its own message-to-id map in step
across a resume, so a compaction that happens in the second process can
still name a message the first process wrote. Applications rarely need
it; one that wants to reference a specific turn later does.

=head2 Concurrency

Every method is safe to call from any thread — the file handle, the
writer and the replayed state all live behind one lock. What that does
B<not> buy you is two processes appending to one file: use one session
per file, which is also the only way the ids stay meaningful.

=head1 SEE ALSO

L<LLM::Agent::Loop> (its main writer), L<LLM::Agent::Compactor> (what
produces the compaction lines), L<JSONL::Writer> (the C<:flush> this
leans on).

=end pod

use JSON::Fast;
use JSONL::Line;
use JSONL::Reader;
use JSONL::Writer;
use UUID::V4;

use LLM::Chat::Conversation::Message;

unit class LLM::Agent::Session;

#| The envelope version this class writes, and the only one it reads.
our constant ENVELOPE-VERSION = 1;

#| The types this class understands. Anything else is preserved by
#| C<events> and ignored by the readers.
our constant KNOWN-TYPES =
	<session-meta message grants compaction elision tool-dispatched
		tool-settled run-context>.Set;

#|( The outcomes a C<tool-settled> line may carry. C<outcome-unknown> is
    not an error and never becomes one: see L<LLM::Agent::ToolOperation>. )
our constant TOOL-OUTCOMES = <completed failed outcome-unknown>.Set;

#| The file this transcript lives in. Append-only for its whole life.
has IO::Path:D $.path is required;

has @!warnings;         # the crash tail load cut off, if there was one
has %!meta;
has @!entries;          # replayed, compaction applied: { id, message, sticky }
has @!events;           # every envelope, in file order, untouched
# Tool operations, in file order, deliberately BESIDE @!entries rather
# than in it: a compaction splices the conversation, and an operation is
# not part of the conversation. %!tool-op-index is op-id => position.
has @!tool-ops;
has %!tool-op-index;
# Run contexts, in file order, and BESIDE @!entries for the same reason
# the tool operations are: what a run was told about the world is not a
# turn of the conversation. %!context-sections is section digest =>
# { id, rendered } for the FIRST envelope that carried that body, which is
# both the deduplication index an append consults and the lookup table
# `run-context-section` answers from.
has @!run-contexts;
has %!context-sections;
has $!writer;
has IO::Handle $!fh;
has Bool $!closed = False;
has Lock:D $!lock .= new;

# One replayed message payload back into a Message. Extras are read past:
# a Message has nowhere to put `reasoning` or `usage`, and inventing
# somewhere would change what the next request looks like.
my sub message-from(%payload --> LLM::Chat::Conversation::Message:D) {
	my %args =
		role    => (%payload<role> // 'user').Str,
		content => (%payload<content> // '').Str,
	;
	%args<tool-call-id> = %payload<tool-call-id>.Str
		if %payload<tool-call-id>.defined;
	%args<sticky>       = True if %payload<sticky>;
	%args<sysprompt>    = True if %payload<sysprompt>;
	%args<depth>        = %payload<depth>.Int if %payload<depth>.defined;

	# NB: `tool-calls` is passed at the call site rather than through
	# %args. A list stored in a Hash element is ITEMIZED, and assigning an
	# itemized list to an `@.` attribute makes a one-element array holding
	# the list rather than the array itself — so every tool call would
	# come back one level too deep.
	my @calls = %payload<tool-calls> ~~ Positional
		?? %payload<tool-calls>.list
		!! ();

	LLM::Chat::Conversation::Message.new(|%args, tool-calls => @calls);
}

# What survives a compaction, wherever it sits in the conversation. The
# same predicate LLM::Agent::Compactor uses (`Message.is-sticky`), spelled
# out here because replay works from a payload rather than a Message.
my sub sticky-payload(%payload --> Bool:D) {
	so %payload<sticky> || %payload<sysprompt> || %payload<depth>.defined;
}

# An envelope's payload, as a Hash, whatever nonsense was in the file.
my sub payload-of(%envelope --> Hash:D) {
	(%envelope<payload> ~~ Associative ?? %envelope<payload> !! {}).Hash;
}

# The section records of a run-context payload, as Hashes. Deliberately
# total: a run context is an audit record, and a line some other tool
# wrote with a `sections` that is not a list of objects must not stop a
# transcript loading. Anything unrecognisable is simply not a section.
my sub sections-of(%payload --> List:D) {
	return () unless %payload<sections> ~~ Positional;
	# NB `.clone`, not `.Hash`: a Hash's `.Hash` is ITSELF, so the replayed
	# record would be holding the very hashes the envelope in @!events is,
	# and one of the two would be rewriting the other. Everything inside a
	# section record is a Str, so one level is the whole copy.
	%payload<sections>.list.grep({ $_ ~~ Associative }).map({ $_.clone }).List;
}

# A copy of `value` that shares nothing mutable with the replayed state:
# Associatives and Positionals are recursed into and rebuilt fresh; anything
# else — a Str, an Int, a Bool, Any — is a value already, and handing the
# same one back is not sharing anything. Used wherever a caller is handed a
# nested structure it must not be able to rewrite this session through.
my sub deep-copy(\value) {
	given value {
		when Associative { value.map({ $_.key => deep-copy($_.value) }).Hash }
		when Positional  { value.map({ deep-copy($_) }).List }
		default          { value }
	}
}

# === Reading the file as bytes, for the crash repair ===
#
# Everything here works on a latin-1 rendering of the file: the one
# decoding that cannot fail on any input, and the one that keeps a byte
# and a codepoint the same thing.
#
# A codepoint is not a character, though — Raku joins CR and LF into a
# single grapheme, so `.chars` over a CRLF file is not a count of bytes
# and `.split("\n")` does not find a CRLF at all. Inside ONE LINE there
# is no CR-then-LF by definition, so there `.chars` is exactly the byte
# length, and that is the only place the arithmetic below leans on it.

# The two graphemes a 0x0A byte can be part of.
my constant BREAKS = "\n", "\r\n";

# Where the last line break at or before $limit starts, or -1 for none.
my sub last-break(Str:D $text, Int:D $limit --> Int:D) {
	return -1 if $limit < 0;
	max(BREAKS.map({ $text.rindex($_, $limit) // -1 }));
}

# How many 0x0A bytes the file holds. Each is part of exactly one of the
# two break graphemes, so counting both is counting them — and two
# `split`s are some hundreds of times quicker than a Raku-level walk over
# a few megabytes of Blob.
my sub count-breaks(Str:D $text --> Int:D) {
	BREAKS.map({ $text.split($_).elems - 1 }).sum;
}

# Is this line a line, or is it where a crash stopped? Both steps are
# fallible and both are guarded: a kill mid-character leaves bytes that
# are not UTF-8 at all, so decoding has to be allowed to fail before JSON
# parsing gets a look at it.
my sub line-is-whole(Str:D $line --> Bool:D) {
	# Back to the bytes the line is, and then to what they were meant to
	# be. A lone CR on the end — a last line that never got its LF — rides
	# along, and JSON::Fast reads it as the trailing whitespace it is.
	my $text = try $line.encode('latin-1').decode;
	return False without $text;

	# A blank line is not a malformed one — here or in JSONL::Reader.
	return True unless $text.trim.chars;

	# NB: the `True` is what is being tested, not the parse result. A line
	# of `null` is valid JSON and a hopeless envelope; replay is the one
	# that gets to say so, and it cannot if a repair ate the line first.
	so try { from-json($text); True };
}

# `.new` is deliberately not the way in: a session is either brand new
# (and gets a meta line) or resumed (and gets replayed), and there is no
# third thing. TWEAK cannot tell those apart, so the two class methods do.
submethod TWEAK(:$open = False, *%) {
	die 'LLM::Agent::Session: use .create(:$path, :%meta) or .load(:$path) '
		~ 'rather than .new — a session is either created or resumed'
		unless $open;
}

#|( Start a new transcript at C<$path> and write its C<session-meta> line.

    Refuses a file that already has content: a transcript is append-only,
    and "create" over a real one would either lose it or interleave two
    runs' ids in one file. Use C<load> for that file, or pick another
    path. Missing parent directories are created. )
method create(
	LLM::Agent::Session:U:
	IO(Cool) :$path!,
	:%meta,
	--> LLM::Agent::Session:D
) {
	die "LLM::Agent::Session.create: $path already has content — a "
		~ 'transcript is append-only, so use .load to continue it (or pick '
		~ 'another path)'
		if $path.e && $path.s > 0;

	$path.parent.mkdir unless $path.parent.e;

	my $session = self.bless(:$path, :open);
	$session!open-handle;
	$session!write-meta(%meta);
	$session;
}

#|( Reopen an existing transcript: replay it, then append to it.

    Dies if the file does not exist, if its first line is not a
    C<session-meta> envelope, if any line but the last is malformed, or
    if a compaction names a message that is not there. A malformed final
    line — the one thing a crash mid-write leaves behind — is cut off the
    file before the replay and reported in C<.warnings>. )
method load(
	LLM::Agent::Session:U:
	IO(Cool) :$path!,
	--> LLM::Agent::Session:D
) {
	die "LLM::Agent::Session.load: no transcript at $path"
		unless $path.e && $path.f;

	my $session = self.bless(:$path, :open);
	# The repair comes first, and hands replay the line count it found on
	# the way: nothing after this point has to wonder whether the file
	# ends in a whole line, and nothing reads the file twice to find out.
	$session!replay($session!repair-tail);
	$session!open-handle;
	$session;
}

#|( Look at a transcript B<without touching it>: nothing is repaired,
    nothing is opened for append, and nothing is written. The answer is
    plain data —

    =item C<path> — the C<IO::Path> it was read from.
    =item C<size> — its size in bytes at the moment it was read.
    =item C<meta> — the C<session-meta> payload, or an empty Hash.
    =item C<envelopes> — every line that parsed, in B<file order>, in the
          shape C<events> hands back.
    =item C<messages> — the C<message> lines as Messages, in B<file
          order>.
    =item C<warnings> — one line per line that would not parse.
    =item C<error> — present B<only> when there is nothing to read at
          all: no file, an empty one, or a first line that is not a
          C<session-meta>. The other keys are still there and still safe.

    B<Raw file order, and no replay.> C<messages> here is every message
    line the file holds — a compaction is B<not> applied, an elision is
    B<not> applied, and nothing is refused. That is the difference
    between this and C<load>, and it is the point of it: C<load> answers
    "what would the model be sent next?", and this answers "what does
    this file actually say?".

    B<Never throws>, and tolerant by design. A malformed line is skipped
    with a warning rather than being repaired off the end of the file,
    because the two callers this exists for are precisely the ones that
    must not write: a B<crash repair> reading a dead child's transcript
    to find out whether it finished (see the C<tool-dispatched> taxonomy
    above — the same not-knowing, one layer out), and a B<viewer> on a
    transcript that is still being written, where the half-line at the
    end is the writer mid-append and not damage.

    Use C<load> when you mean to carry the conversation on. Use this when
    you mean to look. )
method peek(
	LLM::Agent::Session:U:
	IO(Cool) :$path!,
	--> Hash:D
) {
	my %read =
		path      => ($path.defined ?? $path.IO !! IO::Path),
		size      => 0,
		meta      => %(),
		envelopes => (),
		messages  => (),
		warnings  => (),
	;

	unless $path.defined && $path.IO.e && $path.IO.f {
		%read<error> = 'there is no transcript at '
			~ ($path.defined ?? $path.Str !! '(nowhere)');
		return %read;
	}

	my @lines;
	my @bad;
	{
		# A file that is deleted, replaced or made unreadable between the
		# test above and the read is an ordinary race with another
		# terminal, not an exception for the caller to handle.
		CATCH {
			default {
				%read<error> = 'the transcript could not be read: '
					~ (.message.lines.head // .^name);
			}
		}
		%read<size> = ($path.IO.s // 0).Int;
		my $reader = JSONL::Reader.new(path => $path.IO, :lenient);
		@lines = $reader.list;
		# Populated only once the lazy Seq has been walked, which the
		# `.list` above has just done.
		@bad = $reader.warnings.list;
	}
	return %read if %read<error>.defined;

	my @envelopes;
	my @messages;
	for @lines -> $line {
		my $value = $line.value;
		# A line that is not a JSON object, or has no type, is not an
		# envelope. `load` dies on one; this is not the reader that gets
		# to decide a file is broken.
		next unless $value ~~ Associative;
		my %envelope = $value.Hash;
		next unless %envelope<type> ~~ Str:D;

		@envelopes.push: %envelope;
		given %envelope<type>.Str {
			when 'session-meta' {
				%read<meta> = payload-of(%envelope) unless %read<meta>.elems;
			}
			when 'message' {
				@messages.push: message-from(payload-of(%envelope));
			}
		}
	}

	%read<envelopes> = @envelopes.List;
	%read<messages>  = @messages.List;
	%read<warnings>  = @bad.map({
		'line ' ~ $_.line-number ~ ' could not be read, and was skipped';
	}).List;

	%read<error> = 'this is not a transcript: its first line is not a '
		~ 'session-meta line'
		unless @envelopes.elems
			&& @envelopes[0]<type>.Str eq 'session-meta';

	%read;
}

# Where the good prefix is staged during a repair. A sibling, so the
# rename that follows stays inside one directory — and therefore inside
# one filesystem, which is what makes it atomic.
method !repair-path(--> IO::Path:D) {
	$!path.sibling($!path.basename ~ '.repair');
}

#|( Take the crash tail off the end of the file, if there is one, and
    hand back how many lines the file has once that is done.

    Byte level throughout, because the damage can be. See the Pod. )
method !repair-tail(--> Int:D) {
	my $repair = self!repair-path;
	# A repair that was itself interrupted before the rename: the original
	# was never touched, so this is nothing but a stale copy of part of it.
	$repair.unlink if $repair.e;

	my $bytes = $!path.slurp(:bin);
	my Int $size = $bytes.elems;
	# Nothing to look at, and nothing to fix: replay says what an empty
	# file is, and it is not a transcript.
	return 0 unless $size;

	my Str $text = $bytes.decode('latin-1');

	# A file that ends in a break has nothing after it — that is what
	# ending in a break MEANS — so the last line is the one before it, and
	# the break itself is the file's final grapheme whether it is one byte
	# or two. Everything else ends in its last line.
	my Bool $ends-broken = $bytes[$size - 1] == 0x0A;
	my Int $count = count-breaks($text) + ($ends-broken ?? 0 !! 1);
	my Int $end   = $text.chars - ($ends-broken ?? 1 !! 0);
	my Int $start = last-break($text, $end - 1) + 1;

	my Str $tail = $text.substr($start, $end - $start);
	if line-is-whole($tail) {
		return $count if $ends-broken;

		# A complete JSON envelope without its trailing line break is valid
		# JSON but not yet append-safe: JSONL::Writer would put the next
		# envelope directly against its closing brace. Stage the exact bytes
		# plus the transcript's established EOL and atomically replace the
		# original before append mode is opened.
		my Int $previous-lf = (^$size).reverse.first({ $bytes[$_] == 0x0A })
			// -1;
		my @eol = $previous-lf > 0 && $bytes[$previous-lf - 1] == 0x0D
			?? (0x0D, 0x0A)
			!! (0x0A,);
		my $mode = $!path.mode;
		$repair.spurt(Buf.new(|$bytes.list, |@eol), :bin);
		$repair.chmod($mode);
		$repair.rename($!path);
		return $count;
	}

	# One malformed line is a crash; two is damage. Repairing a line per
	# load would eat a damaged file backwards, one resume at a time, and
	# hand back the leftovers as a conversation.
	if $start > 0 {
		my Int $before = last-break($text, $start - 2) + 1;
		die "LLM::Agent::Session.load: {$!path} ends in two malformed "
			~ 'lines; only a single malformed FINAL line is tolerated (that '
			~ 'is what a crash mid-write looks like — a second one means the '
			~ 'file was damaged some other way, and repairing one line per '
			~ 'load would walk backwards through the rest)'
			unless line-is-whole($text.substr($before, $start - 1 - $before));
	}

	# What to keep, in BYTES: everything bar the bad line and whatever it
	# managed to get out of its own line break. `$tail.chars` is a byte
	# count because a line holds no CRLF; the break at the end of the file
	# is two bytes when it IS a CRLF and one when it is not.
	my Int $break = 0;
	if $ends-broken {
		$break = $size > 1 && $bytes[$size - 2] == 0x0D ?? 2 !! 1;
	}
	my Int $keep = $size - $tail.chars - $break;

	my $mode = $!path.mode;
	# Byte for byte, no re-serialisation: the part of the file that
	# survived is not this class's to rewrite.
	$repair.spurt($bytes.subbuf(0, $keep), :bin);
	# The replacement inherits the transcript's permissions rather than
	# the umask's: a transcript is somebody's conversation.
	$repair.chmod($mode);
	$repair.rename($!path);

	@!warnings.push: JSONL::Line.new(
		# utf8-c8 so the raw text is reportable even when the crash landed
		# in the middle of a character; the bytes round-trip through it.
		value       => $tail.encode('latin-1').decode('utf8-c8'),
		line-number => $count,
	);

	# The line the warning names is the one that is no longer there.
	$count - 1;
}

method !open-handle(--> Nil) {
	# JSONL::Writer turns the handle's newline translation off, so an
	# appended envelope ends in exactly one 0x0A byte on every platform —
	# Windows' default translation would append CRLF envelopes, silently
	# flipping the transcript's separator convention (the
	# repaired-separator contract t/08 pins).
	$!fh = $!path.open(:a);
	# Handle mode plus :flush, for the session's whole life. See the Pod:
	# path mode reopens the file per call, and its write-all rewrites it.
	$!writer = JSONL::Writer.new(handle => $!fh, :flush);
	Nil;
}

method !write-meta(%meta --> Nil) {
	self!append('session-meta', %meta.Hash);
	Nil;
}

#|( The one place a line is written: validate, write, then commit.

    An envelope that cannot be applied — a compaction naming a message
    that is not there — is refused B<before> the write, so it leaves no
    line behind to be replayed into the same error next time.

    Nothing in memory moves until the line is on disk. A write that fails
    (the disk filled up, the handle went away) therefore leaves the
    replayed state exactly where it was, rather than one message ahead of
    its own file and out of step with C<events>. A write that half-lands
    is a crash tail, and the next C<load> repairs it.

    C<:$id> exists for the one payload that has to know its own envelope
    id B<before> the line is built: a C<run-context> section that
    back-points at a body carried earlier in the very same envelope. )
method !append(Str:D $type, %payload, Str:D :$id = uuid-v4 --> Str:D) {
	my %envelope =
		v       => ENVELOPE-VERSION,
		type    => $type,
		id      => $id,
		ts      => DateTime.new(now, :timezone(0)).Str,
		payload => %payload,
	;

	$!lock.protect: {
		die 'LLM::Agent::Session: the session is closed'
			if $!closed;
		self!validate(%envelope);
		$!writer.append(%envelope);
		self!apply(%envelope);
		@!events.push: %envelope;
	};

	$id;
}

# === Appending ===

#|( Record one committed conversation message and return its envelope id.

    C<:%extra> carries whatever is worth keeping but is not part of the
    message a model sees — C<reasoning>, C<usage>, C<is-error>. Extras
    never overwrite the message's own keys. )
method append-message(
	LLM::Chat::Conversation::Message:D $message,
	:%extra,
	--> Str:D
) {
	my %payload = %extra.Hash;

	%payload<role>    = $message.role.Str;
	%payload<content> = $message.content // '';

	my @calls = $message.tool-calls.list;
	%payload<tool-calls>   = @calls.List if @calls.elems;
	%payload<tool-call-id> = $message.tool-call-id if $message.tool-call-id.defined;
	%payload<sticky>       = True if $message.sticky;
	%payload<sysprompt>    = True if $message.sysprompt;
	%payload<depth>        = $message.depth if $message.depth.defined;

	self!append('message', %payload);
}

#|( Record the whole grant snapshot. Not a delta — see the Pod. Returns
    the envelope id. )
method append-grants(@grants --> Str:D) {
	self!append('grants', %(
		grants => @grants.map({ $_ ~~ Associative ?? $_.Hash !! $_ }).List,
	));
}

#|( Record that everything up to and including C<$replaces-through-id>
    has been replaced by C<$summary>. Returns the envelope id, which is
    also the id the synthetic summary message replays under. )
method append-compaction(
	Str:D :$summary!,
	Str:D :$replaces-through-id!,
	Int :$tokens-before,
	Int :$tokens-after,
	Bool :$fallback = False,
	--> Str:D
) {
	my %payload =
		summary               => $summary,
		'replaces-through-id' => $replaces-through-id,
		fallback              => $fallback,
	;
	%payload<tokens-before> = $tokens-before if $tokens-before.defined;
	%payload<tokens-after>  = $tokens-after  if $tokens-after.defined;

	self!append('compaction', %payload);
}

#|( Record that the B<content> of messages already in this transcript has
    been replaced by stubs — L<LLM::Agent::Compactor>'s observation aging.
    Returns the envelope id.

    C<@items> is a list of C<< { id, stub } >> hashes, where C<id> is the
    envelope id of the message being stubbed: exactly what
    C<< %result<elisions> >> becomes once a caller has turned its indices
    into ids. Nothing but the content changes — the message keeps its
    place, its role, its C<tool_call_id> and its stickiness.

    Refused, B<before anything is written>, if an item is not a
    C<< { id, stub } >> pair or if its id is not a message this transcript
    still has: an elision that cannot be applied on replay would make a
    resumed conversation silently differ from the one the run had. An empty
    C<@items> is refused too — a line that changes nothing is not worth the
    bytes, and an aging pass that elided nothing should not be writing one. )
method append-elision(:@items! --> Str:D) {
	die 'LLM::Agent::Session.append-elision: items cannot be empty — an '
		~ 'elision that stubs nothing changes nothing'
		unless @items.elems;

	self!append('elision', %(
		items => @items.map(-> $item {
			die 'LLM::Agent::Session.append-elision: every item is a '
				~ '{ id, stub } hash; got a ' ~ $item.^name
				unless $item ~~ Associative;
			%(
				id   => ($item<id> // '').Str,
				stub => ($item<stub> // '').Str,
			);
		}).List,
	));
}

#|( Record that a tool call has been handed to the provider, and return
    the envelope id — which B<is> the operation id, and is what
    C<append-tool-settled> names later.

    C<$arguments> is the canonicalised argument document (a Str, or a Hash
    for a provider that hands them over decoded), not the model's wire
    text: it is a comparison key, and key order and whitespace are not
    semantics. C<$idempotency> is one of the
    L<LLM::Agent::ToolOperation> classes; it is B<configuration>, recorded
    so a repair can word itself honestly, and nothing here or in the loop
    ever retries on the strength of it. )
method append-tool-dispatched(
	Str:D :$call-id!,
	Str:D :$tool!,
	:$arguments!,
	Str :$arguments-digest,
	Str :$idempotency,
	Str :$run-id,
	Int :$round,
	--> Str:D
) {
	my %payload =
		'call-id' => $call-id,
		tool      => $tool,
		arguments => ($arguments ~~ Associative
			?? $arguments.Hash
			!! ($arguments // '').Str),
	;
	%payload<arguments-digest> = $arguments-digest if $arguments-digest.defined;
	%payload<idempotency>      = $idempotency if $idempotency.defined;
	%payload<run-id>           = $run-id if $run-id.defined;
	%payload<round>            = $round if $round.defined;

	self!append('tool-dispatched', %payload);
}

#|( Record what became of the operation C<$op-id> names. Returns the
    envelope id of the settle line.

    C<$outcome> is C<completed>, C<failed> or C<outcome-unknown> —
    B<never> a downgrade of the third to the second: a deadline, a cancel
    or a crash says nothing about whether the remote side effect happened.

    Refused, before anything is written, if C<$op-id> is not an operation
    this transcript dispatched or is one that has already been settled. )
method append-tool-settled(
	Str:D :$op-id!,
	Str:D :$outcome!,
	Str :$reason,
	Real :$duration,
	Str :$result-digest,
	:%artifact,
	Str :$error,
	--> Str:D
) {
	# Checked here rather than as a `where` on the parameter: a constraint
	# failure reports "Constraint type check failed", and this is a value an
	# application can get wrong.
	die 'LLM::Agent::Session.append-tool-settled: outcome must be one of '
		~ TOOL-OUTCOMES.keys.sort.join(', ') ~ "; got '$outcome'"
		unless TOOL-OUTCOMES{$outcome};

	my %payload = 'op-id' => $op-id, outcome => $outcome;
	%payload<reason>        = $reason if $reason.defined;
	%payload<result-digest> = $result-digest if $result-digest.defined;
	%payload<error>         = $error if $error.defined;
	%payload<artifact>      = %artifact.Hash if %artifact.elems;
	# Rounded to microseconds so two transcripts of the same run stay
	# diffable rather than differing in the eighteenth decimal place.
	%payload<duration>      = ($duration * 1_000_000).round / 1_000_000
		if $duration.defined;

	self!append('tool-settled', %payload);
}

#|( Every tool operation this transcript dispatched and never settled, in
    file order, as plain data — C<< { op-id, call-id, tool, arguments,
    arguments-digest?, idempotency?, run-id?, round?, dispatched-at } >>.

    This is the SIGKILL taxonomy's middle row, and the answer to "what was
    in flight when the lights went out". An app resuming a transcript
    should settle each of these (C<resolve-tool-operation>) with what it
    can honestly say — normally C<outcome-unknown> — and, where the
    conversation has no C<tool> message answering the call, write one
    saying so. B<Empty for every transcript written before 0.2>, which is
    exactly what makes an older transcript fall through to whatever
    heuristic an app used before these lines existed.

    Each record is the caller's B<outright>, nested values included:
    poking at what you were handed cannot change what this session
    replays. )
method pending-tool-operations(--> List:D) {
	$!lock.protect: {
		@!tool-ops.grep({ !$_<settled> }).map({ op-record($_) }).List;
	};
}

#|( One operation record as data the caller owns B<outright>.

    Two of these values can be nested structures that C<@!entries>'
    neighbours — the envelopes in C<@!events> — are holding as well:
    C<arguments>, when a provider handed them over decoded rather than as
    wire text, and C<artifact>, when the result was too big to live in
    the conversation. Both are copied a level deeper than the record
    itself, because a caller poking at what it was handed must not be
    able to rewrite this session's replayed state — and one level is all
    it takes: everything inside them is plain scalars. )
my sub op-record(%op --> Hash:D) {
	# NB `.clone`, not `.Hash`: a Hash's `.Hash` is ITSELF, so `.Hash` on
	# something that is already one copies nothing at all. (The assignment
	# below is what copies the outer level — `my %copy = ...` really does
	# build a new hash — which is precisely why the inner ones need saying
	# out loud.)
	my %copy = %op;
	%copy<arguments> = %op<arguments>.clone if %op<arguments> ~~ Associative;
	%copy<artifact>  = %op<artifact>.clone  if %op<artifact> ~~ Associative;
	%copy;
}

#|( Settle one operation by id: a thin delegate to
    C<append-tool-settled>, for the repair path that has a pending record
    in its hand rather than a live operation. Same refusals. )
method resolve-tool-operation(
	Str:D $op-id,
	Str:D :$outcome!,
	Str :$reason,
	--> Str:D
) {
	self.append-tool-settled(:$op-id, :$outcome, :$reason);
}

#|( Record the runtime context a run was rendered with — the facts and
    section blocks of an L<LLM::Agent::RunContext> — and return the
    envelope id. The loop writes one of these per run that was given a
    context; an app that renders its own context can write its own.

    C<@facts> is a list of C<< key => value >> Pairs (or of two-element
    lists), B<in render order>, and C<@sections> a list of
    C<< { name, digest, rendered } >> hashes — which is exactly what
    C<< $context.facts >> and C<< $context.sections >> hand back.

    A section body that this transcript already holds is B<not written
    again>: the record back-points at the line that carries it. See the
    module Pod, and C<run-context-section> for reading one back. )
method append-run-context(
	Str:D :$run-id!,
	Str:D :$digest!,
	:@facts,
	:@sections,
	--> Str:D
) {
	die 'LLM::Agent::Session.append-run-context: run-id cannot be empty — a '
		~ 'context is recorded for a run, and a line that cannot say which '
		~ 'one is not worth the bytes'
		unless $run-id.trim.chars;
	die 'LLM::Agent::Session.append-run-context: digest cannot be empty — it '
		~ 'is what makes two runs comparable'
		unless $digest.trim.chars;

	my @rows    = @facts.kv.map(-> Int $index, $fact { fact-row($fact, $index) }).List;
	my @records = @sections.kv.map(
		-> Int $index, $section { section-record($section, $index) }
	).List;

	# The id up front: a second section with a body the FIRST one in this
	# same envelope carries has to name this line, and `!append` would
	# otherwise not have made one yet.
	my Str $id = uuid-v4;

	# One protected section over the deduplication and the append, so the
	# index a payload was built against is the index the write lands
	# beside. (Raku's Lock is reentrant, which is what lets `!append` take
	# it again from in here.)
	$!lock.protect: {
		my %payload =
			'run-id' => $run-id,
			digest   => $digest,
			facts    => @rows,
			sections => self!dedup-sections(@records, $id),
		;
		self!append('run-context', %payload, :$id);
	};
}

# One incoming fact, as the [key, value] row the payload stores. Pairs
# are what LLM::Agent::RunContext hands over; a two-element list is
# accepted as well, so a record read back out of a transcript can be
# written to another one without being turned back into Pairs first.
my sub fact-row($fact, Int:D $index --> List:D) {
	return ($fact.key.Str, ($fact.value // '').Str).List if $fact ~~ Pair;

	if $fact ~~ Positional && $fact.elems == 2 {
		return ($fact[0].Str, ($fact[1] // '').Str).List;
	}

	die "LLM::Agent::Session.append-run-context: fact $index is a "
		~ $fact.^name ~ '; a fact is a key => value Pair (or a two-element '
		~ 'list), because the ORDER of the facts is part of what was '
		~ 'rendered and a Hash has none';
}

# One incoming section, checked. `rendered` may be the empty string — a
# section that was there and had nothing to say is a fact about the run —
# but it may not be missing: without it there is no body to store or to
# point at.
my sub section-record($section, Int:D $index --> Hash:D) {
	die "LLM::Agent::Session.append-run-context: section $index is a "
		~ $section.^name ~ '; a section is a { name, digest, rendered } hash'
		unless $section ~~ Associative;

	for <name digest rendered> -> $key {
		die "LLM::Agent::Session.append-run-context: section $index has no "
			~ "$key"
			unless $section{$key} ~~ Str:D
				&& ($key eq 'rendered' || $section{$key}.trim.chars);
	}

	%(
		name     => $section<name>.Str,
		digest   => $section<digest>.Str,
		rendered => $section<rendered>.Str,
	);
}

# The section records as they go into the payload: the body where this
# transcript does not have one already, a back-pointer where it does.
# MUST be called with $!lock held.
method !dedup-sections(@records, Str:D $id --> List:D) {
	# Bodies this envelope is itself about to carry, so the second of two
	# identical sections on one line points at that line rather than
	# repeating it.
	my %carried;

	@records.map(-> %record {
		my Str $digest = %record<digest>;
		my %out = name => %record<name>, :$digest;

		my $carrier = (%!context-sections{$digest}:exists)
			?? %!context-sections{$digest}<id>
			!! %carried{$digest};

		if $carrier.defined {
			%out<rendered-in> = $carrier;
		}
		else {
			%out<rendered> = %record<rendered>;
			%carried{$digest} = $id;
		}
		%out;
	}).List;
}

#|( The escape hatch: write a line of your own type. It is preserved by
    C<events> and ignored by C<messages> and C<grants>, both here and in
    every older LLM::Agent that reads the file.

    The built-in types are refused — going through the typed appender is
    what keeps their payloads in shape. )
method append-event(Str:D :$type!, :%payload --> Str:D) {
	die 'LLM::Agent::Session.append-event: a type cannot be empty'
		unless $type.trim.chars;
	die "LLM::Agent::Session.append-event: '$type' is a built-in type; use "
		~ 'the matching append-* method so its payload stays well-formed'
		if KNOWN-TYPES{$type};

	self!append($type, %payload.Hash);
}

# === Replay ===

method !replay(Int:D $total --> Nil) {
	my $reader = JSONL::Reader.new(path => $!path, :lenient);
	my @lines = $reader.list;

	# `.warnings` is only populated once the lazy Seq has been walked,
	# which the `.list` above has just done.
	my @bad = $reader.warnings.list;

	# The crash tail is gone before replay starts (see !repair-tail), and
	# a blank line is not a malformed one, so anything the reader is still
	# unhappy about is a hole in the MIDDLE of the file.
	if @bad.elems {
		die "LLM::Agent::Session.load: {$!path} has {@bad.elems} malformed "
			~ 'lines; only a single malformed FINAL line is tolerated (that '
			~ 'is what a crash mid-write looks like — anything else means '
			~ 'the file was damaged, and replaying it would hand back a '
			~ 'conversation with an invisible hole in it)'
			if @bad.elems > 1;

		die "LLM::Agent::Session.load: {$!path} has a malformed line at line "
			~ "{@bad[0].line-number} of $total; only a malformed FINAL line "
			~ 'is tolerated (see above)';
	}

	die "LLM::Agent::Session.load: {$!path} is empty — a transcript starts "
		~ 'with a session-meta line'
		unless @lines.elems;

	for @lines.kv -> $index, $line {
		my $value = $line.value;
		die "LLM::Agent::Session.load: line {$line.line-number} of {$!path} "
			~ 'is not a JSON object'
			unless $value ~~ Associative;

		my %envelope = $value.Hash;
		my $v = %envelope<v>;
		die "LLM::Agent::Session.load: line {$line.line-number} of {$!path} "
			~ "has envelope version {$v // 'none'}; this LLM::Agent reads "
			~ "version {ENVELOPE-VERSION}"
			unless $v.defined && $v == ENVELOPE-VERSION;

		die "LLM::Agent::Session.load: line {$line.line-number} of {$!path} "
			~ 'has no type'
			unless %envelope<type> ~~ Str:D;

		die "LLM::Agent::Session.load: the first line of {$!path} is a "
			~ "'{%envelope<type>}' line; a transcript starts with session-meta"
			if $index == 0 && %envelope<type> ne 'session-meta';

		self!validate(%envelope, line-number => $line.line-number);
		self!apply(%envelope);
		@!events.push: %envelope;
	}

	Nil;
}

# Everything that can refuse an envelope, and nothing that changes
# anything. `!append` runs this before the line is written; `!replay` runs
# it just before applying, where the line number makes a better error.
method !validate(%envelope, Int :$line-number --> Nil) {
	if %envelope<type> eq 'compaction' {
		self!compaction-cut(%envelope, payload-of(%envelope), :$line-number);
	}
	if %envelope<type> eq 'elision' {
		self!elision-targets(%envelope, payload-of(%envelope), :$line-number);
	}
	if %envelope<type> eq 'tool-settled' {
		self!settle-target(%envelope, payload-of(%envelope), :$line-number);
	}
	Nil;
}

# Fold one envelope into the replayed state. Shared by load and by every
# append, so a live session and a resumed one hold the same thing.
#
# Nothing here refuses an envelope: `!validate` has already run — in
# `!append` before the write, in `!replay` a line earlier. That is what
# lets an append go validate → write → apply, so a write that fails
# leaves the replayed state precisely where it was.
method !apply(%envelope --> Nil) {
	my %payload = payload-of(%envelope);

	given %envelope<type> {
		when 'session-meta' {
			%!meta = %payload;
		}
		when 'message' {
			@!entries.push: %(
				id      => %envelope<id>.Str,
				message => message-from(%payload),
				sticky  => sticky-payload(%payload),
			);
		}
		when 'compaction' {
			self!apply-compaction(%envelope, %payload);
		}
		when 'elision' {
			# `!validate` has already proved every id resolves — in
			# `!append` before the write, in `!replay` a line earlier.
			#
			# `.clone`, not a rebuilt Message: an elision changes the
			# content and NOTHING else, and cloning is the only version of
			# that sentence which stays true when LLM::Chat's Message grows
			# an attribute. The checksum is cleared because it is a memo of
			# the content that has just gone.
			for self!elision-targets(%envelope, %payload).list -> %target {
				@!entries[%target<index>]<message> =
					@!entries[%target<index>]<message>.clone(
						content => %target<stub>, checksum => Str,
					);
			}
		}
		when 'tool-dispatched' {
			# Into %!tool-ops, never into @!entries: an operation is not a
			# conversation message, and a compaction that spliced one out
			# would lose the record of a side effect that really happened.
			my %op =
				'op-id'         => %envelope<id>.Str,
				'call-id'       => (%payload<call-id> // '').Str,
				tool            => (%payload<tool> // '').Str,
				arguments       => %payload<arguments>,
				'dispatched-at' => (%envelope<ts> // '').Str,
				settled         => False,
			;
			for <arguments-digest idempotency run-id round> -> $key {
				%op{$key} = %payload{$key} if %payload{$key}.defined;
			}
			%!tool-op-index{%op<op-id>} = @!tool-ops.elems;
			@!tool-ops.push: %op;
		}
		when 'tool-settled' {
			# `!validate` has already proved this resolves, in `!append`
			# before the write and in `!replay` a line earlier.
			my Int $index = self!settle-target(%envelope, %payload);
			@!tool-ops[$index]<settled>    = True;
			@!tool-ops[$index]<outcome>    = (%payload<outcome> // '').Str;
			@!tool-ops[$index]<settled-at> = (%envelope<ts> // '').Str;
			@!tool-ops[$index]<settle-id>  = %envelope<id>.Str;
			for <reason duration result-digest error artifact> -> $key {
				@!tool-ops[$index]{$key} = %payload{$key}
					if %payload{$key}.defined;
			}
		}
		when 'run-context' {
			# Beside @!entries, never in it — the same rule the tool
			# operations follow, for a stronger reason: a run context was
			# never a conversation message, and letting a compaction splice
			# one would delete the record of what an agent was told.
			my Str $envelope-id = %envelope<id>.Str;
			my @sections = sections-of(%payload);

			@!run-contexts.push: %(
				id       => $envelope-id,
				ts       => (%envelope<ts> // '').Str,
				'run-id' => (%payload<run-id> // '').Str,
				digest   => (%payload<digest> // '').Str,
				facts    => (%payload<facts> ~~ Positional
					?? %payload<facts>.list.grep({ $_ ~~ Positional }).map({ $_.list.List }).List
					!! ()),
				sections => @sections,
			);

			# The body index, first carrier wins — which is the same rule
			# `!dedup-sections` writes by, so a transcript replayed in
			# another process resolves every pointer exactly as the process
			# that wrote it would have.
			for @sections -> %section {
				my $digest = %section<digest>;
				next unless $digest ~~ Str:D && $digest.chars;
				next unless %section<rendered> ~~ Str:D;
				next if %!context-sections{$digest}:exists;
				%!context-sections{$digest} = %(
					id => $envelope-id, rendered => %section<rendered>.Str,
				);
			}
		}
		when 'grants' {
			# Nothing to fold: `grants` reads the last snapshot straight
			# out of @!events, which is where "last one wins" comes from.
		}
		default {
			# An unknown type is data somebody else understands.
		}
	}

	Nil;
}

# Where a compaction cuts the conversation — or a death saying why it
# cannot. The one place that decision is made, so `!validate` and the
# splice below can never disagree about it.
method !compaction-cut(%envelope, %payload, Int :$line-number --> Int:D) {
	my $through = %payload<replaces-through-id>;
	my $where = $line-number.defined
		?? "line $line-number of {$!path}"
		!! 'this session';

	die "LLM::Agent::Session: the compaction at $where has no "
		~ 'replaces-through-id'
		unless $through ~~ Str:D;

	my $cut = @!entries.first({ $_<id> eq $through }, :k);
	die "LLM::Agent::Session: the compaction at $where replaces through "
		~ "'$through', which is not a message this transcript still has — "
		~ 'either the id was never written, or it was written after the '
		~ 'compaction that claims to replace it'
		unless $cut.defined;

	$cut;
}

#|( Which entries an C<elision> line stubs, as
    C<< [ { index, stub }, ... ] >> — or a death saying why it stubs
    nothing. The C<!compaction-cut> precedent again: one place decides,
    so C<!validate> and the fold in C<!apply> can never disagree about
    whether an elision is legal.

    An id that is not in the live message set is fatal. Structurally
    unrecognisable C<items> are fatal too, but an B<empty> list is not: the
    appender refuses one, and a line some other tool wrote with nothing in
    it applies nothing — the same posture the rest of replay takes towards
    payload shape. )
method !elision-targets(%envelope, %payload, Int :$line-number --> List:D) {
	my $where = $line-number.defined
		?? "line $line-number of {$!path}"
		!! 'this session';

	my $items = %payload<items>;
	die "LLM::Agent::Session: the elision at $where has no items list"
		unless $items ~~ Positional;

	$items.list.kv.map(-> Int $position, $item {
		die "LLM::Agent::Session: item $position of the elision at $where is "
			~ 'not a { id, stub } object'
			unless $item ~~ Associative;

		my $id = $item<id>;
		die "LLM::Agent::Session: item $position of the elision at $where has "
			~ 'no id'
			unless $id ~~ Str:D && $id.chars;

		die "LLM::Agent::Session: item $position of the elision at $where has "
			~ 'no stub'
			unless $item<stub> ~~ Str:D;

		my $index = @!entries.first({ $_<id> eq $id }, :k);
		die "LLM::Agent::Session: the elision at $where stubs '$id', which is "
			~ 'not a message this transcript still has — either the id was '
			~ 'never written, or a compaction replaced it before this line '
			~ 'claimed to rewrite it'
			unless $index.defined;

		%( index => $index, stub => $item<stub>.Str );
	}).eager.List;
}

#|( Which tool operation a C<tool-settled> line settles — or a death
    saying why it settles none. The compaction-cut precedent: one place
    decides, so C<!validate> and the fold in C<!apply> can never disagree
    about whether a settle is legal.

    Two refusals, and both are the same kind of refusal a compaction
    naming a missing message gets. A settle for an operation this
    transcript never dispatched describes something that did not happen
    here; a B<second> settle for one operation would mean the transcript
    holds two different accounts of the same side effect, and there is no
    honest way to choose between them. )
method !settle-target(%envelope, %payload, Int :$line-number --> Int:D) {
	my $where = $line-number.defined
		?? "line $line-number of {$!path}"
		!! 'this session';

	my $op-id = %payload<op-id>;
	die "LLM::Agent::Session: the tool-settled line at $where has no op-id"
		unless $op-id ~~ Str:D && $op-id.chars;

	my $outcome = %payload<outcome>;
	die "LLM::Agent::Session: the tool-settled line at $where has outcome "
		~ "'{$outcome // 'none'}'; a settled operation is one of "
		~ TOOL-OUTCOMES.keys.sort.join(', ')
		unless $outcome ~~ Str:D && TOOL-OUTCOMES{$outcome};

	my $index = %!tool-op-index{$op-id};
	die "LLM::Agent::Session: the tool-settled line at $where settles "
		~ "'$op-id', which is not an operation this transcript dispatched — "
		~ 'either the id was never written, or it was written after the '
		~ 'settle that claims to close it'
		unless $index.defined;

	die "LLM::Agent::Session: the tool-settled line at $where settles "
		~ "'$op-id', which was settled already — one operation, one outcome; "
		~ 'two accounts of the same side effect cannot both be believed'
		if @!tool-ops[$index]<settled>;

	$index;
}

method !apply-compaction(%envelope, %payload --> Nil) {
	my Int $cut = self!compaction-cut(%envelope, %payload);

	my @kept = @!entries[0 .. $cut].grep({ $_<sticky> });
	@kept.push: %(
		id      => %envelope<id>.Str,
		message => LLM::Chat::Conversation::Message.new(
			role    => 'user',
			content => (%payload<summary> // '').Str,
		),
		sticky  => False,
	);
	@kept.append: @!entries[$cut + 1 .. *-1] if $cut + 1 < @!entries.elems;

	@!entries = @kept;
	Nil;
}

# === Reading ===

#|( The lines that were dropped on load: at most one, and only ever the
    final line of a file a crash caught mid-write. Each is a
    C<JSONL::Line> carrying the raw text and its 1-based line number.

    The line is no longer in the file by the time this can be read — the
    repair happens during C<load>. This is the record of it. )
method warnings(--> List:D) {
	$!lock.protect: { @!warnings.List };
}

#| The C<:%meta> C<create> was given, as a copy.
method meta(--> Hash:D) {
	$!lock.protect: { %!meta.Hash };
}

#|( The live conversation: every message line, with every compaction
    applied, as C<Message> objects. This is what to hand back to
    C<Loop.run> after a resume. )
method messages(--> List:D) {
	$!lock.protect: { @!entries.map({ $_<message> }).List };
}

#|( The envelope ids of C<messages>, in the same order. A synthetic
    summary carries the id of the compaction that created it. )
method message-ids(--> List:D) {
	$!lock.protect: { @!entries.map({ $_<id>.Str }).List };
}

#|( Every C<run-context> line, in file order, as
    C<< { id, ts, run-id, digest, facts, sections } >> — the payload plus
    the envelope's own id and timestamp.

    C<facts> is a list of C<< (key, value) >> lists in render order, and
    C<sections> a list of C<< { name, digest, rendered? | rendered-in? } >>
    hashes; a section that back-points is resolved with
    C<run-context-section>. Each record is the caller's B<outright>,
    nested values included. )
method run-contexts(--> List:D) {
	$!lock.protect: { @!run-contexts.map({ deep-copy($_) }).List };
}

#|( The most recent C<run-context> line, in the shape C<run-contexts>
    uses, or an B<empty Hash> when this transcript has none — which is
    every transcript written before 0.3, and every run that was given no
    context.

    This is what an app compares against when it wants to know whether the
    world has moved since the last run: same cwd, same branch, same
    commit? )
method last-run-context(--> Hash:D) {
	$!lock.protect: {
		@!run-contexts.elems ?? deep-copy(@!run-contexts.tail).Hash !! %();
	};
}

#|( The rendered body of the context section with this digest, wherever in
    the transcript it was stored — or an B<undefined Str> when this
    transcript does not hold it.

    It never dies, and the undefined answer is a real one: a section is
    written once and back-pointed to afterwards, so a crash-tail repair
    that removed the carrying line leaves later records naming a body that
    is genuinely no longer here. A transcript is a conversation first and
    an audit trail second — replay never needs this, exactly as it never
    needs an artifact file to exist. )
method run-context-section(Str:D $digest --> Str) {
	$!lock.protect: {
		# NB the ternary rather than an early `return`: leaving a method
		# from inside somebody else's Callable throws a control exception
		# through a lock this class does not own the unwinding of.
		(%!context-sections{$digest}:exists)
			?? %!context-sections{$digest}<rendered>.Str
			!! Str;
	};
}

#|( The most recent grant snapshot, or the empty list. Feed it straight
    to C<< MCP::Client::Policy.new(grants => ...) >>. )
method grants(--> List:D) {
	$!lock.protect: {
		my $last = @!events.reverse.first({ $_<type> eq 'grants' });
		my $grants = $last.defined ?? $last<payload><grants> !! Nil;
		($grants ~~ Positional ?? $grants.list !! ()).List;
	};
}

#|( Every envelope in the file, in order, including types this class does
    not understand. Plain data, as a copy — nested payload values included,
    so mutating what you were handed cannot reach the replayed state. )
method events(--> List:D) {
	$!lock.protect: {
		@!events.map({
			my %copy = $_;
			%copy<payload> = deep-copy(%copy<payload>) if %copy<payload>.defined;
			%copy;
		}).List;
	};
}

#| How many lines this transcript has.
method elems(--> Int:D) {
	$!lock.protect: { @!events.elems };
}

#|( Close the file handle. Idempotent. The replayed state stays readable
    afterwards; only appending is refused. )
method close(--> Nil) {
	$!lock.protect: {
		unless $!closed {
			$!closed = True;
			$!fh.close if $!fh.defined;
			$!fh = IO::Handle;
		}
	};
	Nil;
}

method gist(--> Str:D) {
	$!lock.protect: {
		"LLM::Agent::Session<{$!path}> {@!events.elems} lines, "
			~ "{@!entries.elems} messages" ~ ($!closed ?? ', closed' !! '');
	};
}
