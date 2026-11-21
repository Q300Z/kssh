# kssh (KeePassSSH)

[![Licence: MIT](https://img.shields.io/badge/Licence-MIT-blue.svg)](LICENSE)
[![Bash](https://img.shields.io/badge/Shell-Bash%204.0%2B-green.svg)](https://www.gnu.org/software/bash/)
[![OpenSSH](https://img.shields.io/badge/SSH-OpenSSH%20Native-orange.svg)](https://www.openssh.com/)
[![KeePassXC](https://img.shields.io/badge/Vault-KeePassXC-brightgreen.svg)](https://keepassxc.org/)

Orchestrateur et gestionnaire de connexions OpenSSH automatisé avec stockage chiffré **KeePassXC** et injection sécurisée **SSHPass**.

---

## 📑 Table des matières

1. [Présentation](#-présentation)
2. [Fonctionnalités & Sécurité](#-fonctionnalités--sécurité)
3. [Prérequis & Dépendances](#-prérequis--dépendances)
4. [Installation](#-installation)
   - [Installation automatique](#1-installation-automatique)
   - [Installation manuelle](#2-installation-manuelle)
   - [Autocomplétion (Bash & Zsh)](#3-autocomplétion-bash--zsh)
5. [Configuration](#-configuration)
6. [Utilisation](#-utilisation)
   - [Connexions SSH](#1-connexion-ssh)
   - [Ajouter un serveur (`--add`)](#2-ajouter-un-serveur---add)
   - [Lister les serveurs (`--list`)](#3-lister-les-serveurs---list)
   - [Gestion du cache de session (`--lock`)](#4-verrouillage-et-cache---lock)
   - [Agent SSH KeePassXC (`--agent`)](#5-statut-de-lagent-ssh---agent)
   - [Mode Débogage (`--debug`)](#6-mode-débogage---debug)
7. [Développement & Tests](#-développement--tests)
8. [Auteur & Licence](#-auteur--licence)

---

## 🎯 Présentation

**kssh** est un wrapper transparent et hautement sécurisé pour OpenSSH. Il résout le problème récurrent de la gestion des identifiants SSH (mots de passe, clés SSH chiffrées, clés associées) en s'appuyant directement sur votre base de données chiffrée **KeePassXC**.

### Pourquoi utiliser kssh ?

- **Zéro compromis sur la sécurité** : vos secrets restent dans votre coffre fort chiffré KeePassXC (`.kdbx`).
- **Transparence totale avec OpenSSH** : `kssh` accepte toutes les options et arguments natifs d'OpenSSH (`-p`, `-i`, `-l`, `-J`, `-o`, `-L`, etc.) et délègue l'exécution directement à votre binaire SSH.
- **Support des clés et mots de passe** : injection de mot de passe à la volée, extraction automatique de clés privées jointes à vos entrées KeePassXC ou délégation à l'agent SSH natif de KeePassXC.
- **Cache de session en RAM volatile** : déverrouillez votre base une seule fois pour votre session de travail, le mot de passe maître expire automatiquement et ne touche jamais le disque.

---

## 🔒 Fonctionnalités & Sécurité

```
+-------------------------------------------------------------------------------+
|                                 Flux d'exécution                              |
|                                                                               |
|  CLI Input ──► Parser strict OpenSSH ──► Résolution native (ssh -G)           |
|                                                     │                         |
|   ┌─────────────────────────────────────────────────┴────────────────────┐    |
|   │                                                                      │    |
|   ▼                                                                      ▼    |
| [Clé SSH active / Agent SSH]                        [Recherche KeePassXC]     |
|   │                                                                      │    |
|   │                                                                      ▼    |
|   │                                                        [Cache RAM /dev/shm]
|   │                                                                      │    |
|   ▼                                                                      ▼    |
| Connexion OpenSSH Native ◄───────────────────────── Injection sécurisée (FD 3)|
+-------------------------------------------------------------------------------+
```

- **Injection anonyme via File Descriptor (FD 3)** : Le mot de passe n'apparaît **jamais** dans les arguments de processus (`/proc/$PID/cmdline` ou `ps aux`).
- **Hygiène mémoire rigoureuse** : Purge immédiate (`unset`) des variables sensibles et capture des signaux d'interruption (`SIGINT`, `SIGTERM`, `EXIT`).
- **Cache éphémère en mémoire vive** : Stocké dans `/dev/shm` (ou `$XDG_RUNTIME_DIR`) avec permissions strictes `0600` et durée de validité (TTL) configurable.
- **Gestion transactionnelle de `~/.ssh/config`** : Écriture atomique et verrouillée avec préservation stricte des permissions (`0600` pour le fichier, `0700` pour le dossier).
- **Validation stricte des entrées** : Contrôle par expressions régulières des alias, noms d'hôtes, adresses IPv4/IPv6 et plages de ports valides (1-65535).

---

## 📦 Prérequis & Dépendances

`kssh` s'appuie sur des outils standards disponibles sur la quasi-totalité des distributions Linux et macOS :

- **Bash** (v4.0 ou supérieur)
- **OpenSSH** (`ssh`)
- **KeePassXC** (`keepassxc-cli`)
- **sshpass** (pour l'injection sécurisée sans invite de commande)

### Installation des dépendances selon votre distribution

#### Arch Linux / Manjaro
```bash
sudo pacman -S openssh keepassxc sshpass
```

#### Debian / Ubuntu / Linux Mint
```bash
sudo apt update && sudo apt install -y openssh-client keepassxc sshpass
```

#### Fedora / RHEL
```bash
sudo dnf install -y openssh-clients keepassxc sshpass
```

#### openSUSE
```bash
sudo zypper install -y openssh keepassxc sshpass
```

#### macOS (via Homebrew)
```bash
brew install openssh keepassxc hudochenkov/sshpass/sshpass
```

---

## 🚀 Installation

### 1. Installation automatique

Clonez le dépôt et lancez la commande d'installation intégrée :

```bash
git clone git@github.com:Q300Z/kssh.git
cd kssh
./kssh --install
```

La commande `--install` effectue automatiquement les actions suivantes :
1. Vérification des dépendances système nécessaires.
2. Copie du binaire dans `~/.local/bin/kssh` (conforme au standard XDG).
3. Installation des scripts d'autocomplétion pour **Bash** et **Zsh**.
4. Ajout sécurisé du `PATH` et de l'alias optionnel `alias ssh='kssh'` dans `~/.bashrc` ou `~/.zshrc`.

---

### 2. Installation manuelle

Si vous préférez installer `kssh` manuellement :

```bash
# 1. Rendre le script exécutable
chmod +x kssh

# 2. Copier le binaire dans votre dossier local
mkdir -p ~/.local/bin
cp kssh ~/.local/bin/kssh

# 3. Ajouter ~/.local/bin à votre PATH (si ce n'est pas déjà fait)
# Pour Bash (~/.bashrc) ou Zsh (~/.zshrc) :
export PATH="$HOME/.local/bin:$PATH"
```

#### Alias transparent (Optionnel)
Pour remplacer automatiquement la commande `ssh` par `kssh` dans votre shell interactif :

```bash
alias ssh='kssh'
```

> **Note (`scp`, `sftp`, `rsync`, `git`)** : Un alias shell n'affecte pas les sous-processus externes. Pour utiliser `kssh` avec ces outils :
> - `scp -S kssh fichier serveur:/chemin`
> - `sftp -S kssh serveur`
> - `rsync -av -e kssh dossier/ serveur:/chemin`
> - `GIT_SSH_COMMAND="kssh" git clone git@serveur:repo.git`

---

### 3. Autocomplétion (Bash & Zsh)

#### Pour Bash
```bash
mkdir -p ~/.local/share/bash-completion/completions
# L'autocomplétion est générée automatiquement via ./kssh --install
```
Ajoutez dans votre `~/.bashrc` si nécessaire :
```bash
[[ -f ~/.local/share/bash-completion/completions/kssh ]] && source ~/.local/share/bash-completion/completions/kssh
```

#### Pour Zsh
```bash
mkdir -p ~/.local/share/zsh/site-functions
```
Ajoutez dans votre `~/.zshrc` :
```zsh
fpath=(~/.local/share/zsh/site-functions $fpath)
autoload -Uz compinit && compinit
```

---

## ⚙️ Configuration

`kssh` peut être personnalisé via des variables d'environnement (dans votre `.bashrc`, `.zshrc` ou votre environnement de session) :

| Variable | Valeur par défaut | Description |
| :--- | :--- | :--- |
| `KEEPASS_DB` | `$HOME/Database.kdbx` | Chemin absolu vers votre base de données KeePassXC |
| `KEEPASS_KEYFILE` | `""` *(vide)* | Fichier de clé optionnel pour ouvrir la base KeePassXC |
| `KEEPASS_ROOT_GROUP` | `Database` | Groupe racine dans lequel chercher les entrées |
| `KSSH_CACHE_ENABLED` | `true` | Active/Désactive la conservation du mot de passe maître en RAM |
| `KSSH_CACHE_TTL` | `7200` *(2 heures)* | Durée de vie du cache mémoire en secondes avant expiration |
| `SSH_CONFIG_FILE` | `$HOME/.ssh/config` | Emplacement du fichier de configuration OpenSSH |
| `OPENSSH_BIN` | Résolution auto | Chemin explicite vers le binaire `ssh` du système |

Exemple de configuration dans votre `~/.bashrc` :
```bash
export KEEPASS_DB="$HOME/Securite/Coffre.kdbx"
export KEEPASS_KEYFILE="$HOME/Securite/master.key"
export KSSH_CACHE_TTL=14400  # 4 heures
```

---

## 💡 Utilisation

### 1. Connexion SSH

`kssh` fonctionne exactement comme la commande `ssh` standard avec autocomplétion des alias configurés :

```bash
# Connexion via un alias configuré
kssh mon_serveur

# Connexion avec spécification d'utilisateur et de port
kssh -p 2222 debian@51.15.20.30

# Exécution d'une commande distante
kssh nas 'uptime && df -h'

# Options avancées OpenSSH transparentes
kssh -X -C -o StrictHostKeyChecking=no admin@192.168.1.50
```

---

### 2. Ajouter un serveur (`--add`)

Ajoutez un serveur de façon interactive ou directe dans votre `~/.ssh/config` et synchronisez son entrée dans KeePassXC :

```bash
# Ajout simple avec port personnalisé
kssh --add mon_vps debian@51.15.20.30:2222

# Ajout avec clé SSH dédiée
kssh --add mon_raspi pi@192.168.1.50 -i ~/.ssh/id_ed25519

# Ajout d'une machine avec adresse IPv6
kssh --add srv_ipv6 "admin@[2001:db8::1]:2222"
```

---

### 3. Lister les serveurs (`--list`)

Affichez tous les serveurs et alias configurés dans votre fichier `~/.ssh/config` :

```bash
kssh --list
```

---

### 4. Verrouillage et Cache (`--lock`)

Pour purger immédiatement le mot de passe maître de la mémoire vive (`/dev/shm`) et reverrouiller l'accès :

```bash
kssh --lock
```

---

### 5. Statut de l'Agent SSH (`--agent`)

Vérifiez si un Agent SSH (notamment l'agent intégré de KeePassXC) est actif et détecté :

```bash
kssh --agent
```

---

### 6. Mode Débogage (`--debug`)

Pour afficher le diagnostic détaillé et suivre les étapes de résolution :

```bash
kssh --debug mon_serveur
```

---

## 🧪 Développement & Tests

Le dépôt dispose d'une suite complète de tests unitaires et de tests d'intégration End-to-End (E2E) fonctionnant en bac à sable isolé (sandbox temporaire étanche).

### Structure du projet

```
kssh/
├── kssh               # Script principal d'orchestration OpenSSH / KeePassXC
├── test_kssh.sh       # Suite de tests unitaires (parsing, validation, options)
├── test_kssh_e2e.sh   # Suite de tests d'intégration End-to-End (E2E)
├── .gitignore         # Fichiers ignorés par Git
└── README.md          # Documentation du projet
```

### Exécution des tests

Pour lancer les tests unitaires :
```bash
./test_kssh.sh
```

Pour exécuter la suite de tests End-to-End :
```bash
./test_kssh_e2e.sh
```

Pour exécuter l'ensemble des suites :
```bash
./test_kssh.sh && ./test_kssh_e2e.sh
```

---

## 👤 Auteur & Licence

- **Auteur** : [Q300Z](https://github.com/Q300Z)
- **Site Web** : [https://qalpuch.cc](https://qalpuch.cc)
- **Dépôt Git** : [git@github.com:Q300Z/kssh.git](git@github.com:Q300Z/kssh.git)
- **Licence** : [MIT](LICENSE)
