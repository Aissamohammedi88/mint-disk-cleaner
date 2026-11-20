<div align="center">

# 🚀 Linux-DiskGuard & Benchmark
### *L'outil ultime d'audit, benchmark disque et nettoyage automatisé pour Linux Mint, Ubuntu & Debian*

[![GitHub Stars](https://img.shields.io/github/stars/votre-nom-utilisateur/linux-diskguard?style=for-the-badge&logo=github&color=ffb703&label=Laissez%20une%20%E2%AD%90)](https://github.com/votre-nom-utilisateur/linux-diskguard/stargazers)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg?style=for-the-badge)](LICENSE)
[![Platform](https://img.shields.io/badge/OS-Linux%20Mint%20%7C%20Ubuntu%20%7C%20Debian-brightgreen?style=for-the-badge&logo=linux)](https://linuxmint.com)
[![Bash](https://img.shields.io/badge/Shell-Bash%205%2B-black?style=for-the-badge&logo=gnu-bash)](https://www.gnu.org/software/bash/)
[![Open Source Love](https://img.shields.io/badge/Open%20Source-%E2%99%A5-e63946?style=for-the-badge)](#-pourquoi-soutenir-ce-projet-)

<p align="center">
  <a href="#-fonctionnalités-clés">Fonctionnalités</a> •
  <a href="#-aperçu-du-terminal">Interface</a> •
  <a href="#-installation-rapide">Installation</a> •
  <a href="#-guide-des-modules">Guide détaillé</a> •
  <a href="#-pourquoi-soutenir-ce-projet-">Supporter ⭐</a>
</p>

---

> 💡 **Vous en avez marre de voir votre partition racine (`/`) frôler les 85 % ou 90 % d'espace disque ?**  
> **Linux-DiskGuard** identifie exactement qui remplit votre disque, mesure vos performances E/S avant/après, nettoie sans casser votre système et surveille votre stockage en arrière-plan.

</div>

---

## 🌟 Pourquoi soutenir ce projet ?

Le développement et la maintenance de scripts système ouverts et sûrs demandent du temps et des tests rigoureux.

Si cet outil vous a fait **gagner des gigaoctets** ou **accéléré votre machine** :

⭐ **Laissez une Étoile (Star) en haut à droite du dépôt GitHub !**  
C'est 100 % gratuit, cela donne de la visibilité au projet et motive la publication de nouvelles mises à jour.

```markdown
⭐ Comment aider en 3 secondes :
1. Cliquez sur le bouton "Star" en haut à droite de cette page GitHub.
2. Partagez l'outil sur vos forums, Reddit (r/linuxmint, r/linuxfr) ou Discord.
3. Ouvrez une Issue ou une Pull Request si vous avez une idée d'optimisation !
```

---

## 🖥️ Aperçu du Terminal

Voici l'interface TUI interactive affichée directement dans votre terminal :

```text
========================================================================
                      LINUX-DISKGUARD & BENCHMARK
========================================================================
 État actuel        : partition / remplie à 85 % ⚠️
 Surveillance auto  : ACTIVE ✔ (vérification toutes les 15 min)
========================================================================

   1)  Audit complet — qui remplit le disque ?
   2)  Benchmark disque AVANT nettoyage
   3)  Nettoyage guidé par étapes (Oui/Non à chaque catégorie)
   4)  Benchmark disque APRÈS nettoyage
   5)  Sticky bit : audit + correction
   6)  Installer la surveillance auto (purge si ≥ 85 %)
   7)  Générer la vidéo MP4 récapitulative
   8)  TOUT enchaîner (1 → 7)
   9)  Désinstaller la surveillance auto
   a)  Qui écrit sur le disque en ce moment ?
   0)  Quitter

   👉 Ton choix : _
========================================================================
```

---

## ✨ Fonctionnalités Clés

- 🔍 **Audit chirurgical de l'espace disque** : Détection des 20 fichiers/dossiers les plus lourds (`/var/log`, `.cache`, anciens kernels, paquets orphelins).
- ⚡ **Double Benchmark I/O (Avant & Après)** : Mesure des débits en lecture séquentielle et aléatoire (via `fio` / `dd` standardisés) pour prouver le gain réel de performance.
- 🛡️ **Nettoyage guidé avec validation Oui/Non** : Ne supprime rien à l'aveugle. Vous gardez 100 % du contrôle (caches APT/Flatpak/Snap, logs systemd archivés, corbeille, thumbnails).
- 🔒 **Contrôle & Correction du Sticky Bit** : Vérifie la sécurité des répertoires temporaires partagés (`/tmp`, `/var/tmp`) pour éviter les failles locales.
- ⏱️ **Surveillance automatique en tâche de fond** : Watchdog silencieux (cron/systemd timer) toutes les 15 minutes avec déclenchement de purge sécurisée si la partition `/` dépasse 85 %.
- 📹 **Rapport Vidéo MP4 automatisé** : Génère une animation/vidéo résumée de votre gain d'espace et de vos métriques de performance grâce à `ffmpeg`.
- 📊 **Moniteur d'écriture en direct (`a`)** : Inspecte les processus actifs qui saturent les E/S disque en temps réel (via `iotop` / `lsof`).
- 🔄 **Mode Pipeline One-Click (`8`)** : Exécute l'intégralité de la maintenance en une seule fois sans friction.

---

## ⚡ Installation Rapide

### Option 1 : En une seule ligne (Recommandé)

```bash
curl -fsSL https://raw.githubusercontent.com/votre-nom-utilisateur/linux-diskguard/main/install.sh | bash
```

### Option 2 : Installation manuelle via Git

```bash
# 1. Cloner le dépôt
git clone https://github.com/votre-nom-utilisateur/linux-diskguard.git
cd linux-diskguard

# 2. Rendre le script exécutable
chmod +x diskguard.sh

# 3. Lancer l'outil avec les privilèges administrateur
sudo ./diskguard.sh
```

---

## 📖 Guide Détaillé des Modules

<details>
<summary><b>1️⃣ Audit complet — Qui remplit le disque ?</b></summary>

Scanne votre arborescence pour lister :
- Les fichiers volumineux supérieurs à 500 Mo.
- L'espace consommé par `journalctl` (logs systemd).
- Les caches utilisateurs (`~/.cache`) et résidus Flatpak/Snap.
- Les anciens noyaux Linux orphelins non utilisés.
</details>

<details>
<summary><b>2️⃣ & 4️⃣ Benchmarks Disque AVANT / APRÈS</b></summary>

Évalue l'efficacité du nettoyage :
- Test d'écriture directe (I/O throughput).
- Test de lecture et latence d'accès.
- Comparaison synthétique pour vérifier si la libération des blocs améliore les performances du système de fichiers (ext4, btrfs, etc.).
</details>

<details>
<summary><b>3️⃣ Nettoyage guidé par étapes</b></summary>

Chaque catégorie vous demande confirmation (`o/n`) :
- Purge du cache des paquets APT (`apt clean`, `apt autoremove --purge`).
- Nettoyage des journaux systemd (conserve les 7 derniers jours).
- Nettoyage des caches d'applications (miniatures, navigateurs, caches temporaires).
- Vidage des corbeilles utilisateurs et répertoires `/tmp` obsolètes.
</details>

<details>
<summary><b>5️⃣ Sticky Bit : Audit + Correction</b></summary>

Le *sticky bit* (permission `t`) sur `/tmp` empêche un utilisateur non privilégié de supprimer ou renommer les fichiers d'un autre utilisateur.
Le script vérifie la conformité (ex. `chmod 1777 /tmp`) et corrige les dérives de permissions.
</details>

<details>
<summary><b>6️⃣ & 9️⃣ Surveillance Automatique (Watchdog 15 min)</b></summary>

- Installe un timer systemd ou une tâche cron exécutée toutes les 15 minutes.
- Analyse le taux d'occupation de la racine `/`.
- Si `espace >= 85 %` : déclenche une notification desktop et exécute une purge d'urgence ciblée.
- Option `9` pour désinstaller proprement le service en un clic.
</details>

<details>
<summary><b>7️⃣ Générer la vidéo MP4 récapitulative</b></summary>

Compile les résultats de l'audit et du benchmark dans une courte vidéo MP4 prête à être partagée ou archivée pour vos rapports d'administration système. Nécessite `ffmpeg`.
</details>

<details>
<summary><b>a) Qui écrit sur le disque en ce moment ?</b></summary>

Affiche instantanément les processus qui saturent la bande passante disque (I/O read/write) pour diagnostiquer les freezes et les ralentissements inopinés.
</details>

---

## 🏷️ Tags & Mots-Clés GitHub (SEO Topics)

Pour maximiser l'indexation de votre dépôt sur GitHub et Google, ajoutez ces tags dans la section **About ⚙️ > Topics** de votre dépôt :

```text
linux-mint, ubuntu, debian, disk-cleanup, disk-benchmark, system-maintenance,
storage-monitor, bash-script, tui, iotop, sysadmin-tools, storage-cleanup,
auto-purge, sticky-bit, devops-tools, linux-tools, open-source
```

---

## 📋 Prérequis

- Distribution basée sur Debian/Ubuntu : **Linux Mint 20/21/22**, Ubuntu 20.04+, Debian 11/12.
- Droits root (`sudo`).
- Dépendances légères (installées automatiquement si manquantes) : `coreutils`, `util-linux`, `iotop`, `ffmpeg` (optionnel pour la vidéo).

---

## 🤝 Contribution

Les contributions sont les bienvenues ! Pour participer :
1. Forkez le dépôt.
2. Créez une branche dédiée (`git checkout -b feature/nouvelle-amelioration`).
3. Commitez vos modifications (`git commit -m 'Ajout d'une détection Flatpak'`).
4. Poussez vers la branche (`git push origin feature/nouvelle-amelioration`).
5. Ouvrez une **Pull Request**.

---

## 📄 Licence

Ce projet est sous licence **MIT**. Vous êtes libre de l'utiliser, le modifier et le redistribuer librement. Consultez le fichier [LICENSE](LICENSE) pour plus de détails.

<div align="center">
  <sub>Fait avec ❤️ pour la communauté Linux Mint et les passionnés du monde Open Source.</sub>
</div>
