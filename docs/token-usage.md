# Tokens : developpement et agents GRIDMIND

Etat des lieux du 8 novembre 2026. Ce document distingue les tokens utilises
pour construire le projet de ceux que les agents du jeu peuvent consommer
pendant une partie. Ce ne sont pas les memes compteurs.

## Developpement du jeu et configuration des agents

Les agents SuperFlip utilisent un modele pour lire les instructions, les
issues, les specifications, le code et les resultats d'outils, puis pour
produire leurs analyses, modifications et reponses. Les echanges successifs
peuvent renvoyer une partie du contexte au modele. Ces activites expliquent
les postes possibles de consommation, mais ne permettent pas d'en deduire
des quantites sans releve du fournisseur.

Exemples de travail realise : implementation de la simulation et de l'UI,
integration de l'IA, tests et corrections, revues de PR, et configuration
des instructions et competences des agents. La creation d'une fiche d'agent
dans SuperFlip n'est pas en elle-meme une mesure de tokens : les appels au
modele executes pendant sa conception et ses taches sont a compter dans les
releves correspondants.

### Mesures disponibles

Le 8 novembre 2026, `superflip runtime usage <id> --days 90 --output json`
a renvoye `[]` pour les runtimes Codex du MacBook et du XPS, ainsi que pour
le runtime Claude du MacBook. Le meme releve sur 365 jours a renvoye `[]`
pour les runtimes Claude et Codex d'archlinux. Ces resultats ne prouvent pas
une consommation nulle : aucune ligne d'usage n'a ete retournee par ces
requetes. Les listes de taches consultees ne fournissaient pas de compteurs
de tokens par tache.

| Question | Etat |
| --- | --- |
| Total des tokens de developpement | Inconnu |
| Part par agent, modele ou ticket | Inconnue |
| Part entree, sortie, cache et raisonnement | Inconnue |
| Cout reel | Inconnu ; il depend aussi des tarifs et de la facturation |

Les runtimes peuvent servir a plusieurs agents ou projets : meme un total par
runtime ne suffit pas a attribuer toute sa consommation a GRIDMIND. Les
chiffres complets exigent des releves fournisseurs et, pour une ventilation
par tache, des compteurs relies aux executions. Ne pas additionner des releves
qui couvrent les memes appels. Ne pas publier d'identifiants secrets, de cles
API ni de contenu prive dans ce depot.

## Tokens des agents pendant une partie

Le jeu construit des requetes de decision a partir notamment des instructions
et du contexte d'un agent. En mode fournisseur reel, Axis assemble la requete
et transmet la reponse du modele ; celle-ci peut contenir des compteurs
`input_tokens` et `output_tokens` (voir `scripts/ai/axis.luau`). Le fournisseur
du jeu conserve un nombre limite de traces de decisions, avec estimation et
compteurs eventuels (`scripts/ai/provider.luau`). Ce n'est pas un historique
exhaustif de la construction du jeu.

- L'estimation utilise la longueur du texte et `charsPerToken` ; ce n'est pas
  un comptage par tokenizer (`scripts/sim/compute.luau`).
- La file limite les requetes concurrentes et le budget de tokens sur une
  fenetre glissante. Une reservation est une estimation, pas une facture
  (`scripts/sim/ai_queue.luau`).
- Quand les compteurs du fournisseur sont valides, la simulation les utilise
  pour regulariser le Compute et la file ; sinon elle utilise une estimation
  (`scripts/sim/sim.luau`, `Sim:onAiResponse`).
- Le Compute est une ressource de jeu calculee et arrondie par la simulation.
  Il ne constitue ni un montant en monnaie reelle ni la facture du fournisseur.
- Une reponse invalide ou un echec peut quand meme entrainer une consommation ;
  ne pas supposer qu'une decision sans resultat a coute zero.

## Comment etablir un bilan chiffre

1. Fixer une periode, la liste des agents et des runtimes, et le perimetre
   (developpement, jeu en fonctionnement, ou les deux separement).
2. Exporter les releves d'usage des fournisseurs concernes, avec les dates,
   modeles, tokens d'entree et de sortie, cache et cout lorsque disponibles.
3. Rapprocher les releves des executions ou des traces de decision ; marquer
   toute attribution incertaine comme inconnue plutot que l'estimer au hasard.
4. Distinguer les compteurs reels des estimations, les essais en mode stub des
   appels reels, et les couts de developpement de ceux d'une partie.
5. Consigner la date, les sources, les lacunes et les tarifs appliques. Les
   totaux sans attribution par projet doivent rester clairement identifies.
