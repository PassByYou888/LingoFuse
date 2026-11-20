# The right choice, not the choice you want

> Chinese version: [optimal_and_correct_technology_stack_selection.md](optimal_and_correct_technology_stack_selection.md)

Last night my kid had a fever. We took a CT at the emergency room and had to wait an hour for the result. The corridor lights were a cold white, my phone had half a battery left, and I scrolled onto an old piece of news: Anders Hejlsberg had ported the TypeScript compiler from TypeScript to Go.

Who is Hejlsberg? The father of Delphi, the chief designer of C#, the creator of TypeScript. A man who personally wrote C# did not choose C#, nor Rust — the community favourite at the time — when he had to pick a "next home" for TypeScript. He chose Go.

His line, roughly: this is the **right choice**, not the **choice I wanted to make**.

The CT came back; it was a false alarm. But that sentence circled in my head all night.

Because it ran straight into something everyone who writes code faces daily but rarely admits: **when you pick a tech stack, are you choosing "the strongest one", or are you choosing "the right one"?**

---

## Where exactly was that "right choice" right

The community's first reaction was emotional. Rust fans were "devastated", with headlines literally asking "Is Rust over?". The C# community was subtler — Hejlsberg is C#'s father, and the prodigal son was moving house, and not into another son's house either. Someone on Reddit demanded: C# "has almost everything you need", so why not C#? The implication being, do you no longer love the language you wrote?

Hejlsberg did not dodge. None of his reasons was "Go is better than C#" or "Go is stronger than Rust".

What he said was: Go is "the lowest-level language we could get that still has garbage collection". The TypeScript compiler is five hundred thousand lines, and its core style is **functions plus data structures, almost no classes**. C# is heavily object-oriented. Porting TypeScript to C# means bending the shape of the entire codebase into OOP, and the friction cost is "greater than the transition to Go". As for Rust, the team tried; but the existing compiler is built on a great deal of shared mutable data and pointer graphs, and Rust's borrow checker "fights" that architecture; forcing Rust would either bring unacceptable performance or ergonomic trade-offs, or slide into the abyss of "writing your own garbage collector".

Go is not the strongest. Go is **the best shape match**. Hejlsberg's summary: "Our focus is on getting the best results, regardless of which language is used."

Translated: **I was not choosing "which language ranks higher on the leaderboard"; I was choosing "which language lets this five-hundred-thousand-line thing survive with the least structural distortion".**

The result proved it. In the VS Code codebase, type checking went from 77.8 seconds to 7.5 seconds; in Playwright, from 11.1 seconds to 1.1 seconds. A tenfold speed-up — not because Go is ten times faster than C# on some benchmark, but because **after switching to Go, the code was no longer twisted into a shape it never was**.

---

## The "gap" in your hands is the same class of problem Hejlsberg faced

You might say: he is a language father refactoring a compiler, I am filling in one computation module in a business system — how is that the same?

Structurally, it is the same thing.

Every engineering system, at some moment, sprouts a "computational gap". The question is not whether that gap matters, but whether **if the gap is filled with a mismatched technology, the host technology will be forced to distort itself in unacceptable ways**.

Hejlsberg faced a **kernel-type gap**: five hundred thousand lines of compiler logic — type checking, symbol resolution, control-flow analysis — where arithmetic and logical operations themselves make up the bulk of execution time. In such a gap, every indirection of a language's abstraction layer, every paradigm mismatch, is amplified by the sheer volume of iteration and data-structure operations. C#'s OOP paradigm is fine in itself; the problem is that it does not match this particular codebase's "functions plus data structures" shape. Rust's borrow checker is also fine in itself; the problem is that it does not match this codebase's heavy reliance on shared mutable state.

Go's rightness is not that it is "better", but that its **structural cost model** aligns with the shape of the gap: it has a GC, so memory management need not be rewritten; it is functional, so five hundred thousand lines need no paradigm renovation; it is low-level enough to reach native-code performance. Three matches bought a tenfold gain.

But if what you face is an **orchestration-type gap** — a business system that calls an optimization solver once in a while, or a finance system that runs a cash-flow schedule now and then — then the real value of "tenfold kernel performance" in that scenario may be far less important than "no new runtime, no cross-language calls, no extra operational tooling to learn". In that case, filling the gap with the host technology in a "good enough" way is the right choice. **Low difficulty is merely a by-product of that right choice, not its justification.**

Distinguishing the two kinds of gap needs no elaborate decision diagram. Ask two questions:

> **Does the bulk of this gap's execution time go to arithmetic, or to I/O, business logic and state management?**
>
> **When the host technology fills this gap, is it forced to distort the shape of the code, or is it merely not "elegant" enough?**

If the first answer is "arithmetic" and the second is "forced distortion", it is a kernel-type gap and a numerically specialized technology's scope should be confined here. If the first is "business logic", or the second is merely "not pretty but it runs", the host technology is right. Introducing a new runtime for "elegance" trades manageable development cost for unmanageable operational complexity.

---

## The most dangerous choice is not choosing the "slow" one

In the Hejlsberg story, the easiest thing to misread is this: people see "tenfold performance" and conclude "choosing Go was right because Go is fast".

No. Choosing Go was right because **Go is the shape match for that particular gap**. Had the TypeScript compiler originally been written as heavily OOP code depending on inheritance hierarchies, Hejlsberg's choice might have been entirely different. There is no fixed answer to the right choice, only a fixed **way of judging**.

This is the most counter-intuitive and most easily overlooked truth in tech-stack selection:

> **The most dangerous choice is never "choosing the slower technology". The most dangerous choice is using a technology in a position where its structural advantages will not be cashed in, while still bearing its structural costs.**

You can introduce a language designed for numeric kernels into an orchestration module and then find that data conversion across the language boundary eats all the gains. You can pre-emptively adopt a hybrid architecture for "future performance needs" and then find that operational complexity grows far faster than computation speeds up. You can stuff a technology into the system because "it leads on some benchmark" and then find that its abstraction cost in that position exceeds the time it saves.

At the moment they are made, all these choices look like "choosing the stronger one". They are not wrong because of the technology, but because **the technology is placed where its advantages are not cashed in and its disadvantages are exposed**.

Hejlsberg did not make that mistake. He did not choose "the strongest language"; he chose "the language that keeps five hundred thousand lines from being distorted". **He chose structural match, not single-metric optimum.**

---

That hour outside the CT room I had meant only to pass the time. But this old piece of news clarified something that had always been vague:

**When you make a technology decision, asking "which is better" is too easy a question. The hard one is "better for what".**

Hejlsberg asked "for porting five hundred thousand lines of functional compiler code, which language has the lowest structural cost". He got the right answer.

If you face an orchestration-type gap and the host technology writes "awkwardly but runs", then "awkward" is not a reason to introduce new technology; "it runs" is the reason to stay.

If you face a kernel-type gap and the host technology's abstraction mechanisms are amplified in the hot loop into an irreducible cost, then **do not give up structural match just because integration is harder**. Difficulty is a cost, not correctness.

The right choice is never the one that makes you feel you have picked a "more advanced tool". The right choice is the one that lets technology do only what it was designed to do, and lets every layer of the system avoid distorting itself to accommodate the tool.

**Structural match takes precedence over single-metric optimum.** That sounds like a slogan, but Hejlsberg turned it into a judgement that can be executed with surgical precision, using five hundred thousand lines of code and a tenfold speed difference.


