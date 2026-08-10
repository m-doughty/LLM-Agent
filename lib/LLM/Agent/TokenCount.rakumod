=begin pod

=head1 NAME

LLM::Agent::TokenCount - how big is this conversation, three ways

=head1 SYNOPSIS

=begin code :lang<raku>

use LLM::Agent::TokenCount;

# The default: calibrate against what the provider actually billed.
my $counter = LLM::Agent::TokenCount::Usage.new;

$counter.count-messages(@messages);          # estimate, before any call

# ... after a successful completion, tell it what the provider charged:
$counter.record-usage(
    prompt-tokens     => $resp.prompt-tokens,
    completion-tokens => $resp.completion-tokens,
    message-count     => @conversation.elems,
);

$counter.count-messages(@conversation);      # now exact for that prefix

# No provider usage to lean on? Pure arithmetic, no dependencies:
my $rough = LLM::Agent::TokenCount::Heuristic.new;

# Have the real tokenizer? Exact, at the cost of loading it:
my $exact = LLM::Agent::TokenCount::Exact.new(
    counter => LLM::Chat::TokenCounter.new(:$tokenizer, :$template),
);

=end code

=head1 DESCRIPTION

Compaction needs a number: is this conversation close enough to the
context budget to be worth summarizing? The number does not need to be
perfect — it needs to be B<available>, B<cheap>, and B<never wildly
under>. Different deployments can afford different things, so counting is
a seam rather than a function.

=head2 The role

One required method, and three with an answer already:

=item C<count-messages(@messages --> Int)> — required. How many tokens
this conversation is worth.

=item C<record-usage(:$prompt-tokens, :$completion-tokens, :$message-count,
:$prefix-digest, :$backend --> Nil)> — a no-op by default. The loop calls
it after every successful attempt with what the provider reported, B<plus>
the identity of what was billed: the digest of the conversation prefix
(L<LLM::Agent::Canonical>'s C<messages-digest>) and the model that
charged for it. An implementation that can learn from it does, and the
others ignore it.

=item C<count-text(Str:D $text --> Int)> — how big a lump of B<text> is,
weighed as one system message. This is what an
L<LLM::Agent::RunContext> is counted with: the context is rendered into
the request and is B<not> part of the conversation, so weighing it
through C<count-messages> would hand a stateful counter an array that is
not the one it is calibrated against. The default answers through
C<count-messages> and is right for any counter that is a pure function of
its input; C<Usage> overrides it (see below), and so must any other
implementation that keeps state per call.

=item C<invalidate(--> Nil)> — throw away whatever has been learned. A
no-op on C<Heuristic> and C<Exact>, which learn nothing. The loop calls it
at the start of a run whose B<run context differs from the previous
run's>: a calibration recorded against a request carrying yesterday's
context is a confident number about a prompt nobody is sending any more,
and one round of honest estimation beats it. At most one drop per run
boundary, and none at all for a run that reuses the same context.

The loop owns exactly one counter instance and hands the B<same> one to
its compactor, so the calibration a run accumulates is not thrown away at
the moment it matters most.

=head2 Which one to use

=begin table

Implementation | Needs                        | Accuracy
===============|==============================|=========================================
Usage          | nothing (calibrates itself)  | exact for the billed prefix, estimated beyond
Heuristic      | nothing                      | ±20% on English prose, worse on code/CJK
Exact          | a tokenizer + a template     | exact, always

=end table

C<Usage> is the default because it needs no tokenizer, costs nothing per
call, and converges: after one round trip its answer for everything the
model has already seen is the provider's own number, and only the
messages added since are estimated.

C<Exact> is worth it when the tokenizer is loaded anyway — but note it
re-tokenizes the whole conversation on every call, which on a long chat
inside a per-round compaction check is not free.

=head2 How Usage's prefix-plus-delta works

C<record-usage> remembers one record: the message count C<N> and the
prompt tokens C<P> the provider charged for it, B<the digest of the
messages it charged for>, and B<which model charged>. C<P> covers
C<@messages[0 ..^ N]> — every message that existed when the request went
out, including the system prompt and the provider's own template framing,
which is precisely the part a heuristic is worst at.

C<count-messages(@messages)> then answers:

=begin table

Situation                              | Answer
=======================================|=============================================
nothing recorded yet                   | fallback estimate of the whole conversation
@messages is the calibrated prefix     | P
@messages extends it, unchanged        | P plus a fallback estimate of the tail
@messages[0 ..^ N] is something else   | fallback estimate of the whole conversation
@messages.elems < N                    | fallback estimate of the whole conversation

=end table

The last two rows are the same rule twice, and both are B<destructive>:
detecting that the calibration describes something else B<clears it>.

The shrink is compaction — the working array just went from 40 messages
to 6, so C<P>, charged for 40, describes a conversation that no longer
exists. Keeping it would be a live bug rather than a stale one: the loop
appends messages after compacting, and the moment the array grew back to
40 entries the counter would confidently apply C<P> to a completely
different 40 messages and under-report by the size of everything that was
summarized away.

The digest is the same failure without the size change. One counter is
shared by a loop and its compactor, and nothing stops an application
sharing one across runs; "at least N messages" is not evidence that these
are B<those> N messages. A second conversation of the same length would
otherwise inherit the first one's billed prefix — a number that has
nothing to do with it. So the first C<N> messages are digested (see
L<LLM::Agent::Canonical>) and compared, and a mismatch falls back exactly
as a shrink does.

A calibration recorded B<without> a digest — a caller that did not say
what was billed — is taken at its word, because the alternative is to
throw away perfectly good information from an application that predates
the argument.

The very next successful attempt re-calibrates, so the window in which
the estimate is rough is one round.

=head3 Which backend billed

C<record-usage> also records the model that reported the usage, and a
report from a B<different> one B<drops the calibration> rather than
leaving it in force. A fallback backend is not the primary with a
different name: it has its own tokenizer, its own template framing and
its own idea of what a system prompt costs, so C<P> from one is not an
estimate of the other. That matters most in the case that would otherwise
be silent — the fallback answered and reported no usage at all (a local
model, a mock), which leaves nothing to replace the calibration with. An
honest fallback estimate beats the primary's number applied to a
conversation the primary is not serving.

Callers that pass no C<backend> are unaffected: provenance that is not
stated cannot be compared, and nothing is dropped.

C<completion-tokens> is remembered (C<last-completion-tokens>) but plays
no part in counting: those tokens are already inside the assistant message
that got appended, so counting them again would double them.

A C<record-usage> call missing either C<prompt-tokens> or
C<message-count> is B<ignored> for calibration — a backend that reports no
usage (a local model, a mock) leaves the previous calibration alone
rather than destroying it. Negative values are ignored for the same
reason.

All of Usage's state is behind a Lock, so a run that reports usage from
its stream thread while a UI asks for a count from another does not read a
half-updated pair.

=head2 What Heuristic actually counts

Per message: C<per-message-overhead> plus
C<ceiling(chars / chars-per-token)>, where C<chars> is the message content
plus, for a message carrying tool calls, the JSON encoding of those calls
(a tool call is real tokens on the wire, and an assistant turn that asked
for three of them with long arguments is not an empty message).

The defaults — 4 characters per token, 8 tokens of overhead per message —
are the usual English-prose approximation plus room for the role tags and
separators every chat template adds. Tune them per model family if you
care; both are constructor arguments.

Deliberately B<not> counted: the tool-call ids and the template's own
preamble. Both are small, fixed, and swamped by C<per-message-overhead> —
and the whole point of this implementation is that it is arithmetic, not
a model of a tokenizer.

=head1 SEE ALSO

L<LLM::Chat::TokenCounter> (what C<Exact> wraps), C<LLM::Agent::Compactor>
(the main consumer of the answer).

=end pod

use JSON::Fast;

use LLM::Chat::Conversation::Message;

use LLM::Agent::Canonical;

#|( The counting seam. Compose it to teach the agent loop a new way to
    answer "how big is this conversation". )
role LLM::Agent::TokenCount {
	#| Required. How many tokens C<@messages> is worth. Must never throw
	#| for a well-formed conversation: the loop calls this on the hot path
	#| and a counter that dies takes the run with it.
	method count-messages(@messages --> Int) { ... }

	#|( How many tokens a lump of B<text> is worth, counted as one system
	    message would be. What the loop weighs an L<LLM::Agent::RunContext>
	    with: the context is rendered into the request but is B<not> part of
	    the conversation, so counting it through C<count-messages> would
	    hand a stateful counter an array that is not the one it is
	    calibrated against.

	    The default answers through C<count-messages>, which is right for
	    any implementation that is a pure function of its input. B<An
	    implementation that keeps state per call must override it> — see
	    C<Usage>, where the default would drop the calibration on every
	    call. )
	method count-text(Str:D $text --> Int) {
		self.count-messages([
			LLM::Chat::Conversation::Message.new(role => 'system', :content($text)),
		]);
	}

	#|( Throw away whatever this counter has learned, if it learns
	    anything. A no-op by default.

	    The loop calls it when the run's context changes: a calibration
	    recorded against a request that carried B<yesterday's> context
	    describes a prompt nobody is sending any more, and one round of
	    honest estimation beats a confident wrong number. )
	method invalidate(--> Nil) { }

	#|( Optional. Told to the counter after every successful attempt, with
	    whatever the provider reported and what it was reported B<about> —
	    any of the five may be undefined. C<prefix-digest> is
	    C<LLM::Agent::Canonical::messages-digest> over the messages the
	    request carried; C<backend> is what that backend calls its model.
	    The default does nothing at all, which is the right behaviour for
	    a counter that does not learn. )
	method record-usage(
		Int :$prompt-tokens,
		Int :$completion-tokens,
		Int :$message-count,
		Str :$prefix-digest,
		Str :$backend,
		--> Nil
	) { }
}

#|( Exact counting through a real tokenizer. Wraps anything with a
    C<get-conversation-count> method — normally an
    L<LLM::Chat::TokenCounter>, which is deliberately B<not> named as a
    type here so that using this module does not drag in the Tokenizers
    native library for the users who never touch it. )
class LLM::Agent::TokenCount::Exact does LLM::Agent::TokenCount {
	#| An LLM::Chat::TokenCounter, or anything else that can
	#| C<get-conversation-count(@messages)>.
	has $.counter is required;

	submethod TWEAK {
		die 'LLM::Agent::TokenCount::Exact needs a counter with a '
			~ 'get-conversation-count method (an LLM::Chat::TokenCounter, '
			~ 'or anything shaped like one); got '
			~ ($!counter.defined ?? 'a ' !! 'the type object ') ~ $!counter.^name
			unless $!counter.defined && $!counter.can('get-conversation-count');
	}

	method count-messages(@messages --> Int) {
		$!counter.get-conversation-count(@messages).Int;
	}
}

#|( Characters divided by a constant, plus a per-message overhead. No
    dependencies, no state, no I/O — always available, and the fallback
    every other implementation reaches for. )
class LLM::Agent::TokenCount::Heuristic does LLM::Agent::TokenCount {
	#| Average characters per token. 4 is the usual figure for English
	#| prose; dense code or CJK text runs lower (2–3).
	has Int:D $.chars-per-token = 4;
	#| Fixed cost per message for role tags, separators and the framing
	#| every chat template wraps a turn in.
	has Int:D $.per-message-overhead = 8;

	submethod TWEAK {
		die 'LLM::Agent::TokenCount::Heuristic: chars-per-token must be positive'
			unless $!chars-per-token > 0;
		die 'LLM::Agent::TokenCount::Heuristic: per-message-overhead cannot be negative'
			if $!per-message-overhead < 0;
	}

	method count-messages(@messages --> Int) {
		# NB: no seed operand. `[+] 0, @list` reduces over TWO items — the
		# 0 and the Seq — and `0 + Seq` numifies the Seq to its element
		# count, so a whole conversation quietly counts as "2". `[+]` of
		# an empty list is already 0.
		[+] @messages.map(-> $message {
			$!per-message-overhead
				+ ceiling(self!chars($message) / $!chars-per-token);
		});
	}

	method !chars($message --> Int) {
		my Int $chars = ($message.content // '').chars;
		my @calls = $message.tool-calls.list;
		$chars += to-json(@calls, :!pretty).chars if @calls.elems;
		$chars;
	}
}

#|( The default. Remembers what the provider charged for the prefix it has
    already seen and estimates only the tail beyond it. See the module Pod
    for the full table — including what happens when compaction shrinks
    the conversation out from under the calibration. )
class LLM::Agent::TokenCount::Usage does LLM::Agent::TokenCount {
	#| How the messages beyond the calibrated prefix are estimated, and
	#| what answers before there is any calibration at all.
	has LLM::Agent::TokenCount:D $.fallback =
		LLM::Agent::TokenCount::Heuristic.new;

	has Lock:D $!lock .= new;
	has Int $!known-messages;
	has Int $!known-tokens;
	# What was billed, and by whom. Either may be undefined — a caller is
	# free to report usage without saying what it was for, and then there
	# is nothing to check against.
	has Str $!known-digest;
	has Str $!known-backend;
	has Int $!last-completion-tokens;

	#|( The calibration in force, as
	    C<< { message-count, prompt-tokens, prefix-digest?, backend? } >>,
	    or an empty Hash when there is none. The last two keys are absent
	    when the report that established it did not say. For diagnostics
	    and tests — the loop never needs it. )
	method calibration(--> Hash:D) {
		# NB no early `return` from inside the protected block: it would
		# leave the method from within somebody else's Callable, which is
		# a control exception thrown through a lock this class does not
		# own the unwinding of.
		$!lock.protect: {
			my %calibration;
			if $!known-messages.defined {
				%calibration =
					message-count => $!known-messages,
					prompt-tokens => $!known-tokens,
				;
				%calibration<prefix-digest> = $!known-digest
					if $!known-digest.defined;
				%calibration<backend> = $!known-backend
					if $!known-backend.defined;
			}
			%calibration;
		};
	}

	#| The completion tokens of the most recent successful attempt, or an
	#| undefined Int. Recorded but never counted — see the module Pod.
	method last-completion-tokens(--> Int) {
		$!lock.protect: { $!last-completion-tokens };
	}

	method record-usage(
		Int :$prompt-tokens,
		Int :$completion-tokens,
		Int :$message-count,
		Str :$prefix-digest,
		Str :$backend,
		--> Nil
	) {
		$!lock.protect: {
			$!last-completion-tokens = $completion-tokens
				if $completion-tokens.defined && $completion-tokens >= 0;

			# A different model billed this time, so whatever the previous
			# one charged is not an estimate of anything any more. Dropped
			# BEFORE the new report is considered, so that a fallback which
			# reports no usage at all still clears the primary's figure
			# rather than quietly inheriting it — see the module Pod.
			if      $backend.defined && $!known-backend.defined
				&& $!known-backend ne $backend
			{
				self!forget;
			}

			if      $prompt-tokens.defined && $prompt-tokens >= 0
				&& $message-count.defined && $message-count >= 0
			{
				$!known-messages = $message-count;
				$!known-tokens   = $prompt-tokens;
				$!known-digest   = $prefix-digest;
				$!known-backend  = $backend;
			}
		};
	}

	method count-messages(@messages --> Int) {
		my Int $elems = @messages.elems;

		$!lock.protect: {
			# No calibration, or one describing a conversation this is not:
			# estimate the lot. Both mismatches also DROP the calibration —
			# see the module Pod for why keeping one would be worse than
			# having none.
			if !$!known-messages.defined {
				$!fallback.count-messages(@messages);
			}
			elsif $elems < $!known-messages {
				self!forget;
				$!fallback.count-messages(@messages);
			}
			# Digested inside the lock, and once: the prefix has to be the
			# one the record in force describes, and reading the record in
			# two steps around a walk of the conversation would let a
			# concurrent report change it in between. (The lock already
			# covers the fallback's own walk, so this is not a new cost
			# in kind.)
			elsif $!known-digest.defined
				&& messages-digest(@messages[0 ..^ $!known-messages].List)
					ne $!known-digest
			{
				self!forget;
				$!fallback.count-messages(@messages);
			}
			else {
				$!known-tokens
					+ $!fallback.count-messages(@messages[$!known-messages .. *-1].List);
			}
		};
	}

	#|( Text is weighed by the B<fallback>, and the calibration is neither
	    read nor touched. The role's default would count a one-message
	    array through C<count-messages>, which on this class compares that
	    array against the calibrated prefix, finds it is something else
	    entirely, and B<drops the calibration> — a counter that forgot what
	    the provider billed every time somebody asked how big a string was.

	    Signature identical to the role's, deliberately: a mismatched one
	    would be a new candidate rather than an override, and the role's
	    would still be the one that ran. )
	method count-text(Str:D $text --> Int) {
		$!fallback.count-text($text);
	}

	#| Drop the calibration. The next count is a fallback estimate, and the
	#| next successful attempt re-calibrates.
	method invalidate(--> Nil) {
		$!lock.protect: { self!forget };
		Nil;
	}

	# Drop the calibration, all four parts of it at once: a half-cleared
	# one would answer with a digest that belongs to a prompt count that
	# is no longer there. MUST be called with $!lock held.
	method !forget(--> Nil) {
		$!known-messages = Int;
		$!known-tokens   = Int;
		$!known-digest   = Str;
		$!known-backend  = Str;
		Nil;
	}
}
