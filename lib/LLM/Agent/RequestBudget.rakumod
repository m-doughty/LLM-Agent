=begin pod

=head1 NAME

LLM::Agent::RequestBudget - what fits in this backend, and what this run
is allowed to spend

=head1 SYNOPSIS

=begin code :lang<raku>

use LLM::Agent::RequestBudget;

my $budget = LLM::Agent::RequestBudget.new(
    # One profile per backend, keyed by what that backend calls its model
    # — the same string LLM::Agent::TokenCount::Usage calibrates against.
    profiles => {
        'moonshotai/kimi-k2' => LLM::Agent::RequestBudget::Profile.new(
            context-window     => 128_000,
            completion-reserve => 8_000,
        ),
        'local' => LLM::Agent::RequestBudget::Profile.new(
            context-window => 8_192,
        ),
    },
    # For a backend with no profile of its own.
    default-profile => LLM::Agent::RequestBudget::Profile.new(
        context-window => 32_000,
    ),

    # A tool result bigger than this is excerpted into the conversation
    # and spilled whole to an artifact file. See LLM::Agent::Artifacts.
    max-observation-size => 16_384,

    # Run caps. Undefined (the default) means no cap at all.
    max-cost        => 2.50,
    max-total-tokens => 400_000,
    max-wall-clock  => 1800,
);

my $loop = LLM::Agent::Loop.new(:@backends, :$provider, request-budget => $budget);

=end code

=head1 DESCRIPTION

Two questions with one owner: B<will this request fit the backend it is
about to be sent to>, and B<has this run spent more than it was allowed
to>. They are one object because they are the same kind of fact — a limit
that belongs to the deployment rather than to the conversation — and
because both are read at the same two moments (the top of a round, and
the boundary between two tool calls).

Nothing here talks to a backend, counts a token or ends a run.
L<LLM::Agent::Loop> does all three; this is the thing it asks.

=head2 A profile per backend, keyed by model

C<%.profiles> is keyed by B<what a backend calls its model> — exactly the
string L<LLM::Agent::TokenCount>'s C<Usage> stores its calibration under,
so a profile and a calibration cannot end up describing different things
under the same name. A backend with no profile falls back to
C<default-profile>, and a backend with neither is B<not preflighted at
all>: an unknown window is not a small one, and refusing to send a
request because nobody said how big the window is would be worse than
sending it.

A profile is four numbers:

=begin table

Field               | What it is
====================|==========================================================
context-window      | the whole window, in tokens: prompt B<and> completion
completion-reserve  | tokens kept back for the answer (see below)
input-safety-margin | slack for template framing the counter cannot see
counter             | an L<LLM::Agent::TokenCount> for this model only

=end table

C<completion-reserve> is B<undefined by default>, and is then taken from
the backend at lookup time: C<< $backend.settings.max_tokens >>, or 1024
when there is no answer to be had. That is deliberate — the number of
tokens a backend will be asked to produce is already configured on the
backend, and carrying it twice creates a way for the two to disagree.
B<Note what this means in practice>: L<LLM::Chat>'s C<Settings> defaults
C<max_tokens> to 256, so a deployment that never set it gets a 256-token
reserve, which is honest about what that backend will actually generate.

C<counter> exists for heterogeneous chains. Two models with different
tokenizers do not agree about how big a conversation is, and a chain that
falls back from a 128k model to an 8k one is exactly where the difference
matters; a profile with no counter of its own uses the loop's.

=head2 The preflight arithmetic

L<LLM::Agent::Loop> asks, per backend, before it spends an attempt:

=begin code :lang<text>

    needed = count-messages(@conversation)
           + ceiling(chars(to-json(@tools)) / 4)
           + input-safety-margin

    it fits when   needed + completion-reserve <= context-window

=end code

The tool declarations are counted because they are real tokens on the
wire and a catalogue of thirty tools is not small — and because they
B<disappear> when the loop switches tools off after a limit, which is
precisely the case where a conversation that did not fit suddenly does.
They are estimated at four characters per token rather than counted,
because they are JSON rather than prose and no tokenizer here is asked to
weigh in on a schema.

=head2 The caps, and what "spent" means

C<max-cost>, C<max-total-tokens> and C<max-wall-clock> are undefined by
default, and undefined means B<no cap>. C<cap-tripped> compares them
against a spend record the loop accumulates, and answers with
C<< { cap, spent, max } >> for the first one that has been reached.

B<Reached, not exceeded>: a cap is a ceiling on what the run may have
spent, so a run that has spent exactly its cap has nothing left and is
stopped. The alternative — stopping only once the cap is B<past> — means
every cap is quietly the cap plus one more round trip, which for
C<max-cost> is the round trip somebody set a cap to avoid.

C<cost> is only ever counted when a provider reported one (OpenRouter
does; most do not), and a run whose backends report nothing spends
C<0> — so a C<max-cost> against a backend that does not price its calls
never trips. That is the honest behaviour: an unreported cost is not a
zero cost, and inventing a number to compare against would be worse than
having none.

B<Known limitation, 0.2:> a resumed run starts its accumulators at zero.
The transcript records what each turn cost, but adding them up across
processes is runtime-store territory rather than transcript territory,
and the loop deliberately does not go there.

=head2 max-observation-size lives here, not on a profile

It is a B<character> count, not a token count, and it is a property of
the budget as a whole rather than of any one backend. The reason is
timing: the decision to excerpt an enormous tool result is made when that
result settles, which is B<before> the loop knows which backend the next
round will use — see L<LLM::Agent::Artifacts>. A per-profile threshold
would have to be evaluated against a backend nobody has chosen yet.

=head2 The context-budget shorthand

C<< LLM::Agent::Loop.context-budget >> is still the one-number way in,
and a loop given one and no explicit budget synthesizes
C<for-window($context-budget)>: a default profile of exactly that window,
with B<no> safety margin and B<no> completion reserve.

Those two zeroes are the point. C<context-budget> is a statement about
the window and nothing else — it is the same number the compactor is
built with, and the compactor already reserves headroom for the answer
through its ratios (it targets 40% of the budget and triggers at 80%).
Subtracting a margin and a reserve from it as well would double-count
that headroom, and on a small window a 512-token margin is most of the
window. What the shorthand buys is the thing that was missing: a
conversation that does B<not fit the window at all> now ends the run
cleanly instead of being sent and rejected. A deployment that wants a
tight preflight states the numbers per model, because those numbers are
per model.

=head1 SEE ALSO

L<LLM::Agent::Loop> (the only consumer), L<LLM::Agent::Artifacts> (what
C<max-observation-size> triggers), L<LLM::Agent::TokenCount> (the
counting seam and the calibration key), L<LLM::Agent::Compactor> (the
other half of "it does not fit").

=end pod

use LLM::Agent::TokenCount;

#|( One backend's idea of what fits. Keyed in C<%RequestBudget.profiles>
    by the model name that backend reports. )
class LLM::Agent::RequestBudget::Profile {
	#| The whole window in tokens — prompt and completion together.
	has Int:D $.context-window is required;

	#|( Tokens kept back for the answer. Undefined (the default) means
	    "ask the backend": C<< $backend.settings.max_tokens >>, or
	    C<DEFAULT-RESERVE> when it cannot say. )
	has Int $.completion-reserve;

	#|( Slack for the framing a counter cannot see — role tags, the
	    template's own preamble, the tool-call scaffolding a provider adds.
	    512 is a fraction of a percent of a real window; it is most of a
	    toy one, so tune it if you are describing a small model. )
	has Int:D $.input-safety-margin = 512;

	#|( This model's counter, for a chain whose backends do not share a
	    tokenizer. Undefined means the loop's own. )
	has LLM::Agent::TokenCount $.counter;

	submethod TWEAK {
		die 'LLM::Agent::RequestBudget::Profile: context-window must be '
			~ 'positive — a window of nothing cannot hold a request'
			unless $!context-window > 0;
		die 'LLM::Agent::RequestBudget::Profile: completion-reserve cannot '
			~ 'be negative'
			if $!completion-reserve.defined && $!completion-reserve < 0;
		die 'LLM::Agent::RequestBudget::Profile: input-safety-margin cannot '
			~ 'be negative'
			if $!input-safety-margin < 0;
		die 'LLM::Agent::RequestBudget::Profile: completion-reserve is '
			~ $!completion-reserve ~ ' but the whole window is '
			~ $!context-window ~ ' — nothing would ever fit'
			if $!completion-reserve.defined
				&& $!completion-reserve >= $!context-window;
	}

	method gist(--> Str:D) {
		'Profile<window ' ~ $!context-window ~ ', reserve '
			~ ($!completion-reserve // 'from the backend') ~ ', margin '
			~ $!input-safety-margin ~ '>';
	}
}

class LLM::Agent::RequestBudget {
	#|( The reserve for a backend that cannot say what it will generate.
	    Generous on purpose: an under-reserved preflight passes a request
	    the provider then rejects, which is the failure this class exists
	    to prevent. )
	our constant DEFAULT-RESERVE = 1024;

	#| Model name → Profile. See the Pod on why the key is the model.
	has %.profiles;

	#| The profile for a backend that has none of its own. Optional; a
	#| backend with neither is not preflighted.
	has LLM::Agent::RequestBudget::Profile $.default-profile;

	#|( Characters — not tokens, and not bytes — of tool output that may
	    live in the conversation before it is excerpted and spilled to an
	    artifact. See L<LLM::Agent::Artifacts>. )
	has Int:D $.max-observation-size = 16_384;

	#|( Total reported cost this run may reach. Undefined: no cap.

	    C<Real>, not C<Num>, and deliberately: C<2.50> is a B<Rat> in Raku
	    and so is every decimal a JSON config parses to, so a C<Num>
	    constraint would refuse the most obvious way anybody writes this. )
	has Real $.max-cost;

	#| Total tokens (prompt + completion, every attempt) this run may
	#| reach. Undefined: no cap.
	has Int $.max-total-tokens;

	#| Wall-clock seconds this run may reach. Undefined: no cap.
	has Real $.max-wall-clock;

	submethod TWEAK {
		for %!profiles.kv -> $model, $profile {
			die "LLM::Agent::RequestBudget: the profile for '$model' is a "
				~ $profile.^name ~ ', not an '
				~ 'LLM::Agent::RequestBudget::Profile'
				unless $profile ~~ LLM::Agent::RequestBudget::Profile:D;
		}

		die 'LLM::Agent::RequestBudget: max-observation-size must be '
			~ 'positive — leave the budget out entirely to never excerpt'
			unless $!max-observation-size > 0;

		die 'LLM::Agent::RequestBudget: max-cost cannot be negative'
			if $!max-cost.defined && $!max-cost < 0;
		die 'LLM::Agent::RequestBudget: max-total-tokens cannot be negative'
			if $!max-total-tokens.defined && $!max-total-tokens < 0;
		die 'LLM::Agent::RequestBudget: max-wall-clock cannot be negative'
			if $!max-wall-clock.defined && $!max-wall-clock < 0;
	}

	#|( The budget C<< Loop.context-budget >> expands to: one default
	    profile of exactly that window, B<no> margin and B<no> reserve.
	    See the Pod section on the shorthand for why both are zero. )
	method for-window(
		LLM::Agent::RequestBudget:U:
		Int:D $window,
		--> LLM::Agent::RequestBudget:D
	) {
		self.new(
			default-profile => LLM::Agent::RequestBudget::Profile.new(
				context-window     => $window,
				completion-reserve => 0,
				input-safety-margin => 0,
			),
		);
	}

	#|( The profile for a backend that calls its model C<$model>, or an
	    undefined Profile when nothing describes it — which is the loop's
	    signal to skip the preflight for that backend rather than to guess
	    at a window. )
	method profile-for(Str:D $model --> LLM::Agent::RequestBudget::Profile) {
		%!profiles{$model} // $!default-profile;
	}

	#|( The completion reserve C<$profile> asks for against C<$backend>:
	    the profile's own number, or what the backend says it will
	    generate, or C<DEFAULT-RESERVE>.

	    C<$backend> is duck-typed — C<.settings.max_tokens> is a
	    convention among the L<LLM::Chat> backends rather than part of any
	    contract, and anything that cannot answer simply does not. )
	method reserve-for(
		LLM::Agent::RequestBudget::Profile:D $profile,
		$backend,
		--> Int:D
	) {
		return $profile.completion-reserve if $profile.completion-reserve.defined;
		my $max = try $backend.settings.max_tokens;
		($max.defined && $max ~~ Numeric && $max > 0) ?? $max.Int !! DEFAULT-RESERVE;
	}

	#| Every window this budget declares, default included. The loop
	#| checks a compactor's budget against the smallest of them.
	method windows(--> List:D) {
		my @windows = %!profiles.values.map({ .context-window });
		@windows.push: $!default-profile.context-window
			if $!default-profile.defined;
		@windows.sort.List;
	}

	#| True when this budget caps anything at all.
	method has-caps(--> Bool:D) {
		so ($!max-cost.defined || $!max-total-tokens.defined
			|| $!max-wall-clock.defined);
	}

	#|( The first cap C<%spent> has reached, as
	    C<< { cap, spent, max } >> — or an empty Hash when it has reached
	    none.

	    C<%spent> is C<< { cost, total-tokens, wall-clock } >>; a missing
	    key counts as zero, which is what a provider that reports no cost
	    leaves behind. Reached rather than exceeded — see the Pod. )
	method cap-tripped(%spent --> Hash:D) {
		with $!max-cost {
			my $cost = (%spent<cost> // 0).Num;
			return %( cap => 'cost', spent => $cost, max => $_ )
				if $cost >= $_;
		}
		with $!max-total-tokens {
			my $tokens = (%spent<total-tokens> // 0).Int;
			return %( cap => 'total-tokens', spent => $tokens, max => $_ )
				if $tokens >= $_;
		}
		with $!max-wall-clock {
			my $seconds = (%spent<wall-clock> // 0).Real;
			# Rounded to milliseconds: this ends up in an error message a
			# human reads, and eighteen decimal places of Instant
			# arithmetic help nobody.
			return %(
				cap   => 'wall-clock',
				spent => ($seconds * 1000).round / 1000,
				max   => $_,
			) if $seconds >= $_;
		}
		%();
	}

	method gist(--> Str:D) {
		'LLM::Agent::RequestBudget<' ~ %!profiles.elems ~ ' profiles'
			~ ($!default-profile.defined ?? ' + default' !! '')
			~ (self.has-caps ?? ', capped' !! '') ~ '>';
	}
}
