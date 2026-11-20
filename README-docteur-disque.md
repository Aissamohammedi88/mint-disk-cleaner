# Docteur Disque v1.0 — pour Linux Mint

Un seul fichier, `docteur-disque.sh`, qui répond à six besoins :
**audit** du disque, **benchmark** avant/après, **nettoyage par étapes**,
**sticky bit**, **surveillance automatique** et **vidéo MP4 récapitulative**.

## Démarrage rapide

```bash
chmod +x docteur-disque.sh
./docteur-disque.sh
```

Lance-le avec **ton utilisateur normal** : le script demandera `sudo`
quand il en a besoin (Timeshift, logs, apt, sticky bit…), sans polluer
ton dossier personnel.

## Le menu

| Choix | Ce que ça fait |
|---|---|
| **1) Audit** | Trouve qui remplit le disque : Timeshift, logs, journal systemd, cache APT, cache utilisateur, corbeille, fichiers « fantômes » supprimés mais encore ouverts, plus gros dossiers/fichiers, programmes qui écrivent en ce moment. Si le disque est à ≥ 95 %, affiche des commandes d'urgence. |
| **2) Benchmark AVANT** | Mesure la vitesse écriture/lecture du disque (test `dd` de 512 Mo, réduit automatiquement si le disque est plein — même à 0 octet libre il s'adapte). |
| **3) Nettoyage guidé** | Une question Oui/Non par catégorie : snapshots Timeshift (tu choisis combien garder, **3 par défaut**), journal systemd (limité à 100 Mo), vieilles archives de logs, cache APT + autoremove, miniatures et cache utilisateur, corbeille, flatpak inutilisés, vieilles révisions snap, rapports de plantage. Rien n'est supprimé sans ta confirmation. |
| **4) Benchmark APRÈS** | Refait la mesure pour comparer. |
| **5) Sticky bit** | Vérifie que `/tmp`, `/var/tmp`, `/dev/shm` ont le mode `1777` (le « t » qui empêche chacun de supprimer les fichiers des autres) et **corrige** si besoin ; scanne aussi les autres dossiers « écrivables par tous » sans sticky bit et les fichiers modifiables par tout le monde. |
| **6) Surveillance auto** | Installe un timer systemd : toutes les 15 min, si `/` dépasse **85 %**, purge automatiquement journal systemd (à 100 Mo), cache APT et vieilles archives de logs — jamais tes documents, jamais Timeshift, jamais la corbeille. Journal des actions : `/var/log/docteur-disque-auto.log`. |
| **7) Vidéo MP4** | Génère `docteur-disque-rapport.mp4` (~20 s) : titre, barres animées AVANT/APRÈS (Timeshift, logs, caches, corbeille), résultats du benchmark, résumé. Nécessite `ffmpeg` : `sudo apt install ffmpeg`. |
| **8) Tout enchaîner** | 1 → 7 dans l'ordre, avec les questions habituelles. |
| **9) Désinstaller la surveillance** | Retire le timer, le service et le script auto. |
| **a) Qui écrit maintenant ?** | Liste les gros fichiers modifiés durant les 60 dernières secondes : à lancer **pendant** que le disque se remplit pour attraper le coupable. |

## Pourquoi ton disque se remplit tout seul ?

Sur Linux Mint, les coupables classiques sont :

1. **Timeshift** : chaque snapshot garde une copie des fichiers modifiés ;
   avec beaucoup de snapshots, ça peut engloutir 100 Go et plus.
   Conseil : dans Timeshift → Paramètres → Filtres, garde **2-3 snapshots**
   (c'est ce que propose le nettoyage guidé).
2. **Les logs** : journal systemd et `/var/log` grossissent sans limite si
   rien ne les borne — le nettoyage guidé et la surveillance auto s'en chargent.
3. **Un programme qui déraille** : un service qui boucle écrit des Go dans
   ses logs. L'audit (menu 1) et le menu « a » servent à l'identifier.
4. **Des fichiers fantômes** : un fichier supprimé mais encore ouvert par un
   programme occupe l'espace jusqu'au redémarrage de ce programme.

## Options en ligne de commande

```bash
./docteur-disque.sh --audit        # lecture seule
./docteur-disque.sh --sticky       # audit sticky bit, sans correction
./docteur-disque.sh --bench-before # benchmark avant nettoyage
./docteur-disque.sh --bench-after  # benchmark après nettoyage
./docteur-disque.sh --video        # vidéo depuis les chiffres enregistrés
./docteur-disque.sh --demo         # vidéo d'exemple (chiffres fictifs)
./docteur-disque.sh --auto-install # surveillance auto (sudo requis)
./docteur-disque.sh --auto-remove  # désinstalle la surveillance
./docteur-disque.sh --help         # aide
```

Variables d'environnement : `DD_SEUIL=85` (seuil de la surveillance),
`DD_BENCH_MB=512` (taille du test benchmark), `OUT_VIDEO=/chemin/x.mp4`
(destination de la vidéo).

Les chiffres de chaque étape sont mémorisés dans `~/.docteur-disque/etat.conf` :
c'est ce qui permet de comparer avant/après et de bâtir la vidéo.

## Prérequis

- Bash et les outils GNU standard (installés sur Mint) ;
- `ffmpeg` pour la vidéo (`sudo apt install ffmpeg`) ;
- `sudo` pour les étapes système (Timeshift, journal, apt, sticky bit, timer).

Testé avec succès sur un système Linux de test : audit, benchmark,
audit sticky bit, rendu vidéo (5 scènes, animation, accents, %) et
syntaxe du script de surveillance automatique.
