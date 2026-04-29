# Original Prompt

Je voudrais faire une commande réutilisable, dont l'objectif est d'identifié et de réglé des problèmes d'infrastructure en k8s.
Notre devops à mis à disposition un site admin ou je peux récupérer un artefact qui à cette forme /Users/guilhemheinrich/code/MODELO_HUB/modelo-meet/kubeconfig.yaml

Parse et synthétise la docs présente ici : https://modelo-dashboard-k8s-preprod.septeo.fr/docs

Normalement, avec les infos présentent dedans, et kubectl, on doit pouvoir agir sur l'infra dans le périmètre de notre scope (par exemple, je ne peux pas set des secrets, ou toucher à l'infra, mais je peux voir et modifié des variables d'env).

Ecris un ou des skills pour la description de ce fichier, pour la manipulation de kubectl. Fournit un dockerfile à coté du skill pour avoir un docker pour la commande (pas besoin de l'installer en local).
Lorsqu'un problème diagnostiqué implique un changement hors scope, prévoit la rédaction d'un rapport concis à envoyer au devops, qui détail les raisons qui incite à modifier tel ou tel chose (il doit comprendre pourquoi je lui demande de changer quelque chose, avec un exemple / logs concret)

J'attend donc un skill, avec un dockerfile et autre resources utiles (comme les docs exploitable fetché plus haut), et une commande.
