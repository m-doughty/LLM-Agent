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
rewrite the file, and a rewrite is a window in which a crash loses the
whole transcript rather than the last line.

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
type    | What the payload is; see the four types below.
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
are not part of what gets sent back to a model: C<reasoning> (the
thinking trace), C<usage> (what the provider billed for the turn),
C<is-error> (a tool result that failed). They are B<replay-visible> —
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

C<load> reads the file with C<JSONL::Reader>'s C<:lenient> mode and then
applies a stricter rule of its own: a malformed line is tolerated B<only
as the very last line of the file>, where it is exactly what a crash
mid-C<say> looks like. It is dropped, and recorded in C<.warnings> so an
app can say so.

A malformed line anywhere else means the file has been damaged in a way
that no crash produces — a bad merge, a concurrent writer, a truncated
copy — and C<load> B<dies>. Silently skipping it would hand back a
conversation with a hole in it, and the hole would be invisible.

What replay does B<not> repair is a transcript whose last assistant turn
asked for tools that nothing answered — which is what a C<SIGKILL>
between a tool call being committed and its result arriving leaves
behind. L<LLM::Agent::Loop> closes those off itself when it is
I<cancelled>, so the only way to get one is a process that died outright;
an app that wants to be bulletproof against that should check the tail of
C<messages> before resuming (an assistant message with C<tool-calls> and
no C<tool> messages after it) and drop it. It is not repaired here
because a silent repair is a silent change to a conversation, and the
only honest options — drop the turn or answer it with a lie — are the
app's to choose between.

Blank lines are ignored anywhere. An unknown C<type> is preserved in
C<events> and skipped by C<messages> and C<grants>, so a transcript
written by a newer LLM::Agent still replays as far as this one
understands it. An unknown C<v> is fatal: the envelope itself is the one
thing that cannot be guessed at.

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

use JSONL::Reader;
use JSONL::Writer;
use UUID::V4;

use LLM::Chat::Conversation::Message;

unit class LLM::Agent::Session;

#| The envelope version this class writes, and the only one it reads.
our constant ENVELOPE-VERSION = 1;

#| The types this class understands. Anything else is preserved by
#| C<events> and ignored by the readers.
our constant KNOWN-TYPES = <session-meta message grants compaction>.Set;

#| The file this transcript lives in. Append-only for its whole life.
has IO::Path:D $.path is required;

#|( The lines that were dropped on load: at most one, and only ever the
    final line of a file a crash caught mid-write. Each is a
    C<JSONL::Line> carrying the raw text and its line number. )
has @.warnings;

has %!meta;
has @!entries;          # replayed, compaction applied: { id, message, sticky }
has @!events;           # every envelope, in file order, untouched
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
    line is dropped and reported in C<.warnings>. )
method load(
	LLM::Agent::Session:U:
	IO(Cool) :$path!,
	--> LLM::Agent::Session:D
) {
	die "LLM::Agent::Session.load: no transcript at $path"
		unless $path.e && $path.f;

	my $session = self.bless(:$path, :open);
	$session!replay;
	$session!open-handle;
	$session;
}

method !open-handle(--> Nil) {
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

#|( The one place a line is written.

    The replayed state is updated B<before> the write, so an append that
    cannot be applied (a compaction naming a message that is not there)
    leaves no line behind to be replayed into the same error next time. )
method !append(Str:D $type, %payload --> Str:D) {
	my $id = uuid-v4;
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
		self!apply(%envelope);
		$!writer.append(%envelope);
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

#|( The escape hatch: write a line of your own type. It is preserved by
    C<events> and ignored by C<messages> and C<grants>, both here and in
    every older LLM::Agent that reads the file.

    The four built-in types are refused — going through the typed
    appender is what keeps their payloads in shape. )
method append-event(Str:D :$type!, :%payload --> Str:D) {
	die 'LLM::Agent::Session.append-event: a type cannot be empty'
		unless $type.trim.chars;
	die "LLM::Agent::Session.append-event: '$type' is a built-in type; use "
		~ 'the matching append-* method so its payload stays well-formed'
		if KNOWN-TYPES{$type};

	self!append($type, %payload.Hash);
}

# === Replay ===

method !replay(--> Nil) {
	my $reader = JSONL::Reader.new(path => $!path, :lenient);
	my @lines = $reader.list;

	# `.warnings` is only populated once the lazy Seq has been walked,
	# which the `.list` above has just done.
	my @bad = $reader.warnings.list;

	if @bad.elems {
		my Int $total = $!path.lines.elems;

		die "LLM::Agent::Session.load: {$!path} has {@bad.elems} malformed "
			~ 'lines; only a single malformed FINAL line is tolerated (that '
			~ 'is what a crash mid-write looks like — anything else means '
			~ 'the file was damaged, and replaying it would hand back a '
			~ 'conversation with an invisible hole in it)'
			if @bad.elems > 1;

		die "LLM::Agent::Session.load: {$!path} has a malformed line at line "
			~ "{@bad[0].line-number} of $total; only a malformed FINAL line "
			~ 'is tolerated (see above)'
			unless @bad[0].line-number == $total;

		@!warnings = @bad;
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

		self!apply(%envelope, line-number => $line.line-number);
		@!events.push: %envelope;
	}

	Nil;
}

# Fold one envelope into the replayed state. Shared by load and by every
# append, so a live session and a resumed one hold the same thing.
method !apply(%envelope, Int :$line-number --> Nil) {
	my %payload = (%envelope<payload> ~~ Associative ?? %envelope<payload> !! {}).Hash;

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
			self!apply-compaction(%envelope, %payload, :$line-number);
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

method !apply-compaction(%envelope, %payload, Int :$line-number --> Nil) {
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
    not understand. Plain data, as a copy. )
method events(--> List:D) {
	$!lock.protect: { @!events.map({ $_.Hash }).List };
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
	"LLM::Agent::Session<{$!path}> {@!events.elems} lines, "
		~ "{@!entries.elems} messages" ~ ($!closed ?? ', closed' !! '');
}
