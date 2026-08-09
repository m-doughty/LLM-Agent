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

Two methods, one of them optional:

=item C<count-messages(@messages --> Int)> — required. How many tokens
this conversation is worth.

=item C<record-usage(:$prompt-tokens, :$completion-tokens, :$message-count
--> Nil)> — a no-op by default. The loop calls it after every successful
attempt with what the provider reported; an implementation that can learn
from it does, and the others ignore it.

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

C<record-usage> remembers one pair: the message count C<N> and the prompt
tokens C<P> the provider charged for it. C<P> covers C<@messages[0 ..^ N]>
— every message that existed when the request went out, including the
system prompt and the provider's own template framing, which is precisely
the part a heuristic is worst at.

C<count-messages(@messages)> then answers:

=begin table

Situation                     | Answer
==============================|===============================================
nothing recorded yet          | fallback estimate of the whole conversation
@messages.elems == N          | P
@messages.elems  > N          | P + fallback estimate of @messages[N .. *-1]
@messages.elems  < N          | fallback estimate of the whole conversation

=end table

The last row is compaction: the working array just shrank from 40
messages to 6, so C<P> — which was charged for 40 — describes a
conversation that no longer exists. Falling back is the only honest
answer.

It is also, deliberately, B<destructive>: detecting a shrink B<clears the
calibration>. Keeping it would be a live bug rather than a stale one —
the loop appends messages after compacting, and the moment the array grew
back to 40 entries the counter would confidently apply C<P> to a
completely different 40 messages and under-report by the size of
everything that was summarized away. The very next successful attempt
re-calibrates against the compacted conversation, so the window in which
the estimate is rough is one round.

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

#|( The counting seam. Compose it to teach the agent loop a new way to
    answer "how big is this conversation". )
role LLM::Agent::TokenCount {
	#| Required. How many tokens C<@messages> is worth. Must never throw
	#| for a well-formed conversation: the loop calls this on the hot path
	#| and a counter that dies takes the run with it.
	method count-messages(@messages --> Int) { ... }

	#|( Optional. Told to the counter after every successful attempt, with
	    whatever the provider reported — any of the three may be
	    undefined. The default does nothing at all, which is the right
	    behaviour for a counter that does not learn. )
	method record-usage(
		Int :$prompt-tokens,
		Int :$completion-tokens,
		Int :$message-count,
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
	has Int $!last-completion-tokens;

	#| The calibration in force, as C<< { message-count, prompt-tokens } >>,
	#| or an empty Hash when there is none. For diagnostics and tests —
	#| the loop never needs it.
	method calibration(--> Hash:D) {
		$!lock.protect: {
			$!known-messages.defined
				?? {
					message-count => $!known-messages,
					prompt-tokens => $!known-tokens,
				}
				!! {};
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
		--> Nil
	) {
		$!lock.protect: {
			$!last-completion-tokens = $completion-tokens
				if $completion-tokens.defined && $completion-tokens >= 0;

			if      $prompt-tokens.defined && $prompt-tokens >= 0
				&& $message-count.defined && $message-count >= 0
			{
				$!known-messages = $message-count;
				$!known-tokens   = $prompt-tokens;
			}
		};
	}

	method count-messages(@messages --> Int) {
		my Int $elems = @messages.elems;

		$!lock.protect: {
			# No calibration, or one describing a conversation that has
			# since been compacted away: estimate the lot. The shrink case
			# also DROPS the calibration — see the module Pod for why
			# keeping it would be worse than having none.
			if !$!known-messages.defined {
				$!fallback.count-messages(@messages);
			}
			elsif $elems < $!known-messages {
				$!known-messages = Int;
				$!known-tokens   = Int;
				$!fallback.count-messages(@messages);
			}
			else {
				$!known-tokens
					+ $!fallback.count-messages(@messages[$!known-messages .. *-1].List);
			}
		};
	}
}
