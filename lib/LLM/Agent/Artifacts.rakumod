=begin pod

=head1 NAME

LLM::Agent::Artifacts - when one tool result is bigger than the
conversation can afford

=head1 SYNOPSIS

=begin code :lang<raku>

use LLM::Agent::Artifacts;

# What the loop does for you, when a result is over
# `request-budget.max-observation-size`:

my $store = LLM::Agent::Artifacts::Store.new(
    dir => artifact-dir-for($session.path),   # <transcript-stem>.artifacts/
);

my %stored = $store.store($op.op-id, $huge);  # { file, digest, bytes, chars }

my Str $seen = excerpt(
    $huge, 16_384,
    marker => stored-marker(elided-chars($huge.chars, 16_384), %stored),
);

# $seen — not $huge — is what the model sees, what the transcript holds,
# and what the ToolResult event carries. The full bytes are in the file
# and nowhere else.

=end code

=head1 DESCRIPTION

One C<fs_read> of a 400KB file is bigger than some context windows on its
own, and — this is the part that hurts — it is B<immortal>: it goes into
the conversation, into the transcript, and into every request for the
rest of the run, and compaction refuses to eat the recent turns it sits
in. The answer is to put an B<excerpt> in the conversation and the whole
thing in a file beside the transcript.

=head2 The invariant

B<One string, four places.> The excerpt is computed once, on the settle
path, B<before the tool message is built> — so the conversation content,
the session payload, the C<ToolResult> event's content and the digest on
the C<tool-settled> envelope are all the B<same string>. The full bytes
live in the artifact file and B<nowhere else>.

Everything follows from that:

=item a resumed run replays the excerpt byte for byte, and the seed check
(L<LLM::Agent::Canonical>'s digests) passes;

=item B<replay never needs the artifact to exist.> Delete the whole
C<.artifacts> directory and the transcript still loads, still resumes,
and still produces exactly the same next request. What is lost is the
ability to go and read what the tool really said, which is a different
kind of loss from a session that will not open;

=item a crash between the write and the settle envelope leaves an
B<orphan file>, which nothing reads and nothing trips over. The write
happens first on purpose: an envelope that named a file which does not
exist would be a lie in the durable record, and an unreferenced file is
not.

=head2 Characters, not bytes

The threshold is C<.chars> — graphemes — because everything downstream is
C<Str>-shaped and Raku's C<substr> is grapheme-safe: an excerpt can never
be cut through the middle of a character, or between a base character and
its combining accent, or between the CR and the LF of a Windows line
ending (Raku makes those one grapheme). A byte-oriented cut would have to
worry about all three.

The byte count is recorded in the metadata, because that is the number
that matches what C<ls> and C<shasum> say about the file.

=head2 The excerpt

Head-weighted, three quarters to one quarter, with one marker line
between them:

=begin code :lang<text>

    <the first 3/4 of the budget>
    [... elided 391,204 chars (402,110 bytes total); full result: 019903...txt sha256 4f2c... ...]
    <the last 1/4 of the budget>

=end code

Head-weighted because the top of a file, a directory listing or a diff is
where the identifying information is, and the tail is kept at all because
the end is where errors and totals are.

The marker names the artifact by B<basename>, never by path. Transcripts
get moved, copied out of a container, or read on a different machine; a
path recorded inside the conversation would be wrong the first time any
of that happened, and the file is always in the C<.artifacts> directory
beside the transcript that names it.

A run with B<no session> has nowhere to put the full bytes, so it says
so — the marker records the size and the digest and states that the full
result was not stored. The model is told the same thing either way: this
is an excerpt, and here is how much is missing.

=head2 Retention: none

Nothing here deletes anything, ever. A long-lived agent directory grows
one file per oversized tool result, and cleaning it up — by age, by size,
by which transcripts still exist — is a decision an application makes,
not one a library makes silently about files somebody may want.

=head2 Not the same thing as the compactor's cap

L<LLM::Agent::Compactor>'s C<tool-result-cap> truncates tool results in
the text it sends B<the summarizer>, and changes nothing about the
conversation. This changes what the conversation contains in the first
place. They are different layers and both are worth having: this one
stops a huge result entering the transcript, that one stops a compaction
choking on the ones that already did.

Server-side truncation (an MCP tool that returns its own "output
truncated" note) is upstream of all of this and unparseable in general,
so nothing here tries: the size is measured, never inferred from the
payload.

=head1 SEE ALSO

L<LLM::Agent::RequestBudget> (where C<max-observation-size> lives),
L<LLM::Agent::Loop> (the settle path that calls this),
L<LLM::Agent::Session> (the C<artifact> key on a C<tool-settled> line).

=end pod

use Digest::SHA256::Native;

# A module rather than a class, with the store as C<::Store> inside it:
# the excerpt half is four subs that have no state, and a class cannot
# export a sub to the scope that used it.
unit module LLM::Agent::Artifacts;

#|( The directory a transcript's artifacts live in:
    C<< <stem>.artifacts/ >> beside the transcript itself.

    A sibling directory rather than a subdirectory of some state root
    because it has exactly the lifetime of the transcript, and one whose
    name is derived from it because an application scanning a state
    directory for C<*.jsonl> transcripts sees nothing new. )
our sub artifact-dir-for(IO(Cool) $transcript --> IO::Path:D) is export {
	# NB not `.extension('artifacts', :parts(1))`: that replaces an
	# extension the path may not have, and a transcript called `run` with
	# no suffix at all would then be handed its OWN path as the directory
	# to write into.
	my Str $extension = $transcript.extension;
	my Str $stem = $extension.chars
		?? $transcript.basename.substr(0, *-($extension.chars + 1))
		!! $transcript.basename;
	$transcript.sibling($stem ~ '.artifacts');
}

#|( The marker line for a result whose full bytes B<were> stored, from the
    metadata C<store> returned. Named by basename — see the Pod. )
our sub stored-marker(Int:D $elided, %stored --> Str:D) is export {
	'[... elided ' ~ commify($elided) ~ ' chars ('
		~ commify(%stored<bytes> // 0) ~ ' bytes total); full result: '
		~ (%stored<file> // '?') ~ ' sha256 ' ~ (%stored<digest> // '?')
		~ ' ...]';
}

#|( The marker line for a result that could B<not> be stored — a run with
    no session, or a write that failed. It says so rather than naming a
    file nobody can open. )
our sub unstored-marker(
	Int:D $elided,
	Int:D $bytes,
	Str:D $digest,
	Str:D $why = 'not stored',
	--> Str:D
) is export {
	'[... elided ' ~ commify($elided) ~ ' chars (' ~ commify($bytes)
		~ ' bytes total); full result ' ~ $why ~ ', sha256 ' ~ $digest
		~ ' ...]';
}

#|( C<$content> cut down to about C<$limit> characters: the first three
    quarters, C<$marker> on a line of its own, and the last quarter.

    Returns C<$content> B<unchanged> when it is C<$limit> characters or
    fewer — the threshold is "bigger than", so a result exactly the size
    of the budget is left alone.

    Grapheme-safe by construction: C<substr> counts characters, so no cut
    lands inside one. )
our sub excerpt(
	Str:D $content,
	Int:D $limit,
	Str:D :$marker!,
	--> Str:D
) is export {
	return $content unless $limit > 0 && $content.chars > $limit;

	my Int $head = ceiling($limit * 3 / 4);
	my Int $tail = $limit - $head;

	# NB the guard: `substr(*-0)` is the empty string rather than the whole
	# string, but spelling that out is cheaper than making a reader check.
	my Str $start = $content.substr(0, $head);
	my Str $end   = $tail > 0 ?? $content.substr(*-$tail) !! '';

	$start ~ "\n" ~ $marker ~ "\n" ~ $end;
}

#|( The digest an artifact is recorded under: plain SHA-256 of the
    content as UTF-8, so C<shasum -a 256 <the file>> agrees with the
    marker in the conversation. B<Not> L<LLM::Agent::Canonical>'s
    C<data-digest>, which digests a JSON rendering — right for comparing
    two structures, wrong for a file somebody will check by hand. )
our sub content-digest(Str:D $content --> Str:D) is export {
	sha256-hex($content);
}

#| How many characters an excerpt of this size would leave out.
our sub elided-chars(Int:D $chars, Int:D $limit --> Int:D) is export {
	return 0 unless $limit > 0 && $chars > $limit;
	$chars - $limit;
}

#|( Thousands separators, because these numbers are read by people and
    "elided 391204 chars" is a number nobody parses at a glance. )
my sub commify(Int(Cool) $n --> Str:D) {
	$n.Str.flip.comb(3).join(',').flip;
}

#|( The store: one directory, one file per operation, no retention.

    The directory is created on the B<first write>, not at construction —
    a run whose tool results all fit leaves no directory behind. )
class Store {
	#|( An operation id is a uuid or a session envelope id, so this never
	    has anything to do — but a file name built from something a
	    provider influenced is worth spelling out as safe rather than
	    assuming it. )
	my sub sanitise(Str:D $id --> Str:D) {
		my Str $safe = $id.subst(/<-[A..Za..z0..9_.-]>/, '_', :g);
		$safe.chars ?? $safe !! 'artifact';
	}

	#| Where the files go. Created on first use.
	has IO::Path:D $.dir is required;

	#|( Write C<$content> as this operation's artifact and return
	    C<< { file, digest, bytes, chars } >> — C<file> is the B<basename>,
	    which is what an envelope records.

	    Throws on any I/O failure. The caller (L<LLM::Agent::Loop>)
	    shields it: an artifact that could not be written is a warning and
	    an excerpt that says so, never a tool call that failed. )
	method store(Str:D $op-id, Str:D $content --> Hash:D) {
		my Str $name = sanitise($op-id) ~ '.txt';
		my $file = $!dir.add($name);

		$!dir.mkdir unless $!dir.d;

		# Written whole, then closed, and only then does the caller record
		# it: the envelope that names this file is written after this
		# method has returned. See the Pod on orphans.
		$file.spurt($content);

		%(
			file   => $name,
			digest => content-digest($content),
			bytes  => $content.encode('utf-8').bytes,
			chars  => $content.chars,
		);
	}

	#| The path an operation's artifact would have. For an application
	#| resolving an C<artifact> key out of a transcript.
	method path-for(Str:D $op-id --> IO::Path:D) {
		$!dir.add(sanitise($op-id) ~ '.txt');
	}

	method gist(--> Str:D) { "LLM::Agent::Artifacts::Store<{$!dir}>" }
}
