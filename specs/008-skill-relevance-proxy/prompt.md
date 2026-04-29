# Prompt Original

**Source** : Prompt généré par une IA grand public, hors contexte projet.
**Avertissement** : Les hypothèses techniques doivent être vérifiées et challengées.

---

## Objet

Création d'un "Skill Relevance Hook" via un Proxy Local pour l'audit de contexte.

## Description

> Je souhaite concevoir un outil de monitoring d'attention pour évaluer la pertinence des 'skills' (morceaux de code, documentations, fonctions) importés dans mon contexte de travail. Comme les scores d'attention natifs ne sont pas exposés par l'API, nous allons implémenter un pattern **LLM-as-a-Judge** via un proxy local.

### Architecture cible (proposée)

1. **Interception** : Serveur proxy local (FastAPI ou Node.js) entre Cursor et l'API Anthropic/OpenAI.
2. **Extraction** : Intercepter la réponse du modèle et extraire le texte généré + skills du prompt (regex ou détection de blocs de code).
3. **Audit Local** : Envoi à un modèle local (Ollama/Llama3) agissant comme juge.
4. **Reporting** : JSON détaillant quels skills ont été utilisés, avec score de pertinence et citation.

### Capacités requises

- **Support du Base URL** : Cursor configuré pour pointer vers `http://localhost:XXXX/v1`.
- **Context Management** : Structure de Skills (tags XML `<skill id='logger'>...</skill>`) pour faciliter l'extraction.
- **Streaming Compatibility** : Support du streaming pour ne pas casser l'UX.

### Travail demandé

1. Structure de code pour le serveur proxy local.
2. System prompt spécifique pour le modèle local (le Juge).
3. Configuration Cursor pour router les requêtes à travers ce hook.
4. Méthode de logging des rapports (JSON ou console).

### Note du demandeur

> SOIT CRITIQUE, ce preprompt provient d'une IA grand public hors contexte. Les principes sont des a priori qui ne reflètent peut-être pas la réalité.
