# Contributing

Thank you for looking. This repository is the evidence base for two manuscripts,
which shapes what kinds of contribution are useful here.

## Very welcome

**Issues, reproduction reports, and corrections.** Especially:

- You built the elastomer and got a different R(P) or L(P) — that is the most
  valuable thing anyone could report, since those curves are exactly what is
  still open.
- You ran the regression against `CODE/V1/01_golden_model/` and something did
  not match.
- You re-ran synthesis or place-and-route from `CODE/V1/04_constraints/` and got
  different resources or timing.
- A number in a README does not agree with the report or code it points at.
- Something in the bring-up notes is wrong, or cost you time in a way that a
  clearer note would have prevented.

Open an issue. Include what you ran, what you expected, and what you got. A
disagreement backed by a measurement is a contribution, not a complaint.

## Not accepted: code pull requests

Please do not open pull requests that change code, RTL, or data. This is not
about quality or gatekeeping — there are two specific reasons:

**It would blur what the papers claim.** The manuscripts assert particular
resource figures, timing closure, and verification results *about this code*. If
the published source drifts from the source those numbers were produced by, the
claims stop being checkable, which defeats the point of publishing it.

**It would foreclose relicensing.** Copyright in a merged contribution belongs to
its author. Once that happens the repository can no longer be relicensed without
tracking down and getting agreement from every contributor. Today the copyright
is held by one person, which means the licence can be relaxed at any time if
that turns out to serve the work better. That option is worth keeping, and it is
one-way: it can be spent later, but not recovered.

If a change genuinely should be made, open an issue describing it. If it is
right, it gets made, and you get credited in the commit and in the release notes.

## Forking

Fork freely, within the licence (see [LICENSE](LICENSE.md)). Research, teaching, and
personal use are unrestricted; commercial use needs a separate agreement, which
is a conversation rather than a refusal — sigmansslee@gmail.com.

If you build something interesting on this, an issue saying so would be genuinely
appreciated. Knowing what people do with it is more useful than stars.
