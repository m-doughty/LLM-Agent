=begin pod

=head1 NAME

LLM::Agent::Loop - the streaming agent loop: tools, retry, fallback,
transcript, compaction

=head1 SYNOPSIS

=begin code :lang<raku>

use LLM::Agent::Loop;

my $loop = LLM::Agent::Loop.new(
    backends => [$primary, $fallback],   # tried in order, per round trip
    provider => $policy,                 # any tools-for-llm/execute-tool-calls pair
    session  => $session,                # optional, but this is what makes it resumable
    compactor => $compactor,             # optional, needs a context-budget
);

my $run = $loop.run([$system-message, $user-message]);

start react whenever $run.events -> $event {
    given $event {
        when LLM::Agent::Event::Token    { print $event.text }
        when LLM::Agent::Event::ToolCall { note "  -> {$event.name}" }
    }
}

my %outcome = await $run.result;
say %outcome<final>;

=end code

=head1 DESCRIPTION

Everything between "here is a conversation" and "here is the answer": ask
the model, stream what it says, run the tools it asks for, feed the
results back, and go round again until it stops asking. Around that, the
things that make it survive contact with reality — retry, fallback,
inactivity timeouts, cancellation, a transcript that is complete after
every line, and compaction when the conversation outgrows the window.

It is a separate class from L<LLM::Chat::ToolLoop> rather than an
extension of it: that loop is streaming-only, has no cancellation, no
retry and no framing between rounds, and bolting those on would change
its behaviour for every existing user. This one keeps a
C<LLM::Chat::Backend> chain, a duck-typed tool provider, and publishes
one C<Supply> of typed events.

=head2 What plugs into it

=begin table

Attribute      | What it is
===============|=================================================================
backends       | C<LLM::Chat::Backend> chain, tried in order per round trip
provider       | anything with tools-for-llm + execute-tool-calls (or nothing)
counter        | an L<LLM::Agent::TokenCount> (default: C<::Usage>)
session        | an L<LLM::Agent::Session> to write the transcript to
compactor      | an L<LLM::Agent::Compactor>; needs context-budget
context-budget | the window size in tokens

=end table

C<provider> is duck-typed on purpose. An C<MCP::Client>, an
C<MCP::Client::Registry> over several of them, an C<MCP::Client::Policy>
over that, or a hand-rolled object with the two methods — the loop cannot
tell and does not care. B<With no provider the loop is a plain streaming
chat loop>: no tools are declared, and a model that hallucinates a tool
call is answered as if it had not.

The loop stays entirely policy-unaware. It never imports
C<MCP::Client::Policy>, never asks anything, and never decides what is
allowed. What it offers instead is two shims — C<wrap-ask> and
C<log-hook> — that an app wires at construction so that the questions and
the logs a policy or a client produces come out of the same event stream
as everything else. See L</Wiring the shims>.

=head2 One run at a time

C<run> returns a L<LLM::Agent::Run> immediately and does the work behind
it. Calling it again while a run is live B<dies>. That is not a
limitation of the machinery — most of the state is per-run — but a
deliberate refusal to have an opinion about scheduling: how many agents
may talk to one backend at once, whether they queue or run in parallel,
what happens to the second one's tokens, are questions an application (or
a future scheduler) answers. A loop that is one run at a time is a loop
something else can queue.

=head2 A round, step by step

=item B<Compaction check, at the top.> Before spending a request, not
after: a round that ends with six tool results is exactly the round that
blew the budget, and checking on the way in means the next request is the
one that fits. A conversation over C<compactor.trigger> is compacted, the
working array is swapped, a compaction line goes to the session, and
C<CompactionStarted> / C<CompactionDone> frame it.

=item B<The round trip.> C<AttemptStarted>, then a streamed completion,
with C<Token> events as the text arrives. Retry and fallback happen
B<here>, per round trip — see L</Failure>.

=item B<Limits, before anything is committed.> If the model asked for
tools and a limit has been hit, C<LimitReached> is emitted, a system
message in C<ToolLoop>'s exact wording is appended, tools are switched
off, and the round starts again so the model can answer with what it has.

=item B<The assistant turn is committed.> C<AssistantMessage>, appended
to the working array, written to the session (with C<reasoning> and
C<usage> as replay-visible extras).

=item B<Tools.> One C<ToolCall> per call, one batch through the provider,
one C<ToolResult> per result, one C<< role => 'tool' >> message per
result appended to the conversation and to the session.

=item B<Grants.> If the provider C<can('grants')> — a policy does — the
snapshot is compared after each batch, and a changed one is written to
the session so a resumed session does not ask the human again.

No tool calls, or tools switched off: C<RunCompleted>, and the run ends.

=head3 The limit ordering, and the assistant turn it discards

Limits are checked B<before> the assistant turn is committed, and a limit
therefore B<discards> that turn — no C<AssistantMessage>, nothing in the
session. This is C<ToolLoop>'s behaviour and it is not cosmetic: an
assistant message carrying C<tool_calls> that is never followed by the
matching C<tool> messages is a malformed conversation, and every
OpenAI-compatible provider rejects the next request with a 400. The
choice is between losing one sentence of the model's commentary and
losing the run.

=head2 Failure

Every failure is classified by L<LLM::Chat::Retry>'s C<classify-error> —
the same policy L<LLM::Data::Inference::Task> has run in production —
into C<abort>, C<retry-same> or C<advance>:

=begin table

Bucket     | What the loop does
===========|====================================================================
abort      | AttemptFailed, then RunFailed. 4xx will not heal in eight seconds.
retry-same | AttemptFailed with a backoff, sleep, same backend again
advance    | AttemptFailed, next backend in the chain, no wait

=end table

C<max-retries> is the number of B<attempts per backend> (Task's
semantics, not "extra tries"): 3 means one call and two retries before
the chain advances. When the budget runs out, the C<AttemptFailed> says
C<advance>, because C<disposition> reports what the loop B<does> rather
than what the classifier said in the abstract.

When every backend is spent, the run ends with C<RunFailed> carrying the
full C<attempts> list — the same C<< { backend-index, model, error,
raw-text? } >> records C<X::LLM::Chat::Retry::Exhausted> would have
carried.

=head3 Mid-stream failure: what a consumer must do

A backend can fail after streaming four hundred tokens. Those tokens were
emitted; a Supply has no undo. The B<attempt framing> is the contract,
and it is documented in full in L<LLM::Agent::Event> — in short, a
C<Token> belongs to the C<AttemptStarted> that opened it, and an
C<AttemptFailed> B<retracts> every Token since. A consumer that ignores
this renders the model's reply twice.

Nothing a failed attempt streamed reaches the session: only committed
messages are written, so a transcript can never contain half a sentence
the model was in the middle of when a load balancer dropped the
connection.

=head3 The timeout is inactivity, not duration

C<round-trip-timeout> (default 120s) measures the gap since the response
last did B<anything> — C<< $resp.last-activity-at >> — and not the total
time the request has taken.

This is a deliberate divergence from L<LLM::Data::Inference::Task>, which
bounds total duration. Task generates one JSON document per item and a
slow one is a stuck one. An agent turn legitimately runs for minutes: a
reasoning model thinks, a long file is summarised, a big diff is written.
Bounding total time there means killing successful work at the point it
has cost the most. What is never legitimate is a stream that stops
producing tokens and never closes, which is exactly what a dropped
connection behind a proxy looks like, and that is what this catches.

A timeout calls C<< $backend.cancel($resp) >> and is classified as
C<timeout> — which is the C<advance> bucket, so the next backend gets the
turn immediately rather than after a backoff.

=head2 Cancellation

C<< $run.cancel >> is cooperative, and the difference between what is
promised and what is not is worth knowing before you build a UI on it.

B<Promised:>

=item No events after the terminal C<RunCancelled>.

=item The in-flight stream is cancelled at the backend. (Whether that
actually stops the generation upstream is the backend's business — among
the LLM::Chat backends only KoboldCpp really aborts; the others stop
reading.)

=item No further rounds start.

=item A backoff sleep ends within one 0.25s chunk, not at the end of the
backoff.

B<Not promised:>

=item B<Interrupting an in-flight tool batch.> The provider bridge has no
cancellation, so the calls that are running will finish. The loop stops
waiting for them, drains the result and ignores it: no C<ToolResult> is
emitted, and no result reaches the conversation. The run ends promptly;
the C<fs_write> that was already in flight still happened.

What the loop B<does> do on that path is write one synthetic C<tool>
message per abandoned call, saying the run was cancelled before it
returned. That is not a result — it is what keeps the transcript
B<resumable>: an assistant turn carrying C<tool_calls> that nothing
answers is a conversation every OpenAI-compatible provider rejects with a
400, so a cancelled run would otherwise leave a session that can never be
continued.

=item B<Interrupting a blocked permission prompt.> An ask is a leaf: the
policy holds a non-reentrant lock and is waiting for a human. Cancelling
the run cannot dismiss a modal that something else owns. The run ends
when the question is answered.

=head2 Wiring the shims

The loop never talks to a policy, so the app connects them at
construction. Both shims are no-ops when no run is live — a late answer
or a log from a server that had not noticed the run ended is dropped
rather than emitted after the terminal event.

There is a construction cycle to get round: the loop needs the policy (it
is the provider) and the policy needs the loop (the shim comes from it).
B<Forward-declare the loop and defer the shim into a closure> — the same
idiom L<MCP::Client::Policy>'s own Pod uses for its C<elicit-hook>. What
does B<not> work is C<< on-ask => $loop.wrap-ask(&ask) >> with C<$loop>
still undefined: that calls a method on a type object at construction
time and dies there.

=begin code :lang<raku>

my $loop;                                        # named before it exists

# Permission prompts and server elicitations become AskPending /
# AskAnswered events, and still reach the real asker.
my $policy = MCP::Client::Policy.new(
    :$provider,
    on-ask => -> %request { $loop.wrap-ask(&ask-the-human).(%request) },
);

# Server log notifications become Log events. NOTE the log-level: a
# modern MCP server sends NOTHING without one.
my $mcp = MCP::Client.connect-stdio(
    command   => 'mcp-filesystem',
    on-log    => -> %params { $loop.log-hook.(%params) },
    log-level => 'info',
);

$loop = LLM::Agent::Loop.new(:@backends, provider => $policy);

=end code

C<wrap-ask> emits C<AskPending>, calls the real asker (which still
blocks, and still holds the policy's lock), emits C<AskAnswered>, and
returns the answer untouched. An asker that throws is rethrown so the
policy's own handling — refuse this one call, say why — is unchanged;
the C<AskAnswered> is still emitted, so an C<AskPending> is never left
open.

=head2 Tool declarations are fetched once

C<tools-for-llm> is called B<once per run>, not once per round. A round
is a network call, and asking an MCP server to re-list its catalogue
before each of them doubles the round trips for a list that changes
approximately never. A server that adds a tool mid-run is not noticed
until the next run.

=head1 SEE ALSO

L<LLM::Agent::Run>, L<LLM::Agent::Event> (especially the attempt-framing
contract), L<LLM::Agent::Session>, L<LLM::Agent::Compactor>,
L<LLM::Chat::Retry>, L<MCP::Client::Policy>.

=end pod

use JSON::Fast;

use LLM::Chat::Conversation::Message;
use LLM::Chat::Retry;

use LLM::Agent::Event;
use LLM::Agent::Run;
use LLM::Agent::TokenCount;

unit class LLM::Agent::Loop;

#|( What the model is told when a limit stops the tools. C<ToolLoop>'s
    wording, verbatim: it is tuned, it is what models in the wild have
    been trained against, and two agent loops in one ecosystem saying
    different things about the same situation helps nobody. )
our constant LIMIT-MESSAGE =
	'Tool call limit reached. Do not call tools again. Answer using the information already available, and state if more tool work would be needed.';

my constant Message = LLM::Chat::Conversation::Message;

#| The fallback chain, tried in order on every round trip.
has @.backends is required;

#|( The tool provider: anything with C<tools-for-llm> and
    C<execute-tool-calls>. Undefined makes this a plain chat loop. )
has $.provider;

#| The counting seam. Shared with the compactor — see its Pod.
has LLM::Agent::TokenCount:D $.counter = LLM::Agent::TokenCount::Usage.new;

#| The context window in tokens. Taken from the compactor when there is
#| one and this is not set.
has Int $.context-budget;

#| Where the transcript goes. Optional; without one nothing is durable.
has $.session;

#| An L<LLM::Agent::Compactor>, or nothing to never compact.
has $.compactor;

#| Tool rounds before the model is told to answer with what it has.
has Int:D $.max-tool-rounds = 1_000;

#| Total tool calls across the run, same treatment.
has Int:D $.max-tool-calls = 10_000;

#|( How often the same call — same name, same arguments — may be made
    before it counts as a loop. Only B<executed> calls count. )
has Int:D $.max-identical-calls = 3;

#|( Attempts per backend, including the first. Task's semantics: 3 means
    one call and two retries before the chain advances. )
has Int:D $.max-retries = 3;

#|( Seconds of B<inactivity> — not total duration — before a stream is
    given up on. See the Pod on why this differs from Task. )
has Real:D $.round-trip-timeout = 120;

has Lock:D $!lock .= new;
has LLM::Agent::Run $!run;
has $!active-backend;
has $!active-response;

submethod TWEAK {
	die 'LLM::Agent::Loop: backends cannot be empty — there is nothing to '
		~ 'ask'
		unless @!backends.elems;

	with @!backends.first({
		!($_.defined && $_.can('chat-completion-stream') && $_.can('cancel'))
	}, :k) -> $index {
		die "LLM::Agent::Loop: backend $index is a "
			~ @!backends[$index].^name ~ ', which cannot '
			~ 'chat-completion-stream and cancel — a backend has to be an '
			~ 'LLM::Chat::Backend, or shaped like one';
	}

	die 'LLM::Agent::Loop: a provider must have both tools-for-llm and '
		~ 'execute-tool-calls (an MCP::Client, a Registry, a Policy, or '
		~ 'anything shaped like one); got a ' ~ $!provider.^name
		if $!provider.defined
			&& !($!provider.can('tools-for-llm')
				&& $!provider.can('execute-tool-calls'));

	die 'LLM::Agent::Loop: a session must be an LLM::Agent::Session (or '
		~ 'something with its append-message / messages / message-ids '
		~ 'methods); got a ' ~ $!session.^name
		if $!session.defined
			&& !($!session.can('append-message') && $!session.can('messages')
				&& $!session.can('message-ids'));

	if $!compactor.defined {
		die 'LLM::Agent::Loop: a compactor must be an LLM::Agent::Compactor '
			~ '(or something with its trigger / compact / context-budget); '
			~ 'got a ' ~ $!compactor.^name
			unless $!compactor.can('trigger') && $!compactor.can('compact')
				&& $!compactor.can('context-budget');

		# A compactor already knows the budget; carrying it twice only
		# creates a way for the two to disagree.
		$!context-budget //= $!compactor.context-budget;
		die 'LLM::Agent::Loop: context-budget is ' ~ $!context-budget
			~ " but the compactor's is " ~ $!compactor.context-budget
			~ ' — they describe the same window, so set one or make them '
			~ 'agree'
			unless $!context-budget == $!compactor.context-budget;
	}

	die 'LLM::Agent::Loop: round-trip-timeout must be positive'
		unless $!round-trip-timeout > 0;
	die 'LLM::Agent::Loop: max-retries must be at least 1 — it counts '
		~ 'attempts per backend, not extra ones'
		unless $!max-retries >= 1;
	die 'LLM::Agent::Loop: max-identical-calls must be at least 1'
		unless $!max-identical-calls >= 1;
}

# === The public surface ===

#|( Start a run over C<@messages> and hand back its L<LLM::Agent::Run>
    immediately. The array is copied; the Messages in it are not, and are
    never mutated.

    Dies if this loop already has a live run. )
method run(
	@messages where all(@messages) ~~ LLM::Chat::Conversation::Message,
	--> LLM::Agent::Run:D
) {
	die 'LLM::Agent::Loop.run: there is nothing to send — a run starts '
		~ 'from at least one message'
		unless @messages.elems;

	my $run = LLM::Agent::Run.new(on-cancel => { self!poke-cancel });

	$!lock.protect: {
		die 'LLM::Agent::Loop: this loop already has a run in flight. One '
			~ 'run at a time — build a second Loop, or queue them above '
			~ 'this layer'
			if $!run.defined && !$!run.is-done;
		$!run = $run;
	};

	# The working array: our own, so a caller that keeps mutating theirs
	# cannot change the conversation underneath a live run.
	my @conversation = @messages.List;
	my @attempts;

	start {
		{
			CATCH {
				default {
					# A driver that dies without finishing leaves the
					# result Promise Planned forever, and anybody
					# awaiting it hangs. Every exit path finishes.
					my $error = 'LLM::Agent::Loop: the run died: '
						~ (.message.lines.head // .^name);
					$run._finish(
						LLM::Agent::Event::RunFailed.new(
							:$error, attempts => @attempts.List,
						),
						:$error,
						attempts => @attempts.List,
						messages => @conversation,
					);
				}
			}
			self!drive($run, @conversation, @attempts);
		}

		# Belt and braces for a future edit that returns without
		# finishing. Second calls to _finish are no-ops, so this is free.
		unless $run.is-done {
			my $error = 'LLM::Agent::Loop: the run ended without a result';
			$run._finish(
				LLM::Agent::Event::RunFailed.new(
					:$error, attempts => @attempts.List,
				),
				:$error,
				attempts => @attempts.List,
				messages => @conversation,
			);
		}

		self!clear-active;
	}

	$run;
}

#|( An C<on-ask>-shaped wrapper around C<&on-ask>: it emits C<AskPending>,
    calls the real asker, emits C<AskAnswered>, and returns whatever the
    asker returned. An asker that throws is B<rethrown> so a policy's own
    refusal handling is unchanged — and the C<AskAnswered> is emitted
    anyway, so a pending question is never left open.

        # (the loop is forward-declared — see "Wiring the shims")
        MCP::Client::Policy.new(
            :$provider,
            on-ask => -> %request { $loop.wrap-ask(&ask).(%request) },
        );

    With no live run both events are dropped: an answer that arrives
    after the run ended must not appear after its terminal event. )
method wrap-ask(&on-ask --> Callable:D) {
	-> %request {
		my $run = self!live-run;
		my $tool = %request<tool> ~~ Str:D ?? %request<tool>.Str !! Str;

		$run._emit(LLM::Agent::Event::AskPending.new(
			request => %request.Hash, :$tool,
		)) if $run.defined;

		my $answer;
		my $threw;
		{
			CATCH { default { $threw = $_ } }
			$answer = &on-ask(%request);
		}

		$run._emit(LLM::Agent::Event::AskAnswered.new(
			request => %request.Hash,
			answer  => ($threw.defined ?? Nil !! $answer),
		)) if $run.defined;

		$threw.rethrow if $threw.defined;
		$answer;
	};
}

#|( An C<on-log>-shaped closure turning a server's C<notifications/message>
    into C<Log> events:

        MCP::Client.new(..., on-log => $loop.log-hook, log-level => 'info');

    B<Set C<log-level>.> Since the 2026-07-28 revision a modern MCP
    server sends no log notifications at all to a request that did not
    carry one, so an C<on-log> hook without a C<log-level> is a hook that
    never fires — and it looks exactly like a server that has nothing to
    say.

    C<data> is passed through when it is text or a structured record and
    stringified otherwise, so a server with an odd idea of a log line
    cannot break the event's type. )
method log-hook(--> Callable:D) {
	-> %params {
		my $run = self!live-run;
		# `if`, not an early return: this is a Block, and returning from
		# one dies rather than exiting it.
		if $run.defined {
			my $data = %params<data>;
			$data = $data ~~ Associative ?? $data.Hash !! ($data // '').Str;

			$run._emit(LLM::Agent::Event::Log.new(
				level  => (%params<level> // 'info').Str,
				logger => (%params<logger> ~~ Str:D ?? %params<logger>.Str !! Str),
				data   => $data,
			));
		}
	};
}

#| The run in flight, or an undefined Run. Poll-friendly and lock-safe.
method live-run(--> LLM::Agent::Run) {
	self!live-run;
}

method !live-run(--> LLM::Agent::Run) {
	my $run = $!lock.protect: { $!run };
	$run.defined && !$run.is-done ?? $run !! LLM::Agent::Run;
}

# === The state machine ===

method !drive($run, @conversation, @attempts --> Nil) {
	$run._emit(LLM::Agent::Event::RunStarted.new(
		run-id => $run.id, message-count => @conversation.elems,
	));

	my @ids = self!seed-session(@conversation);

	my Bool $tools-enabled = $!provider.defined;
	# Once per run, not once per round: see the Pod.
	my @tools = $tools-enabled ?? $!provider.tools-for-llm.list.List !! ();
	$tools-enabled = False unless @tools.elems;

	my Int $round = 0;
	my Int $tool-rounds = 0;
	my Int $total-calls = 0;
	my Int $grants-known = self!grant-count;
	my %call-counts;
	my Str $final = '';

	loop {
		if $run.is-cancelled {
			self!cancel($run, 'start', $round, @conversation);
			return;
		}

		$round++;

		self!maybe-compact($run, @conversation, @ids, $round);
		if $run.is-cancelled {
			self!cancel($run, 'compaction', $round, @conversation);
			return;
		}

		$run._emit(LLM::Agent::Event::RoundStarted.new(
			:$round,
			tokens => (self!budgeted
				?? $!counter.count-messages(@conversation)
				!! Int),
		));

		my %trip = self!round-trip(
			$run, @conversation, ($tools-enabled ?? @tools !! ()),
			$round, @attempts,
		);

		if %trip<cancelled> {
			self!cancel($run, %trip<stage> // 'streaming', $round, @conversation);
			return;
		}

		unless %trip<ok> {
			my $error = %trip<error>;
			$run._finish(
				LLM::Agent::Event::RunFailed.new(
					:$error, attempts => @attempts.List, :$round,
				),
				:$error, attempts => @attempts.List, messages => @conversation,
			);
			return;
		}

		my $resp = %trip<response>;
		my @tool-calls = ($tools-enabled ?? $resp.tool-calls.list !! ()).List;

		# Limits BEFORE the turn is committed. See the Pod: an assistant
		# message carrying tool_calls with no matching tool messages is a
		# conversation every provider rejects.
		if @tool-calls.elems {
			my %limit = self!limit-reason(
				@tool-calls, $tool-rounds, $total-calls, %call-counts,
			);
			if %limit.elems {
				$run._emit(LLM::Agent::Event::LimitReached.new(|%limit));
				my $notice = Message.new(
					role => 'system', content => LIMIT-MESSAGE,
				);
				@conversation.push: $notice;
				@ids.push: self!record($notice);
				$tools-enabled = False;
				next;
			}
		}

		my $assistant = Message.new(
			role       => 'assistant',
			content    => ($resp.msg // '').Str,
			|(@tool-calls.elems ?? (tool-calls => @tool-calls) !! ()),
		);
		@conversation.push: $assistant;
		@ids.push: self!record($assistant, extra => assistant-extras($resp));
		$final = $assistant.content;

		$run._emit(LLM::Agent::Event::AssistantMessage.new(
			message   => $assistant,
			reasoning => $resp.reasoning-text,
			:$round,
		));

		unless @tool-calls.elems {
			$run._finish(
				LLM::Agent::Event::RunCompleted.new(
					final         => $final,
					rounds        => $round,
					message-count => @conversation.elems,
				),
				final => $final, messages => @conversation,
			);
			return;
		}

		for @tool-calls -> $call {
			my $signature = tool-call-signature($call);
			%call-counts{$signature} = (%call-counts{$signature} // 0) + 1;
			$run._emit(LLM::Agent::Event::ToolCall.new(
				id        => call-id($call),
				name      => call-name($call),
				arguments => call-arguments($call),
				:$round,
			));
		}

		my %batch = self!execute($run, @tool-calls);
		if %batch<cancelled> {
			# The assistant turn asking for these calls is already
			# committed, and an assistant message carrying tool_calls
			# that nothing answers is a conversation no provider will
			# accept. Close them off before ending, so the transcript
			# this run leaves behind is one the next run can resume from.
			self!close-pending-calls(@conversation, @ids, @tool-calls);
			self!cancel($run, 'tools', $round, @conversation);
			return;
		}

		for %batch<results>.list.kv -> $index, %result {
			my $call     = @tool-calls[$index];
			my $id       = (%result<tool_call_id> // call-id($call)).Str;
			my $content  = (%result<content> // '').Str;
			my $is-error = ?%result<is_error>;

			$run._emit(LLM::Agent::Event::ToolResult.new(
				:$id, name => call-name($call), :$content, :$is-error, :$round,
			));

			my $message = Message.new(
				role => 'tool', :$content, tool-call-id => $id,
			);
			@conversation.push: $message;
			@ids.push: self!record(
				$message, extra => ($is-error ?? %( 'is-error' => True ) !! %()),
			);
		}

		$total-calls += @tool-calls.elems;
		$tool-rounds++;
		$grants-known = self!sync-grants($grants-known);
	}
}

# One round trip's worth of retry and fallback. Returns
# { ok, response } / { ok => False, error } / { cancelled, stage }.
method !round-trip(
	$run, @conversation, @tools, Int:D $round, @attempts,
	--> Hash:D
) {
	my Int $attempt = 0;

	for @!backends.kv -> Int $backend-index, $backend {
		my Str $model = model-of($backend);
		# Task's semantics: max-retries counts ATTEMPTS on this backend,
		# so the retry budget is one less than that.
		my Int $retries-left = $!max-retries > 0 ?? $!max-retries - 1 !! 0;

		loop {
			return %( cancelled => True, stage => 'streaming' )
				if $run.is-cancelled;

			$attempt++;
			$run._emit(LLM::Agent::Event::AttemptStarted.new(
				:$round, :$attempt, :$backend-index, :$model,
			));

			my $started = now;
			my %stream = self!stream(
				$run, $backend, @conversation, @tools, $round, $attempt,
			);
			my $resp = %stream<response>;

			return %( cancelled => True, stage => 'streaming' )
				if $run.is-cancelled;

			if $resp.is-success {
				$!counter.record-usage(
					prompt-tokens     => $resp.prompt-tokens,
					completion-tokens => $resp.completion-tokens,
					message-count     => @conversation.elems,
				);
				$run._emit(LLM::Agent::Event::AttemptSucceeded.new(
					:$round, :$attempt, :$backend-index,
					model-used    => $resp.model-used,
					finish-reason => $resp.finish-reason,
					usage         => usage-of($resp),
					latency-ms    => ((now - $started) * 1000).Int,
				));
				return %( ok => True, response => $resp );
			}

			my Bool $timed-out = ?%stream<timed-out>;
			my Str $error = "[backend $backend-index] " ~ ($timed-out
				?? "no activity for {$!round-trip-timeout}s"
				!! ($resp.err // 'the completion stream failed').Str);
			my Str $error-class  = $timed-out ?? 'timeout' !! $resp.error-class;
			my Int $error-status = $timed-out ?? Int !! $resp.error-status;

			@attempts.push: attempt-record(
				:$backend-index, :$model, :$error,
				# Only when there is something worth keeping: an empty
				# raw-text would make a connection failure look like a
				# model that answered with nothing.
				|($resp.latest.chars ?? (raw-text => $resp.latest) !! ()),
			);

			my Str $disposition = classify-error(:$error-class, :$error-status);

			if $disposition eq 'abort' {
				$run._emit(LLM::Agent::Event::AttemptFailed.new(
					:$round, :$attempt, :$backend-index, :$model,
					:$error, :$error-class, :$error-status,
					disposition => 'abort',
				));
				return %( ok => False, error => $error );
			}

			if $disposition eq 'retry-same' && $retries-left > 0 {
				my Int $retry-n = $!max-retries - $retries-left;
				my Num $backoff = retry-backoff($retry-n);
				$retries-left--;

				$run._emit(LLM::Agent::Event::AttemptFailed.new(
					:$round, :$attempt, :$backend-index, :$model,
					:$error, :$error-class, :$error-status,
					disposition => 'retry-same', :$backoff,
				));

				return %( cancelled => True, stage => 'backoff' )
					unless sleep-with-cancel(
						$backoff, cancelled => { $run.is-cancelled },
					);
				next;
			}

			# Either the bucket said advance, or the retry budget for this
			# backend is spent. `disposition` reports what the loop DOES.
			$run._emit(LLM::Agent::Event::AttemptFailed.new(
				:$round, :$attempt, :$backend-index, :$model,
				:$error, :$error-class, :$error-status,
				disposition => 'advance',
			));
			last;
		}
	}

	%(
		ok    => False,
		error => 'every backend failed: '
			~ @attempts.map({ $_<error> }).join('; '),
	);
}

# One streamed attempt, tapped for Tokens and watched for inactivity.
# Returns { response, timed-out }; the response is always settled.
method !stream(
	$run, $backend, @conversation, @tools, Int:D $round, Int:D $attempt,
	--> Hash:D
) {
	my $resp = @tools.elems
		?? $backend.chat-completion-stream(@conversation, tools => @tools)
		!! $backend.chat-completion-stream(@conversation);

	$!lock.protect: {
		$!active-backend  = $backend;
		$!active-response = $resp;
	};

	my Int $emitted = 0;
	my $settled = Promise.new;
	my $vow = $settled.vow;
	my &wake = { $vow.keep(True) if $settled.status ~~ Planned };

	my $tap = $resp.supply.tap(
		-> $chunk {
			my Str $text = ($chunk // '').Str;

			# Catch-up. This tap is installed after the Response's own
			# (which BUILD wires to accumulate `.latest`), so a fragment
			# emitted in the moment between the backend handing the
			# Response back and this tap existing reached `.latest` and
			# nothing else. On the first fragment we DO see, `.latest` is
			# exactly (lost prefix ~ this fragment) — the Response's tap
			# ran first — so the prefix is recoverable, once, in order.
			# Without this, "concatenating the Tokens of a committed
			# attempt reproduces the assistant's text" would be a promise
			# the Event Pod makes and a race quietly breaks.
			if $emitted == 0 {
				my Str $seen = $resp.latest;
				if $seen.chars > $text.chars {
					my Str $prefix =
						$seen.substr(0, $seen.chars - $text.chars);
					$run._emit(LLM::Agent::Event::Token.new(
						text => $prefix, :$round, :$attempt,
					));
					$emitted += $prefix.chars;
				}
			}

			if $text.chars {
				$run._emit(LLM::Agent::Event::Token.new(
					text => $text, :$round, :$attempt,
				));
				$emitted += $text.chars;
			}
		},
		done => &wake,
		quit => -> $ { wake() },
	);

	# Wake often enough to notice a cancel or a stall promptly, and never
	# so often that a two-minute timeout is a busy loop.
	my Num $poll = max(0.005e0, min(0.05e0, ($!round-trip-timeout / 20).Num));
	my Bool $timed-out = False;

	until $resp.is-done {
		await Promise.anyof($settled, $run.cancellation, Promise.in($poll));
		last if $resp.is-done;

		if $run.is-cancelled {
			try $backend.cancel($resp);
			last;
		}

		if (now - $resp.last-activity-at) > $!round-trip-timeout {
			$timed-out = True;
			try $backend.cancel($resp);
			last;
		}
	}

	$tap.close;
	self!clear-active;

	# The whole stream can land before the tap exists, in which case the
	# catch-up above never ran at all.
	if $emitted == 0 && $resp.latest.chars {
		$run._emit(LLM::Agent::Event::Token.new(
			text => $resp.latest, :$round, :$attempt,
		));
	}

	%( response => $resp, 'timed-out' => $timed-out );
}

#|( The tool batch, in its own C<start> so a cancel does not have to wait
    for it. Returns C<< { cancelled } >> or C<< { results } >> with
    exactly one well-formed result per call, in the caller's order. )
method !execute($run, @tool-calls --> Hash:D) {
	my $batch = start { $!provider.execute-tool-calls(@tool-calls) };

	await Promise.anyof($batch, $run.cancellation);

	if $batch.status ~~ Planned {
		# Cancelled with the batch still running. The bridge has no
		# cancellation, so it will finish on its own; we stop waiting and
		# consume the outcome so a failure inside it is not reported as
		# an unhandled broken Promise minutes later, in a run that has
		# already ended.
		$batch.then({ try { $_.result }; True });
		return %( cancelled => True );
	}

	my @answers;
	my $threw;
	{
		CATCH { default { $threw = $_ } }
		@answers = $batch.result.list;
	}

	# ToolLoop's belt and braces. A well-behaved provider never throws;
	# one that does becomes an is_error result per call rather than an
	# exception that takes the run down.
	return %(
		cancelled => False,
		results   => @tool-calls.map(-> $call {
			%(
				role         => 'tool',
				tool_call_id => call-id($call),
				content      => 'The tool provider failed: '
					~ ($threw.message.lines.head // $threw.^name),
				is_error     => True,
			);
		}).List,
	) if $threw.defined;

	%( cancelled => False, results => normalize-results(@tool-calls, @answers) );
}

#|( Answer every call of an abandoned batch with a synthetic C<tool>
    message, in the conversation and in the transcript.

    B<Not> a C<ToolResult> event: nothing came back, and inventing one
    would tell a UI the tool answered. What this is for is the wire — an
    assistant turn with C<tool_calls> and no matching C<tool> messages is
    rejected by every OpenAI-compatible provider, so a run cancelled
    mid-batch would otherwise leave a transcript that cannot be resumed. )
method !close-pending-calls(@conversation, @ids, @tool-calls --> Nil) {
	for @tool-calls -> $call {
		my $message = Message.new(
			role         => 'tool',
			content      => 'The run was cancelled before this tool call '
				~ 'returned. Whether it took effect is unknown.',
			tool-call-id => call-id($call),
		);
		@conversation.push: $message;
		@ids.push: self!record(
			$message, extra => %( 'is-error' => True, cancelled => True ),
		);
	}
	Nil;
}

# === Limits ===

method !limit-reason(
	@tool-calls, Int:D $tool-rounds, Int:D $total-calls, %call-counts,
	--> Hash:D
) {
	return %(
		limit => 'tool-rounds', count => $tool-rounds, max => $!max-tool-rounds,
	) if $tool-rounds >= $!max-tool-rounds;

	return %(
		limit => 'tool-calls',
		count => $total-calls + @tool-calls.elems,
		max   => $!max-tool-calls,
	) if $total-calls + @tool-calls.elems > $!max-tool-calls;

	for @tool-calls -> $call {
		my $signature = tool-call-signature($call);
		return %(
			limit => 'identical-calls',
			count => (%call-counts{$signature} // 0),
			max   => $!max-identical-calls,
		) if (%call-counts{$signature} // 0) >= $!max-identical-calls;
	}

	%();
}

# === Compaction ===

method !budgeted(--> Bool:D) {
	$!compactor.defined || $!context-budget.defined;
}

method !maybe-compact($run, @conversation, @ids, Int:D $round --> Nil) {
	return unless $!compactor.defined;

	my Int $tokens = $!counter.count-messages(@conversation);
	return unless $tokens > $!compactor.trigger;

	$run._emit(LLM::Agent::Event::CompactionStarted.new(
		tokens-before => $tokens,
		budget        => $!context-budget,
		message-count => @conversation.elems,
		:$round,
	));

	my %result = $!compactor.compact(
		@conversation, cancelled => { $run.is-cancelled },
	);

	if %result<dropped> == 0 {
		# Nothing between the sticky prefix and the recent window. Said
		# out loud rather than silently, because it means the budget is
		# too small for keep-recent and somebody should know.
		$run._emit(LLM::Agent::Event::CompactionDone.new(
			tokens-before => %result<tokens-before>,
			tokens-after  => %result<tokens-after>,
			dropped       => 0,
			fallback      => ?%result<fallback>,
			:$round,
		));
		return;
	}

	my Int $cut = %result<cut-index>;
	my Str $summary-id;
	with $!session {
		# NB the unquoted key: a QUOTED fat-arrow key in an argument list
		# is a positional Pair, not a named argument, and the call fails
		# with "too many positionals" several frames from here.
		$summary-id = .append-compaction(
			summary             => %result<summary>,
			replaces-through-id => @ids[$cut],
			tokens-before       => %result<tokens-before>,
			tokens-after        => %result<tokens-after>,
			fallback            => ?%result<fallback>,
		);
	}

	# The same transformation the compactor applied, over the parallel id
	# array. If these two ever disagree, a resumed session would replay a
	# different conversation than the one the run was working with — so
	# they are checked rather than trusted.
	my @new-ids = (0 .. $cut)
		.grep({ @conversation[$_].is-sticky })
		.map({ @ids[$_] });
	@new-ids.push: $summary-id;
	@new-ids.append: @ids[$cut + 1 .. *-1] if $cut + 1 < @ids.elems;

	die 'LLM::Agent::Loop: the compaction produced '
		~ %result<messages>.elems ~ ' messages but ' ~ @new-ids.elems
		~ ' ids — LLM::Agent::Compactor and LLM::Agent::Loop disagree '
		~ 'about what a compaction keeps, and a resumed session would '
		~ 'replay a different conversation'
		unless @new-ids.elems == %result<messages>.elems;

	@conversation.splice(0, @conversation.elems);
	@conversation.append: %result<messages>.list;
	@ids.splice(0, @ids.elems);
	@ids.append: @new-ids;

	$run._emit(LLM::Agent::Event::CompactionDone.new(
		tokens-before => %result<tokens-before>,
		tokens-after  => %result<tokens-after>,
		dropped       => %result<dropped>,
		summary       => %result<summary>,
		fallback      => ?%result<fallback>,
		:$round,
	));

	Nil;
}

# === Session ===

# The ids of @conversation, appending whatever the session does not have.
method !seed-session(@conversation --> Array) {
	my @ids;
	return @ids unless $!session.defined;

	my @known = $!session.messages.list;
	my @known-ids = $!session.message-ids.list;

	die 'LLM::Agent::Loop: the session already holds ' ~ @known.elems
		~ ' messages but this run was given ' ~ @conversation.elems
		~ ' — a session is a transcript, so a run has to extend it rather '
		~ 'than rewrite it. Start from $session.messages'
		if @conversation.elems < @known.elems;

	for @known.kv -> Int $index, $known {
		my $mine = @conversation[$index];
		die "LLM::Agent::Loop: message $index of this run is a '"
			~ $mine.role ~ "' but the session recorded a '" ~ $known.role
			~ "' there — a run extends its session's transcript, it does "
			~ 'not rewrite it. Start from $session.messages'
			unless $mine.role eq $known.role
				&& ($mine.content // '') eq ($known.content // '');
		@ids.push: @known-ids[$index];
	}

	for @conversation[@known.elems .. *-1] -> $message {
		@ids.push: $!session.append-message($message);
	}

	@ids;
}

method !record($message, :%extra --> Str) {
	$!session.defined
		?? $!session.append-message($message, :%extra)
		!! Str;
}

# === Grants ===

method !grant-count(--> Int:D) {
	my @grants = self!grant-snapshot;
	@grants.defined ?? @grants.elems !! 0;
}

method !sync-grants(Int:D $known --> Int:D) {
	my @grants = self!grant-snapshot;
	return $known unless @grants.defined;
	return $known if @grants.elems == $known;

	$!session.append-grants(@grants) with $!session;
	@grants.elems;
}

# The provider's grants, or an undefined Array when it has none to give
# (no provider, no `grants` method, or one that threw — a policy that
# cannot report its grants must not take the run down).
method !grant-snapshot(--> Array) {
	return Array unless $!provider.defined && $!provider.can('grants');

	my @grants;
	my $threw;
	{
		CATCH { default { $threw = $_ } }
		@grants = $!provider.grants.list;
	}
	$threw.defined ?? Array !! @grants;
}

# === Cancellation ===

method !cancel($run, Str:D $stage, Int:D $round, @conversation --> Nil) {
	$run._finish(
		LLM::Agent::Event::RunCancelled.new(
			:$stage, round => ($round > 0 ?? $round !! Int),
		),
		messages => @conversation,
	);
	Nil;
}

# The Run's on-cancel hook: poke the in-flight stream so a cancel does not
# wait out a poll interval (and, on a backend that really aborts, stops
# the generation upstream).
method !poke-cancel(--> Nil) {
	my ($backend, $resp) = $!lock.protect: {
		($!active-backend, $!active-response);
	};
	try $backend.cancel($resp) if $backend.defined && $resp.defined;
	Nil;
}

method !clear-active(--> Nil) {
	$!lock.protect: {
		$!active-backend  = Nil;
		$!active-response = Nil;
	};
	Nil;
}

# === Plain helpers ===

#|( C<ToolLoop>'s exact signature scheme: name, a NUL, and the arguments
    as they arrived. The NUL is what keeps C<< read("a\0b") >> from
    colliding with C<< read\0("a", "b") >>; no tool name or JSON document
    contains one. )
my sub tool-call-signature($call --> Str:D) {
	my $function = $call ~~ Associative ?? $call<function> !! Any;
	my $name = $function ~~ Associative ?? ($function<name> // '') !! '';
	my $arguments = $function ~~ Associative ?? ($function<arguments> // '') !! '';
	$arguments = to-json($arguments) if $arguments ~~ Associative;
	"$name\0$arguments";
}

my sub call-id($call --> Str:D) {
	(($call ~~ Associative ?? $call<id> !! Str) // '').Str;
}

my sub call-name($call --> Str:D) {
	my $function = $call ~~ Associative ?? $call<function> !! Any;
	(($function ~~ Associative ?? $function<name> !! Str) // '').Str;
}

my sub call-arguments($call) {
	my $function = $call ~~ Associative ?? $call<function> !! Any;
	my $arguments = $function ~~ Associative ?? $function<arguments> !! Nil;
	$arguments ~~ Associative ?? $arguments.Hash
		!! ($arguments.defined ?? $arguments.Str !! Str);
}

# What a backend calls itself. Duck-typed: `.model` is a convention among
# the LLM::Chat backends rather than part of the base class.
my sub model-of($backend --> Str:D) {
	((try $backend.model) // 'unknown').Str;
}

my sub usage-of($resp --> Hash:D) {
	my %usage;
	%usage<prompt-tokens>     = $resp.prompt-tokens     if $resp.prompt-tokens.defined;
	%usage<completion-tokens> = $resp.completion-tokens if $resp.completion-tokens.defined;
	%usage<total-tokens>      = $resp.total-tokens      if $resp.total-tokens.defined;
	%usage;
}

# The replay-visible extras of a committed assistant turn: what it was
# thinking, and what it cost.
my sub assistant-extras($resp --> Hash:D) {
	my %extra;
	%extra<reasoning> = $resp.reasoning-text if $resp.reasoning-text.defined;
	my %usage = usage-of($resp);
	%extra<usage> = %usage if %usage.elems;
	%extra;
}

# Exactly one well-formed result per call, in the caller's order. A
# provider that came up short (or answered with a bare string) is
# normalised the way MCP::Client::Registry and MCP::Client::Policy
# normalise theirs, so the conversation always has a `tool` message for
# every `tool_calls` entry — which is what keeps the NEXT request valid.
my sub normalize-results(@tool-calls, @answers --> List) {
	@tool-calls.kv.map(-> Int $index, $call {
		my $answer = @answers[$index];

		with $answer {
			my %result = $answer ~~ Associative
				?? $answer.Hash
				!! %( content => $answer.Str );
			%result<role> = 'tool' unless %result<role>:exists;
			%result<tool_call_id> = call-id($call)
				unless %result<tool_call_id>:exists;
			%result<content> = (%result<content> // '').Str;
			%result<is_error> = ?%result<is_error>;
			%result;
		}
		else {
			%(
				role         => 'tool',
				tool_call_id => call-id($call),
				content      => 'The tool provider returned no result for '
					~ 'this call',
				is_error     => True,
			);
		}
	}).List;
}
