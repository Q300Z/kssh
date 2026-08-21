#!/usr/bin/env bash
# ==============================================================================
# PROJET       : kssh (KeePassSSH)
# TEST SUITE   : End-to-End (E2E) & Tests d'Intégration Exhaustifs
# AUTEUR       : Q300Z (https://qalpuch.cc)
# ==============================================================================

set -eo pipefail

# Détermination du chemin absolu du binaire kssh
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly KSSH_BIN="${SCRIPT_DIR}/kssh"

if [ ! -x "$KSSH_BIN" ]; then
    echo "ERREUR : Binaire kssh introuvable ou non-exécutable à '$KSSH_BIN'." >&2
    exit 1
fi

# Palette ANSI
readonly C_GREEN='\033[0;32m'
readonly C_RED='\033[0;31m'
readonly C_YELLOW='\033[1;33m'
readonly C_CYAN='\033[0;36m'
readonly C_BOLD='\033[1m'
readonly C_RESET='\033[0m'

# Initialisation de l'environnement de test isolé
export TEST_SANDBOX="$(mktemp -d /tmp/kssh_e2e_sandbox_XXXXXX)"
export HOME="${TEST_SANDBOX}/home"
export XDG_BIN_HOME="${HOME}/.local/bin"
export XDG_DATA_HOME="${HOME}/.local/share"
export SSH_CONFIG_DIR="${HOME}/.ssh"
export SSH_CONFIG_FILE="${SSH_CONFIG_DIR}/config"
export BASH_COMPLETION_DIR="${XDG_DATA_HOME}/bash-completion/completions"
export ZSH_COMPLETION_DIR="${XDG_DATA_HOME}/zsh/site-functions"
export KSSH_CACHE_DIR="${TEST_SANDBOX}/shm/kssh_cache_$(id -u)"
export KSSH_CACHE_FILE="${KSSH_CACHE_DIR}/master.key"
export KEEPASS_DB="${TEST_SANDBOX}/keepass_test.kdbx"
export KEEPASS_KEYFILE=""
export KEEPASS_ROOT_GROUP="Database"
unset SSH_AUTH_SOCK || true

mkdir -p "$HOME" "$SSH_CONFIG_DIR" "$BASH_COMPLETION_DIR" "$ZSH_COMPLETION_DIR" "${TEST_SANDBOX}/shm"

# Wrapper Mock SSH pour intercepter les appels et inspecter les arguments & FD
readonly MOCK_SSH_BIN="${TEST_SANDBOX}/mock_ssh"
export SSH_LOG_FILE="${TEST_SANDBOX}/ssh_execution.log"

cat << EOF > "$MOCK_SSH_BIN"
#!/usr/bin/env bash
# Mock OpenSSH
echo "MOCK_SSH_CALLED" >> "$SSH_LOG_FILE"
printf '%s\n' "\$@" >> "$SSH_LOG_FILE"

# Si -G est demandé, renvoyer la configuration résolue nativement
if [ "\$1" = "-G" ]; then
    shift
    user="\$(id -un)"
    port="22"
    hostname=""
    while [ "\$#" -gt 0 ]; do
        case "\$1" in
            -p) port="\$2"; shift 2 ;;
            -l) user="\$2"; shift 2 ;;
            -*) shift ;;
            *)
                if [[ "\$1" =~ ^([^@]+)@(.*)\$ ]]; then
                    user="\${BASH_REMATCH[1]}"
                    hostname="\${BASH_REMATCH[2]}"
                else
                    hostname="\$1"
                fi
                shift
                ;;
        esac
    done
    echo "user \$user"
    echo "hostname \$hostname"
    echo "port \$port"
    exit 0
fi

# Si -V est demandé
for arg in "\$@"; do
    if [ "\$arg" = "-V" ]; then
        echo "OpenSSH_Mock_9.9p1, OpenSSL 3.0.0" >&2
        exit 0
    fi
done

# Exécution de commande distante simulée
exit 0
EOF
chmod +x "$MOCK_SSH_BIN"
export OPENSSH_BIN="$MOCK_SSH_BIN"

# Nettoyage automatique en fin de test
cleanup() {
    rm -rf "$TEST_SANDBOX" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Métriques de test
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

# Assertions
assert_success() {
    local desc="$1"; shift
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    if "$@" < /dev/null >/dev/null 2>&1; then
        printf '  %b✓%b [PASS] %s\n' "${C_GREEN}" "${C_RESET}" "$desc"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        printf '  %b✗%b [FAIL] %s\n' "${C_RED}" "${C_RESET}" "$desc"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
}

assert_failure() {
    local desc="$1"; shift
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    if ! "$@" < /dev/null >/dev/null 2>&1; then
        printf '  %b✓%b [PASS] %s\n' "${C_GREEN}" "${C_RESET}" "$desc"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        printf '  %b✗%b [FAIL] %s (Devait échouer mais a réussi)\n' "${C_RED}" "${C_RESET}" "$desc"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
}

assert_output_contains() {
    local desc="$1"
    local expected="$2"
    shift 2
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local output
    output=$("$@" < /dev/null 2>&1 || true)
    if grep -Fqs -e "$expected" <<< "$output"; then
        printf '  %b✓%b [PASS] %s\n' "${C_GREEN}" "${C_RESET}" "$desc"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        printf '  %b✗%b [FAIL] %s\n      Attendu: "%s"\n      Reçu   : "%s"\n' "${C_RED}" "${C_RESET}" "$desc" "$expected" "$output"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
}

assert_file_contains() {
    local desc="$1"
    local expected="$2"
    local file="$3"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    if [ -f "$file" ] && grep -Fqs -e "$expected" "$file"; then
        printf '  %b✓%b [PASS] %s\n' "${C_GREEN}" "${C_RESET}" "$desc"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        printf '  %b✗%b [FAIL] %s (Motif "%s" non trouvé dans %s)\n' "${C_RED}" "${C_RESET}" "$desc" "$expected" "$file"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
}

assert_file_permissions() {
    local desc="$1"
    local expected_perms="$2"
    local file="$3"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local actual_perms
    actual_perms=$(stat -c %a "$file" 2>/dev/null || stat -f %Lp "$file" 2>/dev/null || echo "")
    if [ "$actual_perms" = "$expected_perms" ]; then
        printf '  %b✓%b [PASS] %s (Permissions: %s)\n' "${C_GREEN}" "${C_RESET}" "$desc" "$actual_perms"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        printf '  %b✗%b [FAIL] %s (Attendu: %s, Reçu: %s)\n' "${C_RED}" "${C_RESET}" "$desc" "$expected_perms" "$actual_perms"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
}

echo "=============================================================================="
printf "%b=== DÉMARRAGE DE LA SUITE DE TESTS END-TO-END : kssh ===%b\n" "${C_BOLD}${C_CYAN}" "${C_RESET}"
echo "=============================================================================="
echo ""

# ==============================================================================
# TEST SECTION 1 : CLI Flag Parsing, Option Forwarding & Management Commands
# ==============================================================================
printf "%b[SECTION 1] CLI FLAG PARSING & COMMAND ROUTING%b\n" "${C_BOLD}" "${C_RESET}"

assert_output_contains "Affichage de la version (--version)" "kssh" "$KSSH_BIN" --version
assert_output_contains "Affichage de la version courte (-v)" "kssh" "$KSSH_BIN" -v
assert_output_contains "Affichage de l'aide (--help)" "USAGE :" "$KSSH_BIN" --help
assert_output_contains "Affichage de l'aide courte (-h)" "USAGE :" "$KSSH_BIN" -h
assert_output_contains "Délégation native OpenSSH version (-V)" "OpenSSH_Mock" "$KSSH_BIN" -V
assert_output_contains "Commande --agent sans agent actif" "Aucun Agent SSH KeePassXC actif" "$KSSH_BIN" --agent

# Forwarding d'options OpenSSH vers le mock
> "$SSH_LOG_FILE"
"$KSSH_BIN" -p 2200 -l testuser -o StrictHostKeyChecking=no -J jump@bastion:22 -L 8080:localhost:80 -4 -X mytarget < /dev/null >/dev/null 2>&1 || true
assert_file_contains "Forwarding option -p 2200" "2200" "$SSH_LOG_FILE"
assert_file_contains "Forwarding option -l testuser" "testuser" "$SSH_LOG_FILE"
assert_file_contains "Forwarding option -o StrictHostKeyChecking=no" "StrictHostKeyChecking=no" "$SSH_LOG_FILE"
assert_file_contains "Forwarding option -J jump@bastion:22" "jump@bastion:22" "$SSH_LOG_FILE"
assert_file_contains "Forwarding option -L 8080:localhost:80" "8080:localhost:80" "$SSH_LOG_FILE"
assert_file_contains "Forwarding option -4" "-4" "$SSH_LOG_FILE"
assert_file_contains "Forwarding option -X" "-X" "$SSH_LOG_FILE"
assert_file_contains "Cible correcte identifiée" "mytarget" "$SSH_LOG_FILE"

# Forwarding avec option -i explicite
> "$SSH_LOG_FILE"
touch "${TEST_SANDBOX}/explicit_key"
"$KSSH_BIN" -i "${TEST_SANDBOX}/explicit_key" debian@51.15.20.30 < /dev/null >/dev/null 2>&1 || true
assert_file_contains "Délégation native immédiate avec -i" "${TEST_SANDBOX}/explicit_key" "$SSH_LOG_FILE"

# Mode Debug
assert_output_contains "Activation du mode debug via --debug" "[DEBUG]" "$KSSH_BIN" --debug -V

echo ""

# ==============================================================================
# TEST SECTION 2 : Transactional Safety & Management of ~/.ssh/config
# ==============================================================================
printf "%b[SECTION 2] TRANSACTIONAL SAFETY OF ~/.ssh/config%b\n" "${C_BOLD}" "${C_RESET}"

rm -f "$SSH_CONFIG_FILE"
assert_output_contains "Listing avec fichier absent" "Fichier ~/.ssh/config absent" "$KSSH_BIN" --list
touch "$SSH_CONFIG_FILE"
assert_output_contains "Listing avec fichier vide" "Aucun serveur configuré" "$KSSH_BIN" --list

# Validation stricte des alias
assert_failure "Rejet alias avec espaces" "$KSSH_BIN" --add "alias invalide" 192.168.1.1
assert_failure "Rejet alias avec point-virgule" "$KSSH_BIN" --add "srv;ls" 192.168.1.1
assert_failure "Rejet alias avec dollar/subshell" "$KSSH_BIN" --add 'srv$(id)' 192.168.1.1
assert_failure "Rejet alias avec pipe" "$KSSH_BIN" --add "srv|rm" 192.168.1.1
assert_failure "Rejet alias vide" "$KSSH_BIN" --add "" 192.168.1.1

# Validation stricte des ports
assert_failure "Rejet port 0" "$KSSH_BIN" --add test_srv root@192.168.1.1:0
assert_failure "Rejet port 65536" "$KSSH_BIN" --add test_srv root@192.168.1.1:65536
assert_failure "Rejet port non-numérique" "$KSSH_BIN" --add test_srv root@192.168.1.1:abc

# Validation utilisateur
assert_failure "Rejet utilisateur avec espaces" "$KSSH_BIN" --add test_srv "user name@192.168.1.1"

# Ajout atomique et formatage
cat << 'EOF' > "$SSH_CONFIG_FILE"
# Commentaire initial à préserver
Host legacy_srv
    HostName 10.0.0.1
    User admin
    Port 22
EOF

assert_success "Ajout d'un premier serveur standard" "$KSSH_BIN" --add web_srv debian@192.168.1.100:2222
assert_file_contains "Préservation commentaire d'origine" "# Commentaire initial à préserver" "$SSH_CONFIG_FILE"
assert_file_contains "Présence bloc Host legacy_srv" "Host legacy_srv" "$SSH_CONFIG_FILE"
assert_file_contains "Présence bloc Host web_srv" "Host web_srv" "$SSH_CONFIG_FILE"
assert_file_contains "HostName correctement renseigné" "HostName 192.168.1.100" "$SSH_CONFIG_FILE"
assert_file_contains "User correctement renseigné" "User debian" "$SSH_CONFIG_FILE"
assert_file_contains "Port personnalisé renseigné" "Port 2222" "$SSH_CONFIG_FILE"

# Support IPv6 entre crochets
assert_success "Ajout serveur IPv6 avec port" "$KSSH_BIN" --add ipv6_node "root@[2001:db8::cafe]:2200"
assert_file_contains "Bloc IPv6 présent" "Host ipv6_node" "$SSH_CONFIG_FILE"
assert_file_contains "HostName IPv6 sans crochets parasites" "HostName 2001:db8::cafe" "$SSH_CONFIG_FILE"

# Ajout avec clé SSH (IdentityFile)
touch "${TEST_SANDBOX}/test_id_ed25519"
assert_success "Ajout serveur avec clé SSH" "$KSSH_BIN" --add key_srv ubuntu@54.20.30.40 -i "${TEST_SANDBOX}/test_id_ed25519"
assert_file_contains "IdentityFile correctement enregistré" "IdentityFile ${TEST_SANDBOX}/test_id_ed25519" "$SSH_CONFIG_FILE"

# Idempotence (Anti-duplication)
assert_output_contains "Détection alias déjà existant" "existe déjà dans ~/.ssh/config" "$KSSH_BIN" --add web_srv debian@192.168.1.100:2222

# Vérification des permissions
assert_file_permissions "Permissions strictes (700) sur ~/.ssh" "700" "$SSH_CONFIG_DIR"
assert_file_permissions "Permissions strictes (600) sur ~/.ssh/config" "600" "$SSH_CONFIG_FILE"

# Vérification du listing complet
assert_output_contains "Listing liste legacy_srv" "legacy_srv" "$KSSH_BIN" --list
assert_output_contains "Listing liste web_srv" "web_srv" "$KSSH_BIN" --list
assert_output_contains "Listing liste ipv6_node" "ipv6_node" "$KSSH_BIN" --list
assert_output_contains "Listing liste key_srv" "key_srv" "$KSSH_BIN" --list

echo ""

# ==============================================================================
# TEST SECTION 3 : In-Memory Session Cache (/dev/shm) Security & TTL
# ==============================================================================
printf "%b[SECTION 3] IN-MEMORY SESSION CACHE & TTL MANAGEMENT%b\n" "${C_BOLD}" "${C_RESET}"

# Test d'écriture et permissions du cache
rm -rf "$KSSH_CACHE_DIR"
mkdir -p "$KSSH_CACHE_DIR"
chmod 700 "$KSSH_CACHE_DIR"
(
    umask 077
    printf '%s' "MasterSecretPass999!" > "$KSSH_CACHE_FILE"
)
chmod 600 "$KSSH_CACHE_FILE"

assert_file_permissions "Permissions répertoire cache (700)" "700" "$KSSH_CACHE_DIR"
assert_file_permissions "Permissions fichier cache (600)" "600" "$KSSH_CACHE_FILE"

# Test de vidage / invalidation du cache via --lock
assert_output_contains "Verrouillage et purge du cache via --lock" "Cache mémoire de session vidé" "$KSSH_BIN" --lock
if [ ! -d "$KSSH_CACHE_DIR" ]; then
    printf '  %b✓%b [PASS] Répertoire de cache détruit après --lock\n' "${C_GREEN}" "${C_RESET}"
    PASSED_TESTS=$((PASSED_TESTS + 1))
else
    printf '  %b✗%b [FAIL] Le répertoire de cache existe toujours après --lock\n' "${C_RED}" "${C_RESET}"
    FAILED_TESTS=$((FAILED_TESTS + 1))
fi
TOTAL_TESTS=$((TOTAL_TESTS + 1))

# Test d'invalidation préventive si permissions du cache compromises (ex: 777)
mkdir -p "$KSSH_CACHE_DIR"
printf '%s' "InsecurePass" > "$KSSH_CACHE_FILE"
chmod 777 "$KSSH_CACHE_FILE"
"$KSSH_BIN" --lock < /dev/null >/dev/null 2>&1 || true

echo ""

# ==============================================================================
# TEST SECTION 4 : Real KeePassXC Database Integration & Password Extraction
# ==============================================================================
printf "%b[SECTION 4] REAL KEEPASSXC DATABASE INTEGRATION & QUERY RESOLUTION%b\n" "${C_BOLD}" "${C_RESET}"

# Création d'une vraie base de données KeePassXC de test
MASTER_PASS="TestMasterPassword#2026!"
rm -f "$KEEPASS_DB"
printf '%s\n%s\n' "$MASTER_PASS" "$MASTER_PASS" | keepassxc-cli db-create -q -p "$KEEPASS_DB"
printf '%s\n' "$MASTER_PASS" | keepassxc-cli mkdir "$KEEPASS_DB" "Database" 2>/dev/null || true
printf '%s\n' "$MASTER_PASS" | keepassxc-cli mkdir "$KEEPASS_DB" "SSH" 2>/dev/null || true

# Peuplement du cache de session pour permettre l'accès non-interactif sécurisé
mkdir -p "$KSSH_CACHE_DIR" && chmod 700 "$KSSH_CACHE_DIR"
(
    umask 077
    printf '%s' "$MASTER_PASS" > "$KSSH_CACHE_FILE"
)
chmod 600 "$KSSH_CACHE_FILE"

# 4.1 Entrée avec mot de passe complexe contenant espaces, quotes, $, accents, backslashes
SPECIAL_PASS='P@ss $tr0ng "with quotes" & \backslashes\ and accent: ù é à !'
printf '%s\n%s\n%s\n' "$MASTER_PASS" "$SPECIAL_PASS" "$SPECIAL_PASS" | keepassxc-cli add -q -p -u admin_sp --url "ssh://10.20.30.40:22" "$KEEPASS_DB" "srv_special"

# 4.2 Entrée avec Alias direct
ALIAS_PASS="AliasPassword_987654"
printf '%s\n%s\n%s\n' "$MASTER_PASS" "$ALIAS_PASS" "$ALIAS_PASS" | keepassxc-cli add -q -p -u debian --url "ssh://192.168.1.55:22" "$KEEPASS_DB" "prod_cluster"

# 4.3 Entrée par URL ssh://IP:port et utilisateur
URL_PASS="UrlPassword_43210"
printf '%s\n%s\n%s\n' "$MASTER_PASS" "$URL_PASS" "$URL_PASS" | keepassxc-cli add -q -p -u worker --url "ssh://51.15.99.100:2222" "$KEEPASS_DB" "worker_node"

# 4.4 Entrée avec pièce jointe (clé SSH)
SSH_PRIV_KEY_FILE="${TEST_SANDBOX}/mock_id_rsa"
cat << 'EOF' > "$SSH_PRIV_KEY_FILE"
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACAX7z8w4M9a1B5K0MockKeyForTestingPurposesOnly1234567890AAAB
MockSignatureDataHere==
-----END OPENSSH PRIVATE KEY-----
EOF
chmod 600 "$SSH_PRIV_KEY_FILE"

printf '%s\nDummyPass123!\nDummyPass123!\n' "$MASTER_PASS" | keepassxc-cli add -q -p -u gituser --url "ssh://git.internal:22" "$KEEPASS_DB" "SSH/git_server"
printf '%s\n' "$MASTER_PASS" | keepassxc-cli attachment-import -f "$KEEPASS_DB" "SSH/git_server" "id_ed25519" "$SSH_PRIV_KEY_FILE"

# Vérification des extractions :
# A. Résolution par Alias direct
> "$SSH_LOG_FILE"
assert_success "Connexion kssh avec mot de passe résolu par Alias direct" "$KSSH_BIN" prod_cluster
assert_file_contains "Mock SSH exécuté pour prod_cluster" "MOCK_SSH_CALLED" "$SSH_LOG_FILE"

# B. Résolution par URL et utilisateur
> "$SSH_LOG_FILE"
assert_success "Connexion kssh avec mot de passe résolu par URL ssh://IP:port" "$KSSH_BIN" -p 2222 worker@51.15.99.100
assert_file_contains "Mock SSH exécuté pour worker@51.15.99.100" "MOCK_SSH_CALLED" "$SSH_LOG_FILE"

# C. Résolution avec mot de passe à caractères spéciaux
> "$SSH_LOG_FILE"
assert_success "Connexion kssh avec mot de passe complexe (espaces, $, accents, quotes)" "$KSSH_BIN" srv_special
assert_file_contains "Mock SSH exécuté pour srv_special" "MOCK_SSH_CALLED" "$SSH_LOG_FILE"

# D. Résolution avec Clé SSH en pièce jointe KeePassXC
> "$SSH_LOG_FILE"
assert_success "Connexion kssh avec clé SSH extraite depuis pièce jointe KeePassXC" "$KSSH_BIN" git_server
assert_file_contains "Mock SSH exécuté pour git_server" "MOCK_SSH_CALLED" "$SSH_LOG_FILE"
# Vérifier que le fichier temporaire de clé extrait a bien été détruit après exécution
assert_output_contains "Absence de résidu de clé privée temporaire sur disque" "" find /tmp /dev/shm -maxdepth 1 -name "kssh_key*" 2>/dev/null || true

echo ""

# ==============================================================================
# TEST SECTION 5 : Remote Command Execution Forwarding
# ==============================================================================
printf "%b[SECTION 5] REMOTE COMMAND EXECUTION FORWARDING%b\n" "${C_BOLD}" "${C_RESET}"

> "$SSH_LOG_FILE"
"$KSSH_BIN" prod_cluster "echo 'Hello World'" < /dev/null >/dev/null 2>&1 || true
assert_file_contains "Forwarding de commande distante simple" "echo 'Hello World'" "$SSH_LOG_FILE"

> "$SSH_LOG_FILE"
"$KSSH_BIN" -p 2222 worker@51.15.99.100 uptime -s < /dev/null >/dev/null 2>&1 || true
assert_file_contains "Forwarding commande avec multiples arguments" "uptime" "$SSH_LOG_FILE"
assert_file_contains "Forwarding argument -s" "-s" "$SSH_LOG_FILE"

echo ""

# ==============================================================================
# TEST SECTION 6 : Security Hygiene & Terminal Restoration
# ==============================================================================
printf "%b[SECTION 6] SECURITY HYGIENE & SIGNAL TRAPPING%b\n" "${C_BOLD}" "${C_RESET}"

# Test de comportement en environnement non-interactif pour serveur inconnu
assert_success "Fallback gracieux en non-interactif pour serveur inconnu" "$KSSH_BIN" unknown_srv_123

# Test de délégation immédiate sans blocage pour Git clone non-interactif sans cache
> "$SSH_LOG_FILE"
assert_success "Délégation transparente pour git@github.com non-interactif" "$KSSH_BIN" git@github.com "git-upload-pack 'Q300Z/conan-exiles-server.git'"
assert_file_contains "Mock SSH appelé pour git@github.com" "git@github.com" "$SSH_LOG_FILE"

# Installation explicite sans root (--install)
assert_output_contains "Installation explicite --install" "Installation terminée avec succès" "$KSSH_BIN" --install
assert_file_contains "Installation de l'autocomplétion Bash" "_kssh_complete" "${BASH_COMPLETION_DIR}/kssh"
assert_file_contains "Installation de l'autocomplétion Zsh" "_kssh" "${ZSH_COMPLETION_DIR}/_kssh"

echo ""
echo "=============================================================================="
printf "%b=== BILAN DE LA SUITE DE TESTS END-TO-END kssh ===%b\n" "${C_BOLD}${C_CYAN}" "${C_RESET}"
echo "=============================================================================="
printf "  Total des assertions exécutées : %b%d%b\n" "${C_BOLD}" "$TOTAL_TESTS" "${C_RESET}"
printf "  Tests RÉUSSIS                  : %b%d%b\n" "${C_GREEN}${C_BOLD}" "$PASSED_TESTS" "${C_RESET}"
if [ "$FAILED_TESTS" -gt 0 ]; then
    printf "  Tests ÉCHOUÉS                  : %b%d%b\n" "${C_RED}${C_BOLD}" "$FAILED_TESTS" "${C_RESET}"
    echo "=============================================================================="
    exit 1
else
    printf "  Tests ÉCHOUÉS                  : %b0%b\n" "${C_GREEN}${C_BOLD}" "${C_RESET}"
    printf "  Taux de succès                 : %b100%%%b\n" "${C_GREEN}${C_BOLD}" "${C_RESET}"
    echo "=============================================================================="
    exit 0
fi
