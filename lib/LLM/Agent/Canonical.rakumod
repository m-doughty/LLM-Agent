=begin pod

=head1 NAME

LLM::Agent::Canonical - one stable rendering of a message, a conversation
or a lump of plain data, and the digest of it

=head1 SYNOPSIS

=begin code :lang<raku>

use LLM::Agent::Canonical;

# "Is this the same message the session recorded here?" — all of it, not
# just the prose.
message-digest($mine) eq message-digest($theirs);

# "Is this conversation still the one the provider billed for?"
my $prefix = messages-digest(@conversation);
$counter.record-usage(
    prompt-tokens => 812, message-count => @conversation.elems,
    prefix-digest => $prefix, backend => $backend.model,
);

# "Have the grants changed since the last time I wrote them out?"
data-digest($policy.grants) ne $written;

# "Is this the same tool call the model made two rounds ago?" — key
# order and whitespace are not semantics.
canonical-arguments('{"b":2, "a":1}') eq canonical-arguments('{"a":1,"b":2}');

=end code

=head1 DESCRIPTION

Several parts of the loop need to answer "is this B<the same thing> as
that?" about data that arrives from a model, a provider or a file, where
the two copies are equal in every way that matters and different in ways
that do not: a JSON object whose keys came back in another order, a Hash
that has been round-tripped through a transcript, a conversation prefix
rebuilt from a session.

Identity by C<eqv> is no use there (a decoded Hash never equals a
hand-built one), and identity by prose — comparing C<role> and
C<content>, which is what the loop used to do — is worse than no check
at all, because it says "the same" about an assistant turn that has
grown three tool calls.

So: one canonical rendering, and a SHA-256 of it.

=head2 What canonical means here

C<canonical-json> renders plain data with B<sorted keys> and no
whitespace, after normalising it:

=item C<Associative> and C<Positional> values are walked recursively, so
nesting is canonicalised all the way down;

=item C<Str>, C<Int>, C<Rat>, C<Num> and C<Bool> are kept as they are;

=item an undefined value becomes JSON C<null>;

=item B<anything else> — a DateTime, an object a provider invented — is
stringified rather than thrown at, because these functions sit on the
loop's hot path and one that dies takes a run with it.

That last rule is what makes this safe to call on whatever a tool
provider hands back. It is not a general-purpose serialiser: it is a
comparison key, and two things that render the same string are being
B<treated> as the same thing.

=head2 Why not Message.get-checksum

L<LLM::Chat::Conversation::Message> has a C<get-checksum>, and it is the
wrong tool for this:

=item it hashes C<to-hash>, which omits C<sticky>, C<sysprompt> and
C<depth> — the three things that decide whether a compaction is allowed
to summarise a message away;

=item it C<.raku>s a Hash, whose iteration order is randomised per
process, so the same message can hash differently in two processes;

=item it B<memoises> into an C<is rw> attribute, so a Message that is
mutated after its first checksum keeps answering with the old one.

The functions here have none of that state: same input, same digest,
every process, every time.

=head2 The digests

=begin table

Function                | Over
========================|=====================================================
data-digest($value)     | the canonical JSON of any plain data
message-digest($msg)    | role, content, tool-calls, tool-call-id, sticky, sysprompt, depth
messages-digest(@msgs)  | the per-message digests, in order

=end table

C<message-digest> covers B<everything that survives the session round
trip> (see L<LLM::Agent::Session>'s C<message> payload) and nothing that
does not — C<:%extra> is deliberately absent, because C<reasoning> and
C<usage> are not part of the conversation a model sees.

C<messages-digest> is a digest of digests rather than of the whole
concatenation, which keeps it cheap to reason about: two conversations
share a digest exactly when they are the same messages in the same order.

=head1 SEE ALSO

L<LLM::Agent::Loop> (seeds a session by digest), L<LLM::Agent::TokenCount>
(calibrates against one), L<LLM::Agent::Session>.

=end pod

use Digest::SHA256::Native;
use JSON::Fast;

use LLM::Chat::Conversation::Message;

unit module LLM::Agent::Canonical;

# Whatever came in, as something JSON::Fast is certain to be able to
# render. Deliberately total: every branch has an answer, so nothing
# below can throw on a provider with an odd idea of a tool result.
my sub plain($value) {
	return Nil without $value;
	return $value if $value ~~ Bool || $value ~~ Str || $value ~~ Int
		|| $value ~~ Rat || $value ~~ Num;
	return $value.Hash.pairs.map({ .key.Str => plain(.value) }).Hash
		if $value ~~ Associative;
	return $value.list.map({ plain($_) }).List if $value ~~ Positional;
	$value.Str;
}

#|( C<$value> as one line of JSON with sorted keys — the same data always
    rendering the same string, whatever order it arrived in and whatever
    it is made of. See the module Pod for the normalisation rules. )
our sub canonical-json($value --> Str:D) is export {
	to-json(plain($value), :sorted-keys, :!pretty);
}

#|( Tool-call arguments as a comparison key. The JSON string a model
    sends is B<reparsed and re-rendered>, so C<< {"b":2,"a":1} >> and
    C<< { "a": 1, "b": 2 } >> are one call made twice rather than two
    different ones; a string that is not JSON at all is its own key,
    verbatim. Undefined arguments render as the empty string. )
our sub canonical-arguments($arguments --> Str:D) is export {
	return '' without $arguments;
	return canonical-json($arguments)
		if $arguments ~~ Associative || $arguments ~~ Positional;

	my Str $text = $arguments.Str;

	# Only what could be a JSON object or array is offered to the parser.
	# Arguments are one or the other in every API that has them, and it
	# keeps prose (or nothing at all) from taking the throwing path —
	# JSON::Fast builds its parse errors through a deprecated method, so
	# a caught failure still prints a deprecation notice at exit.
	my Str $trimmed = $text.trim;
	return $text unless $trimmed.starts-with('{') || $trimmed.starts-with('[');

	# The flag, rather than testing the parse result: `null` and `false`
	# are successful parses of falsy values, and `//` cannot tell those
	# from a document that is not JSON at all. (Nor can a `[from-json(...)]`
	# wrapper — a lone Hash in square brackets meets the single-argument
	# rule and flattens into its Pairs.)
	my $parsed;
	my Bool $parsed-ok = so try { $parsed = from-json($trimmed); True };
	$parsed-ok ?? canonical-json($parsed) !! $text;
}

#| SHA-256 (hex) of C<$value>'s canonical JSON.
our sub data-digest($value --> Str:D) is export {
	sha256-hex(canonical-json($value));
}

#|( SHA-256 (hex) of everything about C<$message> that a transcript keeps
    and a model sees: role, content, tool calls, tool-call id, and the
    three stickiness flags. Two messages with this digest in common are
    interchangeable as far as the loop is concerned. )
our sub message-digest(
	LLM::Chat::Conversation::Message:D $message,
	--> Str:D
) is export {
	my %fields =
		role      => $message.role.Str,
		content   => ($message.content // '').Str,
		sticky    => ?$message.sticky,
		sysprompt => ?$message.sysprompt,
	;

	my @calls = $message.tool-calls.list;
	%fields<tool-calls>   = @calls.List if @calls.elems;
	%fields<tool-call-id> = $message.tool-call-id.Str
		if $message.tool-call-id.defined;
	%fields<depth>        = $message.depth.Int if $message.depth.defined;

	data-digest(%fields);
}

#|( SHA-256 (hex) of C<@messages> as a sequence: the per-message digests,
    joined in order. An empty conversation has a digest too, and it is
    the digest of nothing — which is exactly what a calibration recorded
    against no messages should compare equal to. )
our sub messages-digest(@messages --> Str:D) is export {
	sha256-hex(@messages.map({ message-digest($_) }).join("\n"));
}
