# design

ah's design principles and philosophy.

## identity

ah is an **a**gent **h**arness. most importantly, it is improvable: because
it can be improved and extended, it can become good at many other things.

it is built with [cosmic](https://github.com/whilp/cosmic), a lua
distribution that builds on (a fork of)
[cosmopolitan](https://github.com/jart/cosmopolitan). because it is cosmic,
ah has everything it needs to build tools to do more (sqlite, http, json,
crypto, etc).

## composable

ah is a loop: it takes a prompt, calls tools, and repeats until it's done.
everything else lives outside ah, in the shell and in other tools.

- commands are markdown prompts in `sys/commands/*.md`; invoke with `/<name>`.
- state and context live in the conversation; ah doesn't invent its own
  mechanisms for things the shell already does.
- the minimal CLI surface is the point: it gives other tools (scripts,
  pipelines, cron, other programs) the full power of ah without requiring
  them to know anything about ah.

## embeddable

ah is a portable executable archive. to configure and extend itself, ah
modifies files in its archive. it generally does not rely on external files
(except for authentication), though it can explore its environment and
execute/modify things in the environment.

being embeddable is part of what makes ah portable: copying the ah file
carries with it everything needed to run.

## reliable

ah is reliable because it is tested. it is tested because the code it writes
for itself is testable. the tests themselves are reliable because they are
written first, proving the implementation that follows.

## learnable

ah is learnable because it is small and focused, so there is little to
learn. documentation lives with the thing it documents: inside ah, accessible
from the command line, embedded inline in code.

## general

ah is general. in practice, it should be good at coding and other software
problems. but it can solve other problems by first turning them into software
problems.

## inspiration

ah is inspired by:

- https://github.com/badlogic/pi-mono
- https://github.com/strongdm/attractor
