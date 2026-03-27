**Domaine :** UX / Intégration Web Component & Layout  
**Objectif :** Éliminer les doubles barres de défilement et garantir que l'extension dynamique d'un composant (ex: menu dépliant) soit gérée nativement par le navigateur.

---

## 1. La Théorie : Pourquoi ça casse ?
Le problème survient quand deux "contextes de défilement" entrent en conflit. 

* **Le Piège du Shadow DOM :** Par défaut, un Web Component est `display: inline`. Il ne communique pas sa hauteur réelle au parent. Si on force une hauteur interne avec un `overflow: auto`, on crée une "boîte dans la boîte" qui scrolle indépendamment.
* **Le Conflit de Flux :** Si un composant utilise `position: fixed` ou `absolute` pour ses options, il sort du flux CSS. Le parent "pense" que le composant est petit, alors que son contenu dépasse visuellement.

---

## 2. Les Règles de Comportement (Le "Comment")

### A. Le Composant (The Content Provider)
Le composant doit être **"Agnostique de la Hauteur"**. Il ne doit jamais décider de sa propre limite verticale.

1.  **Affirmation d'existence :** Utiliser `:host { display: block; }`. Cela permet au composant d'occuper toute la largeur et de calculer sa hauteur en fonction de son contenu.
2.  **Transparence du Scroll :** Appliquer `overflow: visible;` sur l'élément racine du composant. 
3.  **Expansion Naturelle :** Les éléments extensibles (accordéons, paramètres avancés) doivent utiliser le flux normal (`static` ou `relative`). En s'ouvrant, ils augmentent la taille du composant, qui augmente la taille du parent.

### B. L'Application Parente (The Scroll Master)
L'application est la seule autorité sur le défilement.

1.  **Conteneur Souple :** Le conteneur du Web Component ne doit avoir ni `height` fixe, ni `max-height`.
2.  **Délégation de Scroll :** Seule la racine de l'application (ou le conteneur principal de la page) possède la propriété `overflow-y: auto`.

---

## 3. Matrice de Décision pour l'implémentation

| Si je veux... | Je fais (Composant) | Je fais (Parent) |
| :--- | :--- | :--- |
| **Ajouter du contenu** | Je laisse le DOM s'étirer naturellement. | Je ne bride pas la hauteur du slot. |
| **Éviter le double scroll** | `overflow: visible` obligatoire. | `overflow-y: auto` sur le wrapper global. |
| **Afficher des options** | Utiliser `relative` pour pousser le bas. | Prévoir un padding en bas de page. |

---

## 4. Logique pour IA (System Prompting)
> "Lors de la génération d'un Web Component, assure-toi que le composant est un 'Flow Citizen'. 
> 1. Définis `:host` en `display: block`.
> 2. Prohibe l'usage de `height: 100%` ou `100vh` à l'intérieur du Shadow DOM.
> 3. Délègue la gestion du dépassement (overflow) au parent pour maintenir une expérience de défilement unifiée (`Single Source of Scroll`)."

---

> **Note d'intention :** Cette approche garantit que l'utilisateur n'est jamais bloqué dans une "impasse de scroll" où le mouvement de sa molette ne fait rien parce qu'il survole une zone qui a déjà atteint son propre bas, alors que la page globale est encore longue.