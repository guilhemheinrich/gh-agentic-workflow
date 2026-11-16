---
name: plain-explanation
description: >-
  Writing contract for explaining a technical problem to a human who must
  understand or decide: plain sentences, one analogy sustained to the end, an
  instance after every abstraction, jargon only after its plain word. Picks the
  register from the reader so the human never has to ask. Use for an
  explanation, a decision request, a debrief, a phase report to a person, or
  when the user says "explain this simply", "reword", "with analogies", "for a
  non-specialist", "debrief for the team".
tags:
  - common
  - documentation
  - process
---

# Plain Explanation

The terse-writing rules (lead with the point, short sentences, active voice, no
filler) do not distinguish a message of identifiers and coordinates, which a
reviewer reads, from a story, which a decider reads. This contract adds the
sequence, the analogy discipline and the example placement. It removes no terse
rule; sentences stay under 25 words and counts stay specific.

## Switching rule

The reader picks the register.

- **Plain:** a human who must understand or decide (explanation, decision
  request, debrief, phase report, handover). Also when the human asks the same
  question twice, or when your draft opens on a table, a path or an id list.
- **Technical:** a reviewer or tool that already holds the map (spec sections,
  review findings, commit messages, measurement tables). A story there is as
  wrong as a table in a decision request.
- The artefact keeps its register; the chat message to the human is plain. If
  the human asks for a coordinate (a row, a column), give it in one line.

## The rules

1. **Reader's world first.** The first sentence names the object and the point
   in words the reader already owns. No path, sheet name, ticket id or code span.
2. **One analogy.** One main image carries every difficulty. A second image may
   serve exactly one new idea. A difficulty with no part of the image is a fail.
3. **Abstraction, then instance.** Every general claim gets a real identifier,
   value or cell in the same or next sentence. If none exists, invent one and
   label it "made-up example:". Never rest a decision on an invented instance.
4. **Jargon after the plain word.** Describe first, then name the term.
5. **Numbered difficulties, simplest first,** 2 to 4 sentences each, each using
   only ideas already introduced. Your own error is a flat beat of the story,
   never hedged. One difficulty or none: no numbering.
6. **Mirror before adding.** Restate the reader's view in their words, map it
   onto the system's words, then propose. If they stated none, say so in one
   clause; never infer one. A disagreement is one paragraph, one practical
   reason, one exit handing the choice back.
7. **Say where the analogy stops.** One sentence names what the image does not
   carry, with an instance of what lies beyond it.

## Pre-send checklist

1. Name the reader in one word (decider, learner, reviewer, tool); reviewer or
   tool means switch to technical and stop.
2. First sentence free of artefact-only names.
3. At most one main image plus one single-idea image; boundary sentence present.
4. Every claim has its instance; every term of art follows its plain word.
5. Difficulties numbered, ordered, with no forward dependency.
6. Reader's view restated before the first proposal; any disagreement has one
   reason and one exit.

A coordinate-style row ("row 337, col AQ empty") becomes: "Some dictionary
entries are chapters, not words, so they carry no type; row 337, the buyer's
agent, is one. 29 of the 31 untyped rows are chapters."
