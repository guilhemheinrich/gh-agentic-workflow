---
name: plain-explanation
description: >-
  Explain a technical problem to a human who must understand or decide — plain
  sentences, one analogy sustained to the end, an instance after every
  abstraction. The terse-writing rules (lead with the point, short sentences,
  active voice, no filler) accept two messages on the same facts and tell them
  apart for nobody: the one made of tables of identifiers and coordinates, which
  a reviewer reads, and the one made of a story, which a decider reads. This
  skill is the method that separates them: a switching rule that picks the
  register from the reader so the human never has to ask, eight rules each with
  a statement and a fail test, a six-item pre-send checklist, a concise
  annotated example and the table-register paragraph it replaces. Use for an
  explanation, a decision request, a debrief, a phase report to a person, or
  whenever a human is about to receive coordinates instead of meaning. Triggers
  on "explain this simply", "vulgarise", "reformule", "with analogies", "for a
  non-specialist", "debrief for the team", and implicitly whenever the reader is
  a human who must understand or decide rather than a reviewer or a tool that
  already holds the map.
tags:
  - common
  - documentation
  - process
---

# Plain Explanation

Two messages can carry the same facts, obey the same terse-writing rules, and
serve two different readers. One is made of tables of identifiers and
coordinates; a reviewer who already holds the map reads it in a minute. The
other is a story with one analogy; a person who must understand or decide reads
that one. The two wordings of the same facts are two registers. The terse
rules do not tell them apart. This skill does.

It adds three things on top of the terse rules. A **sequence**: the point in
the reader's words, then the difficulties, then the reader's own view, then the
proposal. An **analogy discipline**: one image, bounded. An **example
placement** rule: every abstraction gets its instance within one sentence. It
removes no terse rule; section 3 states the precedence.

## 1. When to use — the switching rule

The reader decides the register, not the writer and not the subject.

| Reader                                              | Register  | Typical artefacts                                                                     |
| --------------------------------------------------- | --------- | ------------------------------------------------------------------------------------- |
| A human who must **understand or decide**           | plain     | an explanation, a decision request, a debrief, a phase report to a person, a handover |
| A reviewer or a tool that **already holds the map** | technical | spec sections, review findings, commit messages, gate messages, measurement tables    |

**Explicit triggers.** The human writes "explain this simply", "vulgarise",
"reformule", "with analogies", "for a non-specialist" or "debrief for the
team". A human asking the same question a second time is the same trigger.

**Implicit trigger.** The message you are about to send asks a human to decide
or to understand. Its first paragraph is a table, a list of identifiers or a
sentence that opens on a path. Switch before sending. The human never has to
ask.

**When not to use.** A spec section, a review finding, a commit message, a gate
message or a table of measurements stays in the technical register. A story in
a spec fails the switching rule as surely as a table in a decision request.

**Precedence between the two triggers.** The artefact keeps its register; the
message to the human takes the plain one. A reviewer who asks "explain this
simply" gets a plain-register chat message, and the review finding they asked
about stays as written. A decider who asks for a coordinate (a column letter,
a row number) gets it, in one line, inside the plain message.

## 2. The eight rules

Each rule has a statement, a fail test and a one-line instance. The instances
quote the example in section 5, or are labelled made-up. Apply the fail tests
before sending, in the order of section 4.

### Rule 1 — Start from the reader's world, not the artefact

The first sentence names the object and the point in ordinary words: what is
at stake or what is asked. No name that exists only inside the artefact (a
path, a sheet, a gate id, a ticket id, a code span) appears in that sentence.
Leading with the point and starting from the reader's world are the same
sentence.

Fails when the first sentence holds a name the reader would have to open the
artefact to recognise. Test: read the first sentence to someone who has never
opened the artefact; every noun in it must be a word they already own.

Instance: « Une facture électronique est une lettre écrite dans une langue
XML. » Made-up example of the point stated first: « Il faut choisir entre un
champ et deux pour quatre mots qui désignent la même case ; voici le problème
en phrases simples. »

### Rule 2 — One analogy, sustained to the end

One main image carries every difficulty. An image is a sentence that says the
system is, or works like, something outside the system. A second image may
serve exactly one new idea, and nothing else.

Fails on a third image, on a second image that serves two ideas, or on an idea
illustrated by nothing. Test: count the images; more than two fails. For each
difficulty, name the part of the main image that carries it; a difficulty with
no part fails.

Instance: the dictionary carries the whole example. Pages are sheets, words
are terms, « colour (US : color) » is a pair of id columns, synonyms are
aliases. The customs office serves one idea only: validation layers.

### Rule 3 — Abstraction, then immediately its instance

Every general claim is followed by a real identifier, value or cell that
instantiates it, in the same or the next sentence. The first sentence takes
its instance in the second (rule 1). When the case supplies none, invent one
and label it « exemple fictif : » or "made-up example:". An invented instance
illustrates a mechanism; it never stands where the decision rests.

Fails when a claim stands two sentences without an instance, or when the
nearby concrete fact instantiates a different claim. Test: after each general
claim, ask "for example?". The answer must already stand in the same or the
next sentence. It must be an example of that claim, not of a neighbouring one.

Instance: « ces mots nouveaux ont deux noms » → « `EXT-FR-FE-03` chez l'AFNOR,
`BT-X-…` chez Factur-X ».

### Rule 4 — Jargon after the plain word

The technical term follows its plain description: in the same sentence, in
parentheses or after a colon, or in the next one. The plain word carries the
meaning; the term lets the reader find it in the spec later.

Fails when a term of art precedes its plain counterpart on first use. Test:
list the terms the reader may not own; at the first occurrence of each, look
backwards one sentence for the plain description.

Instance: « la grammaire XML (le XSD) ». Counter-instance, from the same
message: « Le "JSON sémantique" est notre langue pivot » puts the term first;
the plain-register order is « notre langue pivot, le JSON sémantique ».

### Rule 5 — A story of numbered difficulties, simplest first

Difficulties form a numbered sequence, 2 to 4 sentences each. Each difficulty
uses only ideas the earlier ones have introduced. An error the author made is
a beat of the story, stated flat, never a footnote or a hedge. A message with
one difficulty carries no numbers; a message with none (a debrief that reports
no problem) skips this rule and keeps the others.

Fails when a difficulty needs an idea a later one introduces, or runs under 2
or past 4 sentences. Fails too when an admitted error is softened ("it seems
we may have", "arguably"). Test: count the sentences of each difficulty. For
each term in difficulty n, check it was introduced in difficulties 1 to n or
in the opening. The error sentence starts with the fact, not with a qualifier.

Instance: « Nous avions lu la colonne C seule … Faux : elle en parle, sous
l'autre nom. »

### Rule 6 — Mirror before adding

When the reader has stated a view, restate it in their words, map their words
onto the system's words, then propose. When the reader has stated none, say so
in one clause and propose; never infer a view for them. A message that
proposes nothing has no mirror section. A disagreement gets its own section,
one practical reason, one exit.

Fails when a proposal precedes the restatement, or when the restatement
attributes to the reader words they did not write. Fails too when a
disagreement runs past one paragraph, carries more than one reason, or offers
no exit. Test:
locate the first sentence that proposes; before it, find the restatement and
check each of its claims against the reader's message. In a disagreement
section, count the reasons (one) and find the sentence that hands the choice
back (one).

Instance: « Tu veux une construction par couches, comme une douane à plusieurs
guichets » → « C'est déjà l'architecture : les portes 1 à 5 ». The exit: « Si
tu préfères vraiment deux champs, dis-le, et j'écris la règle de conflit. »

### Rule 7 — Say where the analogy stops

One sentence marks the boundary: what the image does not carry, with an
instance of what lies beyond it. Without it the reader extends the image past
its reach and asks a question the image cannot answer.

Fails when the analogy is never bounded, or when the boundary sentence names
the beyond in jargon alone. Test: find the sentence that names the main image
and says what it stops covering (« le dictionnaire s'arrête ici »); check it
obeys rules 3 and 4.

Instance: « Un dictionnaire traduit des mots ; une cellule de liaison dit
aussi combien de fois le mot peut apparaître (sa cardinalité). »

### Rule 8 — The switching rule

Use this register when the reader is a human who must understand or decide.
Use the technical register when the reader is a reviewer or a tool that
already holds the map. Section 1 lists both sides and the precedence between
them.

Fails when a decision request is delivered as tables of coordinates, or when a
spec section is delivered as a story. Test: name the reader in one word
(decider, learner, reviewer, tool). If the word is "decider" or "learner" and
the message opens on a table, a list of identifiers or a path, rewrite. If the
word is "reviewer" or "tool" and the message carries an image or numbered
difficulties, rewrite.

Instance: the table in section 6 versus the sentence that replaces it.

## 3. Precedence

This register never breaks the terse rules. Sentences stay under 25 words, the
actor is named, filler stays out, numbers stay specific, completeness beats
concision. The plain register adds sequence, analogy discipline and example
placement on top of them. When a plain-register sentence would need 30 words
to hold its instance, split it; never drop the instance.

"Lead with the point" and rule 1 meet in the first sentence: the point, stated
in the reader's words, is the reader's world. The proposal that follows the
difficulties is the detail of that point, not its first statement.

Instance: « Notre traducteur ne connaît que les mots du vocabulaire européen,
`BT-1`, `BG-25`, etc. Environ 2 200 entrées. » Two sentences, one instance
each, one specific number.

## 4. Pre-send checklist

Run these six checks on the draft, in order. One failure sends the draft back.

1. **Reader named.** One word: decider, learner, reviewer or tool. "Decider"
   and "learner" continue the checklist. The other two switch to the
   technical register and stop here. Exception: the human asked for a plain
   explanation in so many words (section 1, precedence).
2. **First sentence clean.** The point and the object in ordinary words; no
   path, sheet name, gate id, ticket id or code span anywhere in that sentence
   (rule 1).
3. **Images counted.** One main image with a named part for every difficulty;
   at most one secondary image, serving one idea. One sentence says where the
   main image stops, and names the beyond with an instance (rules 2 and 7).
4. **Instances placed.** Every general claim has, within one sentence, an
   identifier, value or cell that instantiates that claim; invented ones are
   labelled. Every term of art follows its plain word (rules 3 and 4).
5. **Story ordered.** When there are two or more difficulties: numbered, 2 to
   4 sentences each, each using only ideas already introduced. The author's
   own errors stated flat as beats (rule 5).
6. **Mirror first, one exit.** When the message proposes: if the reader stated
   a view, it is restated in their words and mapped before the first proposal.
   If not, one clause says so. Any disagreement is one paragraph, one reason,
   one exit (rule 6).

## 5. A concise example

Four blocks from a decision request, quoted in French, about mapping e-invoice
fields between two vocabularies. The case does not matter; the moves do. The
rule each block shows is in the line above it. The full message, annotated
paragraph by paragraph, is in `references/exemplar.md`.

*Rule 1 — the object in ordinary words. Rule 4 slip, left visible: « JSON
sémantique » precedes « langue pivot ».*

> Une facture électronique est une lettre écrite dans une langue XML : UBL ou
> CII. Le « JSON sémantique » est notre langue pivot : on y écrit le sens, la
> machine traduit vers UBL ou CII.

*Rule 5 — a numbered difficulty, 4 sentences, with the author's error as a
beat. Rule 2 — the dictionary image stretches to cover two id columns. Rule 3
— « deux noms » gets its two identifiers. Edited down from the 8-sentence
original in `references/exemplar.md`.*

> Deuxième difficulté : ces mots nouveaux ont **deux noms**, `EXT-FR-FE-03`
> chez l'AFNOR, `BT-X-…` chez Factur-X. La page CII écrit les noms Factur-X en
> colonne C et les noms AFNOR en colonne D, comme un dictionnaire qui écrit
> « colour (US : color) ». Nous avions lu la colonne C seule et conclu que la
> page CII ne parlait pas des extensions. Faux : elle en parle, sous l'autre
> nom.

*Rule 7 — the boundary sentence, with the beyond named plainly (rule 4) and
instantiated (rule 3). Added to the original.*

> Le dictionnaire s'arrête ici. Un dictionnaire traduit des mots ; une cellule
> de liaison dit aussi combien de fois le mot peut apparaître (sa
> cardinalité) : exemple fictif, un nom d'agent au plus une fois par facture.

*Rule 6 — the disagreement: the reader's claim restated, the earlier decision
named, one practical reason, one exit.*

> Tu dis : deux mots qui visent la même case, ce n'est pas grave, c'est une
> surjection. L'Option C que tu avais retenue disait l'inverse : un seul
> champ, jamais deux. Je garde l'Option C, pour une raison pratique. Avec deux
> champs, `BT-173` et `EXT-FR-FE-187`, un appelant peut remplir les deux avec
> des valeurs différentes. Il faudrait alors une règle pour trancher, écrite
> par nous. Si tu préfères vraiment deux champs, dis-le, et j'écris la règle
> de conflit.

## 6. The anti-example and its rewrite

The same fact in the technical register, as sent to the same reader before the
switch:

> **1. `datatypeUnstated` — 31 lignes sans `DT` sur `CII D22B & FX EXT-CTC-FR`
> (col AQ)**
>
> | classe                          | lignes | exemple                                                                                    |
> | ------------------------------- | ------ | ------------------------------------------------------------------------------------------ |
> | groupes, col AR (`Type`) = `EG` | 29     | ligne 337 : C `BG-X-62`, D `EXT-FR-FE-BG-01`, AP `…/ram:BuyerAgentTradeParty`, AQ vide |

Right for a reviewer who holds the map: the sheet, the column letters and the
row number let them open the workbook and verify. Wrong for a decider, on two
counts. The heading opens on a rule id and a sheet name (rule 1). The table
gives coordinates without the claim they support (rule 3 inverted).

Rule 3 turns the row into a sentence, abstraction first, then its instance:

> Certains mots du dictionnaire ne sont pas des mots mais des chapitres : ils
> regroupent d'autres mots et n'ont donc pas de type. Une de ces lignes est un
> groupe : la ligne 337, l'agent de l'acheteur, et un groupe n'a pas de type.
> Sur les 31 lignes sans type, 29 sont des groupes de cette sorte.

The counts survive (precedence). The column letters and the XPath do not: the
decider does not open the workbook, and the reviewer already has the table.

## 7. What is in this bundle

| File                     | Role                                                               |
| ------------------------ | ------------------------------------------------------------------ |
| `SKILL.md`               | The method: switching rule, eight rules, checklist, short example. |
| `references/exemplar.md` | The full example message, annotated paragraph by paragraph.        |

No script. The writer applies the fail tests of section 2 before sending, in
the order of section 4.
