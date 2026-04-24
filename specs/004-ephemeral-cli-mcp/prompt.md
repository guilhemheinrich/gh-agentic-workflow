# Prompt original

Je voudrais créer un CLI / MCP éphémère pour ce projet :

- Installable localement avec `uvx`
- Interface moderne pour le CLI

**Objectif** : Installer / mettre à jour les skills / rules / commands / hooks.

**Comment** : Le CLI installe un MCP local, pour que l'agent appelant (dans Cursor, Pi, autre) puisse l'appeler. Il fournit également un cleanup, pour retirer la config MCP / nettoyer (il est éphémère).

**Fonctionnement** :

- Le MCP expose une fonction de recherche, pour trouver quelles sont les skills / rules / commandes / hooks à installer en fonction de son interrogation. Un paramètre est de réduire le scope (uniquement skills / rules / commands / hooks / ...), ainsi que l'IDE ou environnement agent (Cursor, Pi, .agent universel).
- Le MCP expose également un prompt, à exécuter par l'agent appelant, pour poser les bonnes questions pour avoir de quoi passer à la fonction de recherche.
