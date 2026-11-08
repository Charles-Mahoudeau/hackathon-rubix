# Consommation de tokens dans GRIDMIND

Ce document décrit le fonctionnement implémenté dans le dépôt et les valeurs de configuration par défaut. Il s'adresse aux joueurs qui configurent leurs agents et aux personnes qui règlent l'économie du jeu. Les nombres peuvent changer avec la configuration ou l'état de la partie.

## À quoi servent les tokens ?

GRIDMIND est un jeu de gestion spatiale : des agents pilotent l'extraction, la logistique, le raffinage, le pillage, la récupération et la supervision. Lorsqu'un agent en mode IA doit choisir une action, le jeu construit une requête contenant ses instructions, l'état du monde et les outils qu'il peut utiliser. La réponse choisit un outil et ses arguments. Les tokens mesurent la taille de cette entrée et de cette sortie ; ils servent à calculer le coût en **Compute**, une ressource du jeu.

Un token n'est ni un caractère, ni un mot, ni un crédit. Le Compute est une monnaie interne : les équivalences en crédits ci-dessous sont celles du jeu et ne représentent pas le prix réel d'une API ou une facture en euros.

Une décision est utile quand l'agent doit interpréter des instructions, choisir entre plusieurs actions ou réagir à une situation changeante. Une action déjà en cours n'appelle pas le modèle à chaque seconde. À l'inverse, chaque nouvelle décision reconstruit les instructions et le contexte : un texte plus long ou davantage d'informations peuvent donc coûter à répétition.

## Ce qui est compté

Pour chaque décision, le jeu estime séparément les sections suivantes, puis additionne leurs estimations :

| Section | Contenu | Pourquoi elle est utile |
| --- | --- | --- |
| `rules` | Rôle de l'agent, règles de réponse, format JSON et légende du format compact si celui-ci est utilisé. | Définir le rôle et obtenir un appel d'outil exploitable. |
| `directive` | Instruction permanente du joueur, avec son en-tête. | Fixer une stratégie stable d'une décision à l'autre. |
| `order` | Ordre temporaire, avec son en-tête, jusqu'à son effacement. | Modifier une priorité ou traiter une situation précise. |
| `context` | État de la partie propre à l'agent et options de contexte activées. | Prendre une décision à partir des informations disponibles. |
| `tools` | Nom, description et arguments des outils équipés. | Indiquer au modèle les actions autorisées et leurs paramètres. |
| Sortie | Réponse JSON contenant notamment le raisonnement, l'outil et ses arguments. | Transmettre le choix du modèle au jeu. |

Même sans directive ou ordre, l'en-tête et `none` sont présents. Les descriptions de tous les outils équipés sont incluses à chaque décision, même s'ils ne sont pas choisis. `wait` et `run_skill` ne prennent pas d'emplacement d'outil, mais leurs descriptions comptent quand ils sont équipés.

Le jeu estime chaque section par `ceil(nombre de caractères Unicode / 4)` ; si la chaîne n'est pas du UTF-8 valide, il utilise sa longueur en octets. Ce calcul est une approximation : le découpage en tokens du modèle réel peut différer. L'estimation d'entrée est la somme des estimations par section, et non nécessairement l'estimation du texte complet assemblé.

La directive est limitée à **400 tokens estimés** et l'ordre à **100** : au-delà, l'enregistrement est refusé. Le compteur passe à l'orange dès 90 % de la limite. Ces limites portent sur le texte saisi, indépendamment des en-têtes présents dans la requête.

## Calcul du coût en Compute

Par défaut, une décision coûte un Compute pour 1 000 tokens, avec un arrondi **au dixième de Compute supérieur**, appliqué à chaque décision :

```text
Compute = ceil((tokens d'entrée + tokens de sortie) / 100) / 10
```

| Tokens totaux | Coût | Équivalent au prix du magasin |
| ---: | ---: | ---: |
| 100 | 0,1 Compute | 4 crédits |
| 101 | 0,2 Compute | 8 crédits |
| 740 | 0,8 Compute | 32 crédits |
| 1 000 | 1,0 Compute | 40 crédits |
| 1 001 | 1,1 Compute | 44 crédits |

Exemple : 700 tokens d'entrée et 40 de sortie font 740 tokens, soit 0,8 Compute. À 60 décisions identiques, cela représente 48 Compute. L'arrondi étant appliqué à chaque décision, on ne peut pas simplement additionner tous les tokens de l'heure avant de calculer le coût.

Le jeu débite d'abord l'entrée estimée plus **40 tokens de sortie estimés**, dès l'acceptation de la décision dans la file, y compris si elle doit attendre. Le solde doit pouvoir couvrir cette estimation. À la réponse :

- Avec Axis, si les deux compteurs rapportés par le fournisseur sont valides, le débit est ajusté aux tokens d'entrée et de sortie rapportés, même si la réponse est invalide.
- Avec le simulateur `stub`, la sortie de l'appel d'outil est estimée localement et le débit est ajusté à cette estimation.
- Si les deux chiffres d'utilisation ne sont pas exploitables, notamment lors de certaines erreurs, le code conserve l'entrée estimée plus 40 tokens de sortie estimés. Une décision de repli `stub` peut ensuite être utilisée ; les erreurs répétées peuvent mettre l'agent en pause.

Le débit corrigé peut être supérieur ou inférieur à l'estimation initiale. Le solde est borné à zéro si le complément dépasse le Compute restant ; le journal conserve le coût calculé. Lors d'un changement de fournisseur avec une décision en attente, le jeu règle celle-ci sur l'entrée estimée seule et l'abandonne.

La partie commence avec **10 Compute** et **500 crédits**. Le magasin vend des lots de **5 Compute pour 200 crédits**, soit 40 crédits par Compute. Un plan de récupération peut accorder une réduction de 10 % sur le coût en Compute d'un type d'agent concerné ; la réduction s'applique avant l'arrondi et ne réduit pas le nombre de tokens comptabilisés dans le budget horaire. Les estimations des panneaux Context et éditeur affichent le coût sans cette réduction.

## Dans quels domaines dépenser du contexte ?

Il n'existe pas de configuration optimale universelle : une donnée supplémentaire est pertinente si elle peut changer la décision assez souvent pour compenser son coût récurrent. Le volume dépend des données effectivement présentes, des déblocages et du format choisi.

| Agent | Informations particulièrement pertinentes | Pourquoi |
| --- | --- | --- |
| Mineur | Position et capacité du vaisseau, filons, prix des débouchés accessibles ; stock si l'entrepôt intervient dans sa stratégie. | Choisir où extraire, quand rentrer et où vendre ou stocker. Élargir les filons ou les prix si l'agent doit comparer plusieurs destinations. |
| Logisticien | Stock de station, cargos, prix des marchés concernés, résultats récents et messages si coordination. | Choisir quoi expédier et vers quel marché, tout en tenant compte des cargos disponibles. |
| Raffineur | Stock, recettes, prix et éventuellement tableau des marges. | Choisir une recette réalisable et, si nécessaire, comparer sa rentabilité. Les marges ajoutent du contexte mais facilitent ce choix. |
| Corsaire (`privateer`) | État et coque de l'intercepteur, cargaison, routes, cibles repérées et réputation. | Évaluer une interception, le risque d'attaque et la nécessité de se replier ou réparer. |
| Récupérateur (`scavenger`) | État du vaisseau, sites, danger, couches, temps restant et coût de réparation. | Choisir un site et arbitrer entre butin, temps disponible et état de la coque. |
| Superviseur (`monitor`) | Alertes et résumé des agents ; résultats détaillés, compétences, filons ou prix selon sa mission. | Repérer les blocages et coordonner les agents ; les détails supplémentaires sont utiles pour diagnostiquer ou réaffecter. |

Une partie de ces données constitue le contexte de base propre au rôle ; elle n'est pas forcément désactivable individuellement. Les options visibles varient selon le type d'agent et certains marchés ou l'entrepôt doivent être débloqués. Une option sans données disponibles peut apporter peu ou pas de tokens à un instant donné.

### Réglages à surveiller

- **Prix et tendances** : activer les marchés que l'agent peut comparer. Les tendances ajoutent un prix habituel à côté du prix courant ; elles sont utiles pour interpréter les variations.
- **Filons** : limiter à son filon, à sa planète ou étendre aux planètes à portée selon le besoin de prospection.
- **Résultats récents** : de 0 à 10, avec 3 par défaut. Ils aident à comprendre les conséquences et les échecs précédents, mais rallongent le contexte.
- **Messages et entrepôt** : utiles à la coordination et au stockage lorsqu'ils interviennent réellement dans la tâche.
- **Superviseur** : les résultats détaillés ajoutent jusqu'à trois résultats récents par agent ; compétences, filons et prix sont des sections optionnelles.
- **Format** : comparer `compact` et `json` dans le panneau Context. Le premier réduit souvent le contexte, mais ajoute une légende aux règles ; il faut comparer le total, pas seulement la section `context`.
- **Outils et instructions** : équiper les outils nécessaires et écrire une directive précise et concise. Supprimer un outil indispensable ou des informations nécessaires peut provoquer de mauvaises décisions et augmenter les coûts indirects.

Dans le panneau Context, les valeurs `+N` comparent le poids de la section contexte pour une option à l'option minimale de ce réglage, toutes choses égales par ailleurs. Elles évoluent avec la partie ; ce ne sont pas des prix fixes. L'éditeur affiche également le détail estimé et le poids des outils. Le journal des décisions permet de comparer les sections, la sortie, le total et le Compute dépensé. Quand le total provient du fournisseur, les sections d'entrée restent des estimations locales et ne s'additionnent pas nécessairement à ce total réel.

## Budget, fréquence et exécution hors ligne

Le jeu applique un budget partagé de **400 000 tokens par heure réelle glissante**, calculé sur les décisions terminées. Une fois le seuil atteint, les nouvelles décisions sont bloquées avec `Server AI budget reached` jusqu'à ce que des consommations sortent de la fenêtre. La file réserve aussi une estimation pour les requêtes en cours et peut en mettre d'autres en attente si elles ne tiennent pas dans le budget restant. Axis réévalue cette réservation après ajout de son contexte, avant l'appel au modèle. Les estimations ne constituent toutefois pas un plafond strict : une requête seule peut démarrer même si son estimation dépasse le budget restant, et l'utilisation réelle peut dépasser les réservations. Les requêtes encore en attente lorsque le seuil est atteint sont abandonnées et leur Compute est remboursé. Il y a au plus **4 requêtes simultanées** ; les autres attendent, avec priorité au superviseur puis aux plus anciennes.

Un agent est également limité à **5 décisions par 30 secondes de jeu**. Pour un fournisseur réel, aux vitesses supérieures à x1, deux demandes du même agent sont espacées d'au moins **6 secondes réelles**. Le compteur de débit en Compute par heure utilise quant à lui le temps de jeu, sur une fenêtre allant jusqu'à 600 secondes de jeu : il ne faut pas le confondre avec le budget de tokens par heure réelle.

Une **skill** exécute une séquence d'actions prédéfinie sans appel IA, sans tokens et sans Compute par étape. Une décision IA qui lance `run_skill` reste une décision facturée. Les skills conviennent aux opérations répétitives et stables ; l'IA est utile pour choisir, adapter ou superviser lorsque la situation varie. Pendant la progression hors ligne, seuls les agents en mode skill continuent à agir : aucun appel IA ni dépense de Compute ne sont effectués. La simulation hors ligne est limitée à 8 heures par défaut.

## Fournisseur réel et limites des chiffres

Par défaut, `provider = "stub"` : les décisions sont simulées localement, sans appel à un modèle externe, tout en consommant le Compute et le budget simulés. Avec `axis`, le jeu utilise le modèle configuré `claude-haiku-4-5`, avec une limite demandée de **150 tokens de sortie**. Cette limite n'est pas l'estimation de sortie de 40 tokens utilisée pour le débit initial.

Axis ajoute au message système du jeu une configuration d'agent et un bloc de mémoire récupérés auprès de la plateforme. Ils peuvent augmenter les tokens réellement envoyés, sans être inclus dans le découpage local affiché avant l'appel. Le fournisseur conserve aussi sa propre estimation de diagnostic, calculée sur les messages locaux plus la limite maximale de sortie ; elle diffère donc de l'estimation de facturation initiale. Les autres échanges HTTP avec Axis ne sont pas eux-mêmes comptés comme des appels au modèle dans ce calcul. La facturation externe éventuelle dépend du fournisseur et n'est pas calculée par l'économie en crédits du jeu.

## Références dans le code

- Paramètres et valeurs par défaut : [`scripts/config/ai.luau`](../scripts/config/ai.luau), [`scripts/config/balance.luau`](../scripts/config/balance.luau).
- Construction des messages et du contexte : [`scripts/sim/prompt.luau`](../scripts/sim/prompt.luau), [`scripts/sim/context_builder.luau`](../scripts/sim/context_builder.luau), [`scripts/sim/context_settings.luau`](../scripts/sim/context_settings.luau).
- Facturation, file et décisions : [`scripts/sim/compute.luau`](../scripts/sim/compute.luau), [`scripts/sim/ai_queue.luau`](../scripts/sim/ai_queue.luau), [`scripts/sim/sim.luau`](../scripts/sim/sim.luau).
- Fournisseur et mémoire : [`scripts/ai/provider.luau`](../scripts/ai/provider.luau), [`scripts/ai/axis.luau`](../scripts/ai/axis.luau).
- Exécution des skills et hors ligne : [`scripts/sim/skills.luau`](../scripts/sim/skills.luau), [`scripts/sim/offline.luau`](../scripts/sim/offline.luau).
