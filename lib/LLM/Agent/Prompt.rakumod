=begin pod

=head1 NAME

LLM::Agent::Prompt - the four pieces almost every system prompt is made of

=head1 SYNOPSIS

=begin code :lang<raku>

use LLM::Agent::Prompt;

my $system = assemble(
    identity => q:to/END/.trim,
        You are a coding assistant working in a checked-out repository.
        Prefer small, reviewable edits. Never commit.
        END
    sections => [
        env-block(extra => { cwd => $*CWD.Str, branch => $branch }),
        tool-docs($policy.tools-for-llm),
        instructions-from-files([
            'AGENTS.md',
            $*HOME.add('.config/sadna/AGENTS.md').Str,
        ]),
    ],
);

my $run = $loop.run([$system, user-message($question)]);

=end code

Which produces one sticky system Message whose content reads:

=begin code :lang<text>

You are a coding assistant working in a checked-out repository.
Prefer small, reviewable edits. Never commit.

## Environment

- platform: darwin (arm64)
- os: macos 26.3.1
- date: 2026-08-09
- branch: feature/agent-loop
- cwd: /srv/project

## Tools

### fs_read
Read a file from disk.

Parameters:
- path (string, required) - Absolute path of the file to read.
- limit (integer) - Maximum number of lines to return.

## AGENTS.md

Run the test suite with `prove6 -Ilib t/`...

=end code

=head1 DESCRIPTION

Four pure functions. They take what you give them, format it, and return
a string; C<assemble> turns strings into the one C<Message> that goes at
the top of a conversation. There is no configuration, no discovery, no
XDG lookup and no caching — an app knows where its own instruction files
live and under what rules, and this module is deliberately too dumb to
have an opinion about it.

=head2 Nothing is inferred

C<env-block> reports the platform, the OS and today's date, because those
are facts about the process that no caller can be expected to marshal.
Everything else in it comes from C<:%extra>. It does B<not> add the
current directory, the git branch, the project name or the user's shell:
an agent that is told "cwd: /srv/project" when the app actually runs tools
somewhere else has been lied to, and the app is the only layer that knows
the truth. Pass what you know; nothing else appears.

For the same reason C<instructions-from-files> takes explicit paths.
Where an C<AGENTS.md> may come from, whether a parent directory's copy is
merged, whether a user-level file outranks a project one — those are
product decisions, and they belong to the app.

=head2 Determinism

Every function is deterministic given its inputs, apart from
C<env-block>'s date and platform lookups. C<:%extra> keys are rendered in
sorted order rather than hash order, so two runs on the same machine on
the same day produce byte-identical prompts — which is what makes prompt
diffs and cache keys meaningful.

=head1 SUBROUTINES

=head2 env-block(:%extra --> Str)

The C<## Environment> section: C<platform> (kernel name and hardware),
C<os> (distro name and version), C<date> (B<local> date, ISO format —
what "today" means to the human the agent is working with), then every
pair of C<:%extra> in sorted key order.

An extra whose key is one of the three built-ins B<replaces> it, in
place: the caller is closer to the truth than a C<uname> call, and an app
running an agent inside a container has a legitimate reason to say so.
Undefined extra values are dropped, so an optional fact can be passed as
an undefined variable without a conditional at the call site. Values are
stringified with C<.Str>; a Hash value is not rendered as a nested block —
flatten it yourself if you need one.

A platform lookup that fails (an exotic kernel with no C<hardware>) yields
C<unknown> for that part rather than throwing.

=head2 tool-docs(@tools --> Str)

The C<## Tools> section, rendered from the exact
C<< { type => 'function', function => { name, description, parameters } } >>
declarations C<tools-for-llm> returns — so it is documenting what the
model can really call, not a hand-maintained copy that drifts.

Per tool: an C<### name> header, the description on its own line, then
either C<Takes no arguments.> or a C<Parameters:> list of
C<- name (type, required) - description>. A type given as a list
(C<["string", "null"]>) is rendered C<string|null>.

Parameters are ordered B<required first> — in the order the schema's
C<required> array names them, which really is an ordered JSON array —
B<then the rest alphabetically>. Deliberately not the C<properties>
order: that decodes to a plain Raku Hash whose iteration order is
randomised per process, so rendering it as it comes would give the same
tool a different system prompt on every run, and quietly defeat any
prompt cache keyed on the text.

This is a B<summary>, not a substitute for the schema: the model still
receives the full JSON Schema through the API's own tool declarations. Its
job is to make a tool discoverable to a model reading its system prompt,
and to give a backend with no native tool-calling something to work from.

Anything malformed is skipped rather than thrown over: an entry that is
not a hash, a function with no name, a C<parameters> that is not an
object. An empty tool list yields the empty string (not an empty
C<## Tools> header) so it can be passed to C<assemble> unconditionally.

=head2 instructions-from-files(@paths --> Str)

Each path that exists and is a file, in the order given, under an
C<## <basename>> header. Missing paths are skipped silently — an optional
project convention file is expected to be absent.

A path that exists but cannot be read is B<not> skipped: the exception
propagates. That is a misconfiguration (a permission bug, a dangling
symlink), and silently omitting the instructions the operator thinks the
agent is following is worse than failing loudly.

Trailing whitespace is trimmed from each file; an empty file contributes
its header and nothing else, which is a visible signal that it was found
and had nothing to say.

=head2 assemble(Str:D :$identity!, :@sections --> Message)

The finished system message: C<$identity>, then every non-empty section,
joined by blank lines. The Message comes back with C<role => 'system'>,
C<sysprompt => True> and C<sticky => True> — which is what keeps
L<LLM::Agent::Compactor> from ever summarizing away the agent's own
instructions.

Undefined and empty sections are dropped, so a call site can pass
C<tool-docs(@tools)> without first checking whether there are any tools.
An empty C<$identity> throws: an agent with no identity is a
misconfiguration, not a style choice.

=head3 What a baked prompt fossilizes

C<assemble> produces a B<sticky> message, and a sticky message that
reaches a session is written to the transcript, digest-locked by
L<LLM::Agent::Loop>'s seed check and replayed verbatim by every resume
afterwards. That is exactly right for identity, and exactly wrong for
everything C<env-block> and C<instructions-from-files> put beside it: a
transcript resumed in October opens with August's date, August's tool
catalogue and August's C<AGENTS.md>, and nothing in the system will ever
correct it.

So: bake what is true for the life of the conversation, and pass what is
true B<today> as a L<LLM::Agent::RunContext> instead
(C<< $loop.run(@messages, :$context) >>) — same section strings, same
functions, rendered into the request per run rather than into the
conversation once. An app that has moved to a context entirely sends B<no>
system message at all and calls C<assemble> not at all;
C<instructions-from-files> and C<env-block> are just as useful feeding a
context's sections and facts.

=head1 SEE ALSO

L<LLM::Chat::Conversation::Message>, C<LLM::Agent::Loop>,
L<LLM::Agent::RunContext> (the refreshable half, and why a baked prompt
cannot be it).

=end pod

use LLM::Chat::Conversation::Message;

unit module LLM::Agent::Prompt;

# One "- key: value" line, the shape every section here uses.
my sub bullet(Str:D $key, $value --> Str:D) {
	"- $key: {$value.Str}";
}

#|( The C<## Environment> section: platform, os, date, then the caller's
    own pairs in sorted key order. See the module Pod — nothing here is
    inferred beyond the three built-ins, and an extra with a built-in's
    key replaces it in place. )
our sub env-block(:%extra --> Str) is export {
	my $kernel   = (try $*KERNEL.name) // 'unknown';
	my $hardware = (try $*KERNEL.hardware) // 'unknown';
	my $distro   = (try $*DISTRO.name) // 'unknown';
	my $version  = ((try $*DISTRO.version.Str) // '').subst(/^ 'v' /, '');

	my %values =
		platform => "$kernel ($hardware)",
		os       => ($version.chars ?? "$distro $version" !! $distro),
		date     => Date.today.Str,
	;

	# Sorted, so the same facts render the same way every time; undefined
	# values dropped, so an optional fact needs no conditional at the call
	# site.
	my @extra-keys = %extra.keys.grep({ %extra{$_}.defined }).sort;
	%values{$_} = %extra{$_} for @extra-keys;

	my @lines = <platform os date>.map({ bullet($_, %values{$_}) });
	@lines.push: bullet($_, %values{$_})
		for @extra-keys.grep({ $_ ne any(<platform os date>) });

	("## Environment", '', |@lines).join("\n");
}

# The "Parameters:" tail of one tool block, or the no-arguments note.
my sub parameter-lines($parameters --> List) {
	return ('Takes no arguments.',) unless $parameters ~~ Associative;
	my $properties = $parameters<properties>;
	return ('Takes no arguments.',) unless $properties ~~ Associative && $properties.elems;

	my %required = ($parameters<required> ~~ Positional
		?? $parameters<required>.map({ $_.Str => True })
		!! ()).Hash;

	# Required parameters first, in the order the schema's `required`
	# array lists them, then everything else alphabetically. NOT the
	# hash's own order: `properties` decodes to a plain Raku Hash, whose
	# iteration order is randomised per process, so rendering it as-is
	# would give the same tool a different system prompt on every run.
	my @order = (($parameters<required> ~~ Positional
			?? $parameters<required>.map(*.Str)
			!! ())
		.grep({ $properties{$_}:exists }).unique).List;
	@order.append: $properties.keys.grep({ !%required{$_} }).sort;

	my @lines = 'Parameters:';
	for @order -> $property {
		my $schema = $properties{$property};
		my @facts;
		if $schema ~~ Associative {
			my $type = $schema<type>;
			@facts.push: ($type ~~ Positional ?? $type.map(*.Str).join('|') !! $type.Str)
				if $type.defined;
		}
		@facts.push: 'required' if %required{$property};

		my $line = "- $property";
		$line ~= " ({@facts.join(', ')})" if @facts;

		if $schema ~~ Associative {
			my $description = $schema<description>;
			$line ~= " - {$description.Str.trim}"
				if $description.defined && $description.Str.trim.chars;
		}
		@lines.push: $line;
	}
	@lines.List;
}

#|( The C<## Tools> section, rendered from C<tools-for-llm> declarations.
    Malformed entries are skipped; an empty list yields the empty string.
    See the module Pod for the exact layout. )
our sub tool-docs(@tools --> Str) is export {
	my @blocks;

	for @tools -> $tool {
		next unless $tool ~~ Associative;
		my $function = $tool<function>;
		next unless $function ~~ Associative;
		my $name = $function<name>;
		next unless $name ~~ Str:D && $name.chars;

		my @block = "### $name";
		my $description = $function<description>;
		@block.push: $description.Str.trim
			if $description.defined && $description.Str.trim.chars;

		@block.push: '';
		@block.append: parameter-lines($function<parameters>);
		@blocks.push: @block.join("\n");
	}

	return '' unless @blocks;
	("## Tools", '', @blocks.join("\n\n")).join("\n");
}

#|( Every path that exists and is a file, in order, under an
    C<## basename> header. Missing paths are skipped; an unreadable one
    throws. See the module Pod. )
our sub instructions-from-files(@paths --> Str) is export {
	my @blocks;

	for @paths -> $path {
		next unless $path.defined;
		my $io = $path.IO;
		next unless $io.e && $io.f;

		# Deliberately outside a try: a file that is there but unreadable
		# is a misconfiguration, and an agent silently not following the
		# instructions its operator wrote is the worse failure.
		my $content = $io.slurp.trim-trailing;
		@blocks.push: ("## {$io.basename}", '', $content).join("\n").trim-trailing;
	}

	@blocks.join("\n\n");
}

#|( The finished system message: identity, then the non-empty sections,
    joined by blank lines. Sticky and marked as a sysprompt, so compaction
    can never summarize the agent's own instructions away. )
our sub assemble(
	Str:D :$identity!,
	:@sections,
	--> LLM::Chat::Conversation::Message
) is export {
	die 'LLM::Agent::Prompt::assemble: identity cannot be empty — it is '
		~ 'what the agent is, and every other section is context for it'
		unless $identity.trim.chars;

	my @parts = $identity.trim-trailing;
	@parts.append: @sections
		.grep({ $_.defined && $_.Str.trim.chars })
		.map({ $_.Str.trim-trailing });

	LLM::Chat::Conversation::Message.new(
		role      => 'system',
		content   => @parts.join("\n\n"),
		sysprompt => True,
		sticky    => True,
	);
}
