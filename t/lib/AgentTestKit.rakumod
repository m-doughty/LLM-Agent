=begin pod

=head1 NAME

AgentTestKit - scripted backends, scripted tools, and settled-run helpers

=head1 SYNOPSIS

=begin code :lang<raku>

use lib 'lib', 't/lib';
use AgentTestKit;

my $backend = scripted-backend(steps => [
    # round 1: the model asks for a tool
    { chunks => ['Let me look. '], tool-calls => [tool-call('c1', 'fs_read', '{"path":"a"}')] },
    # round 2: it answers, and the provider says what it was billed
    { chunks => ['The file says hello.'], usage => { prompt => 812, completion => 9 } },
]);

my $provider = ScriptedProvider.new(
    tools   => [tool-decl('fs_read', 'Read a file', { path => { type => 'string' } })],
    results => { fs_read => 'hello' },
);

my $run = $loop.run([msg('user', 'what is in a?')]);
run-settled($run, 'the scripted run');
my @events = drain-events($run);

is $backend.recorded-calls.elems, 2, 'two round trips';
is $provider.recorded-calls.elems, 1, 'one tool call';

=end code

=head1 DESCRIPTION

Everything the agent tests need in order to drive a loop without a
network, a model, or a clock they do not control.

It is deliberately B<not> C<LLM::Chat::Backend::Mock>: that mock exists to
prove LLM::Chat's own behaviour and widening it to script mid-stream
failures, stalls and per-attempt usage would be changing one dist's test
surface to suit another's. This kit is free to be as strict and as
purpose-built as the agent tests need.

=head2 ScriptedBackend

A real C<LLM::Chat::Backend> subclass driven by a list of B<steps>: one
step is consumed per call, in order, by both C<chat-completion-stream> and
C<chat-completion>. Every step key is optional.

=begin table

Key                 | Effect
====================|=====================================================================
chunks              | List of fragments to emit, in order
content             | Shorthand for a single-fragment C<chunks>
tool-calls          | List of wire-shaped calls; also sets finish-reason to 'tool_calls'
finish-reason       | Overrides the finish reason ('stop', or 'tool_calls' with tool-calls)
usage               | C<< { prompt, completion, total, model } >>, any subset
error               | Message the call fails with, AFTER emitting whatever chunks it had
error-class         | 'http' / 'timeout' / 'connection' / 'response' (default 'unknown')
error-status        | HTTP status, for error-class 'http'
delay               | Seconds to wait before the first fragment
chunk-delay         | Seconds to wait between fragments
fail-after-chunks   | Emit only this many fragments, then fail
stall               | Emit the fragments and then go silent — no done, no quit, ever

=end table

C<stall> is what an inactivity timeout is tested against: the response
never reaches a terminal state on its own, C<last-activity-at> stops
advancing, and the loop is expected to notice, call C<cancel> (which the
backend records) and move on. It is streaming-only; a blocking call on a
stalled step throws rather than hanging the suite forever.

=head3 One step, one trailing comma

C<steps => [{ chunks => ['hi'] }]> is B<not> a one-step script: Raku's
single-argument rule flattens a lone Hash in a list into its Pairs, so
that reads as three steps of one key each and the failure surfaces
somewhere else entirely. Write C<steps => [{ chunks => ['hi'] },]> — the
trailing comma is the whole fix. The same applies to a step's
C<tool-calls> and to a provider's C<tools>.

The kit checks for it rather than letting it happen: a list of Pairs where
hashes were expected dies immediately, with that advice.

Running out of steps is an B<error>, not an empty response: the backend
answers with an C<error-class> of 'response' saying which call it was.
A test whose loop went round more times than it scripted should say so
rather than quietly pass.

Everything is recorded: C<.recorded-calls> (messages, tools, the step
used, and whether it was streaming), and C<.cancelled-responses> (the
Responses C<cancel> was called on, in order).

=head2 ScriptedProvider

The duck-typed tool provider — C<tools-for-llm> and C<execute-tool-calls>,
the same pair C<MCP::Client>, C<MCP::Client::Registry> and
C<MCP::Client::Policy> present, so a scripted provider can be dropped
under a real Policy in an integration test.

Like the real ones, C<execute-tool-calls> B<never throws>: a malformed
call, an unknown tool and a responder that died all come back as
C<is_error> results, one per call, in the caller's order.

C<block-on> is a Promise the batch waits on before returning — a blocked
tool round (a permission prompt nobody has answered yet) without needing a
real one.

C<grants> is deliberately absent from C<ScriptedProvider> and present on
C<ScriptedProviderWithGrants>, because the loop decides whether to
synchronise grants with C<.can('grants')>. A single class with an
always-present method could not test both sides of that branch.

=head2 run-settled / drain-events

C<run-settled> B<polls> C<is-done> rather than awaiting the result
Promise, and C<drain-events> taps the event Supply exactly B<once>. Both
follow the lesson recorded in LLM-Chat's ChatTestKit: a scripted run can
finish before the test gets to it, and a fresh tap on an
already-finished stream never receives the C<done> it is waiting for. So:
poll for completion, tap once, and give up loudly after
C<TIMEOUT> seconds instead of hanging the suite.

=end pod

use JSON::Fast;

use LLM::Chat::Backend;
use LLM::Chat::Backend::Response;
use LLM::Chat::Backend::Response::Stream;
use LLM::Chat::Backend::Settings;
use LLM::Chat::Conversation::Message;

use LLM::Agent::Run;

unit module AgentTestKit;

#| How long any wait here may take before it is called a failure rather
#| than a slow machine.
constant TIMEOUT is export = 30;

# Raku's single-argument rule turns `[ %h ]` into a list of that hash's
# PAIRS, so a one-step script (`steps => [{ chunks => [...] }]`) silently
# becomes several steps of one key each, and a one-call `tool-calls => [ %c ]`
# becomes three malformed calls. Both failures look like a bug in the code
# under test rather than in the script, so every list-of-hashes the kit
# accepts goes through here and says so instead.
my sub hashes-or-die(@items, Str:D $what --> List) {
	# NB: no braces in this message. A literal brace pair inside a
	# double-quoted Raku string is an interpolated BLOCK, and one
	# containing a yada throws "Stub code executed" from the error path
	# itself — which is a memorable way to lose an afternoon.
	die "AgentTestKit: $what contains Pairs, which means a single Hash hit "
		~ "Raku's single-argument rule: a lone hash inside square brackets "
		~ "flattens into that hash's pairs. Add a trailing comma - "
		~ 'steps => [ %step, ] - or pass a List of two or more hashes.'
		if @items.first({ $_ ~~ Pair });

	# :k, not the value — an undefined entry is exactly the kind of thing
	# worth catching, and it would test as "no match" by value.
	with @items.first({ $_ !~~ Associative }, :k) -> $index {
		die "AgentTestKit: every entry of $what must be a Hash; entry "
			~ "$index is a {@items[$index].^name}";
	}

	@items.List;
}

#| A Message, briefly. Extra named arguments (C<:sticky>, C<:sysprompt>,
#| C<:tool-call-id>, C<:tool-calls>) go straight through.
sub msg(Str:D $role, Str:D $content = '', *%extra) is export {
	LLM::Chat::Conversation::Message.new(:$role, :$content, |%extra);
}

#| One wire-shaped tool call, as a provider would receive it. C<$arguments>
#| is the JSON string models actually send.
sub tool-call(
	Str:D $id,
	Str:D $name,
	Str:D $arguments = '{}',
	--> Hash:D
) is export {
	{
		id => $id,
		type => 'function',
		function => { name => $name, arguments => $arguments },
	};
}

#| One tool declaration in C<tools-for-llm> shape.
sub tool-decl(
	Str:D $name,
	Str:D $description = '',
	%properties = {},
	:@required,
	--> Hash:D
) is export {
	{
		type => 'function',
		function => {
			name => $name,
			description => $description,
			parameters => {
				type => 'object',
				properties => %properties,
				|(@required ?? (required => @required.List) !! ()),
			},
		},
	};
}

#|( A backend that replays a script. See the step table in the module Pod.

    Both completion methods consume from the same C<@.steps> list, so a
    test that mixes streaming rounds with a blocking summarization call
    scripts them in one place, in the order they happen. )
class ScriptedBackend is LLM::Chat::Backend is export {
	#| What C<< try { $backend.model } >> finds — the name that ends up on
	#| AttemptStarted events and attempt records.
	has Str:D $.model = 'scripted-model';

	#| The remaining script. Mutable on purpose: a test can push a step
	#| mid-run to react to what the loop did.
	has @.steps is rw;

	#| One entry per completion call: C<< { messages, tools, step, kind,
	#| response-id } >>, where C<kind> is 'stream' or 'blocking'.
	has @.recorded-calls;

	#| The Responses C<cancel> was called on, in order.
	has @.cancelled-responses;

	has Lock:D $!lock .= new;
	has Int $!calls = 0;

	submethod TWEAK(*%) {
		hashes-or-die(@!steps, 'the step script');
	}

	# Consume the next step and record the call. One lock covers both, so
	# two concurrent calls cannot get the same step or record out of order.
	method !take-step(@messages, @tools, Str:D $kind, Str:D $response-id --> Hash:D) {
		$!lock.protect: {
			my $n = ++$!calls;
			# Re-checked here as well as in TWEAK: @.steps is rw, and a
			# test that pushes a step mid-run can hit the same trap.
			hashes-or-die(@!steps.head(1).List, 'the step script') if @!steps.elems;

			my %step = @!steps.elems
				?? @!steps.shift.Hash
				!! %(
					error => "ScriptedBackend: no step scripted for call $n "
						~ "(the loop made more round trips than the test expected)",
					error-class => 'response',
				);

			@!recorded-calls.push: {
				messages => @messages.clone,
				tools => @tools.clone,
				step => %step,
				kind => $kind,
				response-id => $response-id,
			};
			%step;
		};
	}

	# Everything a step says about a finished call, applied in the order
	# the Response contract wants: metadata first, terminal state last.
	method !apply-outcome($resp, %step --> Nil) {
		if %step<tool-calls>:exists && %step<tool-calls>.defined {
			my @calls = %step<tool-calls> ~~ Associative
				?? (%step<tool-calls>,)
				!! %step<tool-calls>.list;
			$resp._set-tool-calls(hashes-or-die(@calls, "a step's tool-calls"));
		}

		$resp._set-finish-reason(
			%step<finish-reason>
				// (%step<tool-calls>.defined ?? 'tool_calls' !! 'stop')
		);

		if %step<usage> ~~ Associative {
			my %usage = %step<usage>;
			my %args;
			%args<prompt>     = %usage<prompt>.Int     if %usage<prompt>.defined;
			%args<completion> = %usage<completion>.Int if %usage<completion>.defined;
			%args<total>      = %usage<total>.Int      if %usage<total>.defined;
			%args<model>      = (%usage<model> // $!model).Str;
			$resp._set-usage(|%args);
		}
	}

	# The failure half of the same: structured error info BEFORE the quit,
	# so a consumer reading the finished response sees both.
	method !apply-error($resp, %step --> Nil) {
		my %info = class => (%step<error-class> // 'unknown').Str;
		%info<status> = %step<error-status>.Int if %step<error-status>.defined;
		$resp._set-error-info(|%info);
		$resp.quit(%step<error> // 'scripted failure');
	}

	# The fragments a step emits, as a list.
	method !chunks-of(%step --> List) {
		return %step<chunks>.list if %step<chunks>.defined;
		return (%step<content>.Str,) if %step<content>.defined;
		();
	}

	method chat-completion-stream(
		@messages where all(@messages) ~~ LLM::Chat::Conversation::Message,
		:@tools,
		--> LLM::Chat::Backend::Response::Stream
	) {
		my $id = 'scripted-stream-' ~ ($!calls + 1);
		my $resp = LLM::Chat::Backend::Response::Stream.new(:$id);
		my %step = self!take-step(@messages, @tools, 'stream', $id);

		start {
			CATCH {
				# A broken script must fail the test, not vanish into a
				# start block nobody awaits.
				default {
					$resp._set-error-info(class => 'response');
					$resp.quit("ScriptedBackend: {.message}");
				}
			}

			sleep %step<delay> if %step<delay>.defined && %step<delay> > 0;

			my @chunks = self!chunks-of(%step);
			my $limit = %step<fail-after-chunks>.defined
				?? %step<fail-after-chunks>.Int
				!! @chunks.elems;

			my Bool $truncated = False;
			for @chunks.kv -> $i, $chunk {
				if $i >= $limit {
					$truncated = True;
					last;
				}
				$resp.emit($chunk.Str) if $chunk.defined && $chunk.Str.chars;
				sleep %step<chunk-delay>
					if %step<chunk-delay>.defined && %step<chunk-delay> > 0;
			}

			if $truncated || (%step<fail-after-chunks>.defined && $limit >= @chunks.elems) {
				self!apply-error($resp, %(
					error => %step<error> // 'scripted mid-stream failure',
					error-class => %step<error-class>,
					error-status => %step<error-status>,
				));
			}
			elsif %step<stall> {
				# Deliberately nothing: no done, no quit. The response sits
				# there with a last-activity-at that stops advancing, which
				# is exactly what an inactivity timeout has to notice.
			}
			elsif %step<error>.defined {
				self!apply-error($resp, %step);
			}
			else {
				self!apply-outcome($resp, %step);
				$resp.done;
			}
		}

		$resp;
	}

	method chat-completion(
		@messages where all(@messages) ~~ LLM::Chat::Conversation::Message,
		:@tools,
		--> LLM::Chat::Backend::Response
	) {
		my $id = 'scripted-blocking-' ~ ($!calls + 1);
		my $resp = LLM::Chat::Backend::Response.new(:$id);
		my %step = self!take-step(@messages, @tools, 'blocking', $id);

		die 'ScriptedBackend: `stall` is a streaming-only step key — a '
			~ 'blocking call cannot stall without hanging the suite'
			if %step<stall>;

		sleep %step<delay> if %step<delay>.defined && %step<delay> > 0;

		if %step<error>.defined {
			self!apply-error($resp, %step);
			return $resp;
		}

		$resp.emit(self!chunks-of(%step).join);
		self!apply-outcome($resp, %step);
		$resp.done;
		$resp;
	}

	#| Records the Response, then cancels it for real — the cancelled
	#| stream ends up C<is-done> and not C<is-success>, as a live one does.
	method cancel(LLM::Chat::Backend::Response $resp) {
		$!lock.protect: { @!cancelled-responses.push: $resp };
		$resp.cancel;
	}
}

#| A ScriptedBackend with a Settings already built. Named arguments go
#| straight to the constructor.
sub scripted-backend(*%args --> ScriptedBackend) is export {
	ScriptedBackend.new(
		settings => LLM::Chat::Backend::Settings.new,
		|%args,
	);
}

#|( The duck-typed tool provider: C<tools-for-llm> plus
    C<execute-tool-calls>, never throwing, fully recorded. )
class ScriptedProvider is export {
	#| The declarations C<tools-for-llm> publishes.
	has @.tools;

	#|( Per tool name: a Str (the content of a successful result) or a
	    Hash merged into the result, so an error can be scripted as
	    C<< { fs_write => { content => 'nope', is_error => True } } >>. )
	has %.results;

	#| Consulted before C<%results> when present:
	#| C<< -> $name, $arguments, $id { ... } >> returning a Str or a Hash.
	#| A responder that throws becomes an is_error result, as a real
	#| provider's would.
	has &.responder;

	#| Awaited before each batch returns — a tool round blocked on
	#| something that has not happened yet.
	has Promise $.block-on;

	#| One entry per batch, each the calls it received.
	has @.recorded-batches;
	#| Every call of every batch, flattened, in order.
	has @.recorded-calls;
	#| How many times the catalogue was asked for.
	has Int $.list-calls = 0;

	has Lock:D $!lock .= new;

	submethod TWEAK(*%) {
		hashes-or-die(@!tools, 'the tool catalogue');
	}

	method tools-for-llm(--> List) {
		$!lock.protect: { $!list-calls++ };
		@!tools.List;
	}

	#|( One result per call, in order, never throwing — the same contract
	    C<MCP::Client> and C<MCP::Client::Policy> have.

	    The single exception is a Pair, which no loop can produce and no
	    provider can answer: that is the single-argument rule again, and it
	    dies with the fix rather than coming back as three malformed
	    results. )
	method execute-tool-calls(@tool-calls --> List) {
		die 'AgentTestKit: execute-tool-calls was handed Pairs — a lone '
			~ 'call hash inside square brackets flattens into its pairs. '
			~ 'Add a trailing comma: [ %call, ]'
			if @tool-calls.first({ $_ ~~ Pair });

		$!lock.protect: {
			@!recorded-batches.push: @tool-calls.List;
			@!recorded-calls.append: @tool-calls.list;
		};

		await $!block-on with $!block-on;

		@tool-calls.map({ self!answer($_) }).List;
	}

	method !answer($call --> Hash:D) {
		return {
			role => 'tool', tool_call_id => '',
			content => 'Malformed tool call: not an object',
			is_error => True,
		} unless $call ~~ Associative;

		my $id = ($call<id> // '').Str;
		my $function = $call<function>;
		my $name = ($function ~~ Associative ?? ($function<name> // '') !! '').Str;
		my $arguments = $function ~~ Associative ?? $function<arguments> !! Str;

		return {
			role => 'tool', tool_call_id => $id,
			content => 'Malformed tool call: no function name',
			is_error => True,
		} unless $name.chars;

		my $answer;
		my $threw;
		{
			CATCH { default { $threw = $_ } }
			$answer = &!responder.defined
				?? &!responder($name, $arguments, $id)
				!! (%!results{$name}:exists ?? %!results{$name} !! "ok: $name");
		}

		return {
			role => 'tool', tool_call_id => $id,
			content => "Tool '$name' failed: {$threw.message}",
			is_error => True,
		} if $threw.defined;

		my %result = role => 'tool', tool_call_id => $id,
			content => '', is_error => False;
		if $answer ~~ Associative {
			%result{$_} = $answer{$_} for $answer.keys;
			%result<content> = (%result<content> // '').Str;
			%result<is_error> = ?%result<is_error>;
		}
		else {
			%result<content> = ($answer // '').Str;
		}
		%result;
	}
}

#|( A ScriptedProvider that also has C<grants> — the optional method the
    loop probes for with C<.can('grants')>. Separate class so both sides
    of that branch are testable. )
class ScriptedProviderWithGrants is ScriptedProvider is export {
	has @!grants;
	has Lock:D $!grant-lock .= new;

	# NB: the *% is load-bearing — TWEAK is handed EVERY named argument
	# that reached .new, so an explicit signature without it rejects
	# `tools => ...` and every other attribute the parent takes.
	submethod TWEAK(:@grants, *%) {
		@!grants = @grants.map({ $_.Hash });
	}

	#| The grant snapshot, as a copy — the same contract
	#| C<MCP::Client::Policy.grants> has.
	method grants(--> List:D) {
		$!grant-lock.protect: { @!grants.map({ $_.Hash }).List };
	}

	#| Grow the snapshot mid-test, as answering a permission prompt would.
	method add-grant(%grant --> Nil) {
		$!grant-lock.protect: { @!grants.push: %grant.Hash };
	}
}

#|( Wait for a Run to finish, by POLLING C<is-done> — never by awaiting a
    fresh tap on a Supply that may already be finished. Dies after
    C<TIMEOUT> seconds rather than hanging the suite. Returns the Run. )
sub run-settled(LLM::Agent::Run:D $run, Str:D $what = 'the run') is export {
	my $deadline = now + TIMEOUT;
	until $run.is-done {
		die "Timed out after {TIMEOUT}s waiting for $what" if now > $deadline;
		sleep 0.002;
	}
	$run;
}

#|( Collect every event of a Run, in order.

    Taps B<once>, which is the only thing that works: the Supply is
    C<Supplier::Preserving>, so the first tap replays the whole run — and
    a second tap on a finished run receives nothing at all, not even the
    C<done>. Call this once per Run, after C<run-settled>. )
sub drain-events(LLM::Agent::Run:D $run, Str:D $what = 'the event stream') is export {
	my @events;
	my $done = Promise.new;
	my $vow = $done.vow;

	my $tap = $run.events.tap(
		-> $event { @events.push: $event },
		done => { $vow.keep(True) },
		quit => -> $ex { $vow.break($ex) },
	);

	await Promise.anyof($done, Promise.in(TIMEOUT));
	if $done.status === Planned {
		$tap.close;
		die "Timed out after {TIMEOUT}s draining $what — either the run "
			~ 'never finished, or something had already tapped this Supply '
			~ '(a Supplier::Preserving delivers its buffer to the FIRST tap '
			~ 'only, and replays nothing to a second one)';
	}
	$tap.close;
	@events.List;
}

#| The events of C<@events> whose kind is C<$kind>, in order.
sub events-of(@events, Str:D $kind --> List) is export {
	@events.grep({ .kind eq $kind }).List;
}

#| Just the kind strings, for asserting whole sequences at a glance.
sub event-kinds(@events --> List) is export {
	@events.map({ .kind }).List;
}
