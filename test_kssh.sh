#!/usr/bin/env bash
# ==============================================================================
# TEST SUITE ÉTENDUE : kssh (KeePassSSH)
# AUTEUR       : Q300Z (https://qalpuch.cc)
# ==============================================================================

set -eo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly KSSH_BIN="${SCRIPT_DIR}/kssh"
readonly TEST_DIR="/tmp/kssh_test_env_$$"
mkdir -p "$TEST_DIR"

export SSH_CONFIG_DIR="$TEST_DIR/.ssh"
export SSH_CONFIG_FILE="$TEST_DIR/.ssh/config"
export BASH_COMPLETION_DIR="$TEST_DIR/completions"
export ZSH_COMPLETION_DIR="$TEST_DIR/zsh"
export KEEPASS_DB="$TEST_DIR/mock.kdbx"
mkdir -p "$SSH_CONFIG_DIR" "$BASH_COMPLETION_DIR" "$ZSH_COMPLETION_DIR"

cleanup() {
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

PASSED=0
FAILED=0

assert_success() {
    local desc="$1"; shift
    if "$@" < /dev/null >/dev/null 2>&1; then
        printf '  \033[0;32m✓\033[0m [PASS] %s\n' "$desc"
        PASSED=$((PASSED + 1))
    else
        printf '  \033[0;31m✗\033[0m [FAIL] %s\n' "$desc"
        FAILED=$((FAILED + 1))
    fi
}

assert_failure() {
    local desc="$1"; shift
    if ! "$@" < /dev/null >/dev/null 2>&1; then
        printf '  \033[0;32m✓\033[0m [PASS] %s\n' "$desc"
        PASSED=$((PASSED + 1))
    else
        printf '  \033[0;31m✗\033[0m [FAIL] %s\n' "$desc"
        FAILED=$((FAILED + 1))
    fi
}

assert_output_contains() {
    local desc="$1"
    local expected="$2"
    shift 2
    local output
    output=$("$@" < /dev/null 2>&1 || true)
    if grep -Fqs "$expected" <<< "$output"; then
        printf '  \033[0;32m✓\033[0m [PASS] %s\n' "$desc"
        PASSED=$((PASSED + 1))
    else
        printf '  \033[0;31m✗\033[0m [FAIL] %s (Attendu: "%s", Reçu: "%s")\n' "$desc" "$expected" "$output"
        FAILED=$((FAILED + 1))
    fi
}

echo "=== Démarrage de la Suite de Tests kssh ==="

# [1] Affichage & Informations
assert_output_contains "Version kssh" "kssh" "$KSSH_BIN" --version
assert_output_contains "Aide en ligne" "USAGE :" "$KSSH_BIN" --help
assert_output_contains "Délégation OpenSSH version" "OpenSSH" "$KSSH_BIN" -V

# [2] Listing des serveurs (Fichier absent vs Fichier vide)
rm -f "$SSH_CONFIG_FILE"
assert_output_contains "Listing config absente" "Fichier ~/.ssh/config absent" "$KSSH_BIN" --list
touch "$SSH_CONFIG_FILE"
assert_output_contains "Listing serveur vide" "Aucun serveur configuré" "$KSSH_BIN" --list

# [3] Validation des Alias (--add)
assert_failure "Rejet alias avec espaces" "$KSSH_BIN" --add "alias invalide" 192.168.1.1
assert_failure "Rejet alias avec point-virgule" "$KSSH_BIN" --add "srv;ls" 192.168.1.1
assert_failure "Rejet alias avec injection shell" "$KSSH_BIN" --add 'srv$(whoami)' 192.168.1.1
assert_failure "Rejet alias avec pipe" "$KSSH_BIN" --add "srv|test" 192.168.1.1
assert_failure "Rejet alias vide" "$KSSH_BIN" --add "" 192.168.1.1

# [4] Validation des Ports
assert_failure "Rejet port 0" "$KSSH_BIN" --add test_srv root@192.168.1.1:0
assert_failure "Rejet port 65536" "$KSSH_BIN" --add test_srv root@192.168.1.1:65536
assert_failure "Rejet port négatif" "$KSSH_BIN" --add test_srv root@192.168.1.1:-22
assert_failure "Rejet port non-numérique" "$KSSH_BIN" --add test_srv root@192.168.1.1:ssh

# [5] Validation des Noms d'utilisateurs
assert_failure "Rejet nom utilisateur avec espaces" "$KSSH_BIN" --add test_srv "user name@192.168.1.1"

# [6] Ajout avec Clé SSH (IdentityFile)
assert_success "Ajout serveur avec clé SSH" "$KSSH_BIN" --add vps_cle debian@51.15.20.30:2222 -i /tmp/mock_key
assert_output_contains "Présence dans la config après ajout" "vps_cle" "$KSSH_BIN" --list

# [6.1] Ajout avec drapeau -l / --user explicite
assert_success "Ajout serveur avec -l explicite" "$KSSH_BIN" --add serv_admin 192.168.1.113 -l administrateur -i /tmp/mock_key
assert_output_contains "Présence serv_admin dans la config" "serv_admin" "$KSSH_BIN" --list

# [7] Support IPv6
assert_success "Ajout serveur IPv6 avec port" "$KSSH_BIN" --add srv_ipv6 "admin@[2001:db8::1]:2222" -i /tmp/mock_key
assert_output_contains "Présence IPv6 dans la config" "srv_ipv6" "$KSSH_BIN" --list

# [8] Détection d'alias existant (Anti-duplication)
assert_output_contains "Détection alias déjà existant" "existe déjà dans ~/.ssh/config" "$KSSH_BIN" --add vps_cle debian@51.15.20.30 -i /tmp/mock_key

# [9] Parsing des options OpenSSH complexes
assert_success "Parsing option -o avec valeur" "$KSSH_BIN" -o StrictHostKeyChecking=no -V
assert_success "Parsing option -p séparé" "$KSSH_BIN" -p 2222 -V
assert_success "Parsing option -l avec argument" "$KSSH_BIN" -l admin -V
assert_success "Parsing option booléenne -X" "$KSSH_BIN" -X -V
assert_success "Parsing option -4 et -C" "$KSSH_BIN" -4 -C -V

# [10] Mode Debug
assert_output_contains "Mode debug actif" "[DEBUG]" "$KSSH_BIN" --debug -V

# [11] Installation explicite
assert_output_contains "Installation explicite sans root" "Toutes les dépendances" "$KSSH_BIN" --install

# [12] Cache de session & Agent SSH
assert_output_contains "Commande de verrouillage --lock" "Cache mémoire de session vidé" "$KSSH_BIN" --lock
assert_success "Vérification commande --agent" "$KSSH_BIN" --agent

echo ""
echo "=========================================="
echo "  BILAN : $PASSED tests réussis / $((PASSED + FAILED)) au total"
echo "  Échecs : $FAILED"
echo "=========================================="

[ "$FAILED" -eq 0 ] && exit 0 || exit 1
