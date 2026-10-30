# Standard: architecture documents and diagrams

Applies to `docs/architecture.md`, its published pages (Architecture, Lab Map), ADRs, and runbooks with figures.
Agents working in this repo follow it too. Each rule says where it comes from, so a disagreement can go back to the source.

## 1. Every document opens with control and scope

| Rule | Source |
|---|---|
| Document control first: **status** (draft, living, superseded), **owner**, **last reviewed**, **next review** | Google design docs; Microsoft Learn metadata |
| A **revision history**: letter, date, one line on what changed. Append only | Drawing-set revision blocks; Apple and Microsoft doc change logs |
| **In scope / out of scope**, three bullets each at most. Out of scope says where that content lives instead | Google design docs ("goals and non-goals") |
| Dates are absolute (`30 Oct 2026`), never "yesterday" or "next week" | Google and Microsoft style guides |

## 2. Structure

| Rule | Source |
|---|---|
| Sheets (sections) are numbered by discipline: `N` network, `S` security, `D` delivery, `Q` quality, `G` general, `P` plain-words edition. Numbers only where order or reference is real | Drawing-set sheet index; C4/arc42 views |
| A **numbered workflow** under every flow diagram; its numbers match callouts on the drawing | Azure Architecture Center ("Workflow") |
| A **Considerations** section by Well-Architected pillar: reliability, security, operational excellence, performance, cost. Each: today, largest risk, next step | Azure Well-Architected Framework |
| Lists of things with the same attributes are **schedules** (tables), not card grids | Drawing-set schedules; Microsoft Learn reference tables |
| Decisions are not argued in the architecture doc: one line each, linking to the ADR | arc42 §9; ADR practice |

## 3. Diagrams

| Rule | Source |
|---|---|
| Every diagram declares its **view type** (deployment, security, dynamic, supply-chain) in its title strip | C4 model; arc42 views |
| A title strip on every drawing: sheet, title, view, revision, date | Drawing-set title block |
| **One ink, one signal colour.** Ink for what is built; red only for redlines (untrusted zones, open issues). Meaning never by colour alone: red is always paired with hatching, a dashed line or a label | WCAG 2.2 SC 1.4.1; drafting redline convention |
| Line language: solid = built, dashed = pulled / tunnelled / not built yet, heavy border = gate | Drafting convention (existing vs proposed) |
| Square corners; three stroke weights (1, 1.5, 2) | Drafting line-weight hierarchy |
| Arrows are labelled with what moves (`git push`, `pull, read-only`), not left as "related somehow" | C4 ("label every relationship") |
| Large drawings carry grid references (A–F, 1–4); tables cite the grid square | Drawing-set grid convention |
| Every diagram has a text alternative (`aria-label` / alt text) stating its claim | WCAG 2.2 SC 1.1.1; Apple and Microsoft accessibility guides |
| No vendor logos or brand marks | Avoids implied endorsement; keeps the set legible in one ink |

## 4. Writing

| Rule | Source |
|---|---|
| Sentence-case headings | Google, Microsoft, Apple style guides |
| Active voice, present tense, second person where the reader acts ("you merge") | Google and Microsoft style guides |
| Code font for anything typed or read by a machine: commands, paths, hostnames, flags, versions in commands | Google developer docs style guide |
| Bold for the term being defined or the lead-in of a list item, not for emphasis in running text | Microsoft Writing Style Guide |
| Plain words first; the term of art once, then used consistently (Lab Map: kid way, then what is really happening) | Apple Style Guide; Microsoft "bias-free, simple" |
| No secrets, private domains, personal names or e-mails in anything that is mirrored to GitHub | Repo rule (`README.md`) |

## 5. Type and layout

| Rule | Source |
|---|---|
| Body text 16 px, line height 1.6, measure about 68 characters | Material type scale; Apple HIG legibility |
| A type scale with three faces and fixed roles: display (Archivo, condensed) for headings, sans (IBM Plex Sans) for text, mono (IBM Plex Mono) for labels, code and data | Design-system practice (Material, Fluent) |
| Inline code is a tinted chip; inside tables it drops the chip | Google, Microsoft Learn, Apple developer docs |
| Numbers that line up use tabular figures | Typographic practice |
| Light and dark themes are designed, not inverted; contrast at least WCAG AA (4.5:1 body text) | WCAG 2.2 SC 1.4.3; Apple HIG dark mode |
| Never put mixed inline content (text plus `<b>` or `<code>`) directly in a CSS grid or flex item; wrap it, or the inline parts become separate cells | Lesson from Rev C, 30 Oct 2026 |

## 6. Review

- One look at the rendered page (desktop, light and dark) before publishing; fix what it shows, then publish.
- Bump the revision letter on every publish that changes content, and add the line to the revision history.
- When the lab changes, update `docs/architecture.md` first; the published pages follow it.

## References

- Google developer documentation style guide: https://developers.google.com/style
- Microsoft Writing Style Guide: https://learn.microsoft.com/style-guide/welcome/
- Apple Style Guide: https://support.apple.com/guide/applestyleguide/welcome/web
- Azure Architecture Center, architecture design guidance: https://learn.microsoft.com/azure/architecture/
- Azure Well-Architected Framework: https://learn.microsoft.com/azure/well-architected/
- C4 model: https://c4model.com/
- arc42: https://arc42.org/
- WCAG 2.2: https://www.w3.org/TR/WCAG22/
