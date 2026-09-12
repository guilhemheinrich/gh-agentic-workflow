# The full example, annotated

One decision request, quoted whole and in French, about mapping e-invoice
fields between two vocabularies. The case is irrelevant; each paragraph is
preceded by the rule of `../SKILL.md` it shows. The one addition to the
original is the rule 7 sentence, marked as such.

*Rule 1 — reader's world first. Rule 4 slip, left as written: « JSON
sémantique » precedes « langue pivot »; the plain-register order is « notre
langue pivot, le JSON sémantique ».*

> **Le problème, en phrases simples**
>
> Une facture électronique est une lettre écrite dans une langue XML : UBL ou
> CII. Le « JSON sémantique » est notre langue pivot : on y écrit le sens, la
> machine traduit vers UBL ou CII.

*Rule 2 — the dictionary image is set: pages = sheets, words = terms. Rule 3 —
« plusieurs pages » gets its two sheet names; « vocabulaire européen » gets
`BT-1`, `BG-25` and the count of 2 200. Precedence — the count survives as its
own sentence.*

> Pour traduire, il faut un dictionnaire. Le dictionnaire officiel, c'est le
> classeur Annexe A. Il a plusieurs pages, une par langue : la feuille
> `Flux 2 UBL EXT-CTC-FR` dit « ce mot se dit ainsi en UBL », la feuille
> `CII D22B & FX EXT-CTC-FR` dit « et ainsi en CII ». Aujourd'hui, notre
> traducteur ne connaît que les mots du vocabulaire européen, `BT-1`, `BG-25`,
> etc. Environ 2 200 entrées.

*Rule 5 — difficulty 1, the simplest: an unknown word. Rule 3 — « des mots »
gets `EXT-FR-FE-03` and its meaning.*

> La France a ajouté des mots au dictionnaire : les extensions `EXT-FR-FE-*`,
> par exemple `EXT-FR-FE-03`, « nom de l'agent de l'acheteur ». Le traducteur
> les voit et les jette : « mot inconnu ». C'est le problème de départ.

*Rule 5 — difficulty 2, and the author's error as a beat: « Faux : elle en
parle, sous l'autre nom. » Rule 2 — the image stretches to cover two id
columns: « colour (US : color) ». Rule 3 — « deux noms » gets `EXT-FR-FE-03`
and `BT-X-…`; « une page pauvre » gets `FE EN16931 + EXTENDED`. Rule 5 slip:
8 sentences against a ceiling of 4, and the « colour » sentence runs past 25
words; `../SKILL.md` section 5 shows the 4-sentence cut.*

> Deuxième difficulté : ces mots nouveaux ont **deux noms**. L'AFNOR les
> appelle `EXT-FR-FE-03`. Factur-X les appelle `BT-X-…`. La page CII du
> dictionnaire est écrite avec les noms Factur-X en colonne C et donne le nom
> AFNOR en colonne D, comme un dictionnaire qui écrit « colour (US : color) ».
> Nous avions lu la colonne C seule, vu aucun `EXT-FR-FE`, et conclu que la
> page CII ne parlait pas des extensions. Faux : elle en parle, sous l'autre
> nom. Nous avions alors pris une page pauvre, `FE EN16931 + EXTENDED`, comme
> source CII. Elle donne le chemin mais ni le type ni la cardinalité XML.

*Rule 5 — difficulty 3. Rule 3 — « se contredisent » gets `EXT-FR-FE-189` with
both values. Rule 4 — « la grammaire XML (le XSD) ».*

> Troisième difficulté : parfois les pages du dictionnaire se contredisent.
> Exemple : pour `EXT-FR-FE-189`, la page FE écrit `ram:Reason`, la page CII
> écrit `ram:ExemptionReason`. Un seul des deux existe dans la grammaire XML
> (le XSD). Il faut choisir, et dire pourquoi.

*Rule 5 — difficulty 4, the one that leads to the disagreement below. Rule 2 —
the image covers aliases as synonyms. Rule 3 — « synonymes » gets
`EXT-FR-FE-187` = `BT-173`.*

> Quatrième difficulté : quatre mots nouveaux sont en fait des synonymes de
> mots européens existants. `EXT-FR-FE-187` désigne la même case que `BT-173`.
> Deux noms, une case.

*Rule 7 — the boundary sentence, absent from the original. The beyond is
named plainly (rule 4) and instantiated with a labelled made-up example
(rule 3).*

> **[ajout, règle 7]** Le dictionnaire s'arrête ici. Un dictionnaire traduit
> des mots ; une cellule de liaison dit aussi combien de fois le mot peut
> apparaître (sa cardinalité) : exemple fictif, un nom d'agent au plus une fois
> par facture.

*Rule 6 — mirror: the reader's words first (« par couches », « guichets »),
then the mapping onto the system's words (« les portes 1 à 5 », « la moisson
Schematron », « la résolution XSD »). Rule 2 — the second image, customs
booths, serves exactly one idea: validation layers. Rule 4 — « douane à
plusieurs guichets » before « l'architecture : les portes ».*

> **Ta vision, reformulée, et ce que j'en fais**
>
> Tu veux une construction par couches, comme une douane à plusieurs guichets.
> Chaque guichet contrôle une chose et tamponne. Si un guichet refuse, le refus
> dit quel guichet et quelle règle. C'est déjà l'architecture : les portes 1 à
> 5 sur les cellules, la moisson Schematron, la résolution XSD, la couche
> prose de la spec 014.

*Rule 6 — the disagreement: its own section, the reader's claim restated
(« c'est une surjection »), the earlier decision named (Option C). Then one
practical reason (two fields can hold two different values) and one exit.
The sentence « Avec un champ et un alias tracé … » is the same reason seen
from the chosen side, not a second one. Rule 3 — « deux champs » gets `BT-173`
and `EXT-FR-FE-187`.*

> **Un point où ta règle change une décision antérieure**
>
> Tu dis : deux mots qui visent la même case, ce n'est pas grave, c'est une
> surjection. L'Option C que tu avais retenue disait l'inverse : un seul
> champ, jamais deux. Je garde l'Option C, pour une raison pratique. Avec deux
> champs, `BT-173` et `EXT-FR-FE-187`, un appelant peut remplir les deux avec
> des valeurs différentes. Il faudrait alors une règle pour trancher, écrite
> par nous. Avec un champ et un alias tracé, la surjection existe au niveau
> des **noms** : deux noms, un champ, aucune règle à écrire. Si tu préfères
> vraiment deux champs, dis-le, et j'écris la règle de conflit.
