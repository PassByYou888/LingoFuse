# LF Architecture: experts write the core, AI writes the periphery — why others plus AI still cannot replicate it, however much time they spend

> Chinese version: [LF-Architecture-Unreplicable-Backend-Systems.md](LF-Architecture-Unreplicable-Backend-Systems.md)

## The first-principles premise

A program is not a mathematical conjecture. A program is a finite symbol system and, in theory, can be described completely. If hard mathematical problems can be solved, software systems can certainly be understood completely.

So "unreplicable" is not a logical impossibility. It is **engineering cost that cannot be reached**: the cost of fully describing a system is designed to exceed the cost of redesigning an equivalent one.

## The core mechanism: implicit-contract density

Experts write the core, AI writes the periphery. That division of labour by itself does not create irreplicability. What does is this:

**The expert embeds defensive design in the core but does not write it into the documentation; AI generates the periphery from the surface interface and unknowingly depends on those hidden behaviours.**

This forms an **implicit contract**: the correctness of a peripheral module's behaviour depends on undocumented side effects of the core. The higher the density of implicit contracts, the higher the cost of fully describing the system.

Once implicit-contract density passes a threshold, the replicator faces a choice:

- pay the cost of "living through the operational trauma again" to recover all implicit contracts;
- or accept behavioural non-equivalence.

**This is not unsolvable; it is that the cost of the solution has been designed to exceed that of reinvention.**

## Why AI cannot replicate it

**First, AI-generated periphery introduces new unconscious dependencies.**
A replicator uses AI to generate the periphery and gets another set of "guesses based on the surface interface". That set is not aligned with the original implicit contracts. AI does not know what it depends on, and neither does the replicator.

**Second, implicit contracts cannot be fully recovered by static analysis.**
The core code is readable and so is the peripheral code, but "under which call sequences the periphery depends on which hidden side effect of the core" is not in the code. It lives in the expert's operational memory and in the unstated assumptions made when AI generated the code.

**Third, testing cannot cover the combinatorial space of implicit contracts.**
Distributed testing can only prove that an error exists, never that it does not. The trigger conditions of hidden behaviours depend on particular call sequences and concurrency timings, and that combinatorial space cannot be exhausted. Passing the tests is not the same as recovering the contracts.

**Fourth, after long-term evolution even the expert cannot enumerate them all.**
The periphery keeps being modified by AI and the dependency relationships become chaotic. The expert knows "roughly where the pits are" but cannot write out "all the pits". A replicator who obtains all the code still cannot read out the complete dependency graph.

## Why time is not the remedy

Time lets a replicator read more code, run more tests and ask the expert more questions. But time cannot lower **the ratio between the cost of complete description and the cost of redesign**.

When implicit-contract density is high enough, the cost of fully describing the system ≥ the cost of redesigning an equivalent one. The time a replicator spends is essentially reliving the operational trauma of the original system's evolution. **They are not "replicating"; they are "reinventing", and reinventing with less information.**

## Applied to LF's three classes of systems

**Distributed systems built with LF**: the core's deterministic design relies on the expert's intuition about hardware timing, and AI-generated peripheral code may unknowingly depend on hidden synchronization behaviour of the core. A replicator cannot recover "why this peripheral module must call the core this way".

**AI systems built with LF**: the core's stateful management relies on the expert's anticipation of "where non-determinism leaks", and AI-generated orchestration code may depend on the core's implicit state isolation. A replicator cannot recover "which peripheral logic depends on which hidden isolation".

**Large stateful backends built with LF**: the core's failure-survival design relies on the expert's intuition about "what breaks first", and AI-generated operational code may depend on the core's implicit degradation behaviour. A replicator cannot recover "the complete dependency graph of the degradation chain".

## Falsifiability conditions

Any one of the following would overturn this note's conclusion:

1. A method exists that can fully recover all implicit contracts from core code + peripheral code + documentation in polynomial time, at a cost below redesigning an equivalent system;
2. Someone proves that AI-generated peripheral code has behavioural correctness that does not depend on any undocumented core behaviour;
3. Someone proves that finite testing can cover implicit contracts across all call sequences and concurrency timings.

## Final word

**A replicator can obtain the code but not the expert's "I knew downstream would use it this way" from when the core was written; they can obtain the AI-generated periphery but not the fact that "AI did not know what it depended on". Implicit contracts are not in the code; they sit between the expert's operational memory and AI's unconscious dependencies. Time can buy more information but not the fact that "the information has been designed so that it cannot be obtained cheaply".**


