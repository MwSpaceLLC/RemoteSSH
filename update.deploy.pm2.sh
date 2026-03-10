#!/bin/bash
# Aleksandr Ivanovitch | MwSpace LLC
# Server manager for node/pm2 build update app
# ===========================================
# version 5.5 | deploy script | 14/08/2025

#                 __
#  /\/\__      __/ _\_ __   __ _  ___ ___
# /    \ \ /\ / /\ \| '_ \ / _` |/ __/ _ \
#/ /\/\ \ V  V / _\ \ |_) | (_| | (_|  __/
#\/    \/\_/\_/  \__/ .__/ \__,_|\___\___|
#                   |_|
#
# DO NOT EDIT BELOW ----------------------

set -euo pipefail
IFS=$'\n\t'

# Configurazioni base
BASE_DIR="$(pwd)"
RELEASES_DIR="${BASE_DIR}/releases"
CURRENT_LINK="${BASE_DIR}/current"
TIMESTAMP=$(date +%Y%m%d%H%M%S)
RELEASE_DIR="${RELEASES_DIR}/release-${TIMESTAMP}"
KEEP_RELEASES=5

# Funzione di logging
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Funzione di error handling
error() {
    log "ERRORE: $1"
    exit 1
}

# Funzione per ottenere l'URL del repository Git
get_git_repo_url() {
    local git_dir="${BASE_DIR}/.git"

    if [ -d "$git_dir" ]; then
        # Prova a ottenere l'URL del remote origin
        if command -v git &> /dev/null; then
            local repo_url=$(cd "$BASE_DIR" && git config --get remote.origin.url 2>/dev/null)
            if [ -n "$repo_url" ]; then
                echo "$repo_url"
                return 0
            fi
        fi

        # Fallback: cerca nel file config di git
        if [ -f "$git_dir/config" ]; then
            local url=$(grep -A2 '\[remote "origin"\]' "$git_dir/config" | grep 'url' | cut -d'=' -f2 | tr -d ' ')
            if [ -n "$url" ]; then
                echo "$url"
                return 0
            fi
        fi
    fi

    return 1
}

# Funzione per generare il nome PM2 basato sul percorso
generate_pm2_name() {
    local path="$1"

    # Rimuovi il trailing slash se presente
    path="${path%/}"

    # Prendi solo la parte dopo /home/
    if [[ "$path" =~ ^/home/([^/]+)/(.+)$ ]]; then
        local user="${BASH_REMATCH[1]}"
        local rest="${BASH_REMATCH[2]}"

        # Combina utente e path rimanente
        local full_path="${user}/${rest}"

        # Prendi solo l'ultima parte del path (nome del progetto)
        local project_name=$(basename "$path")

        # Se il nome del progetto sembra un dominio, usa quello
        if [[ "$project_name" =~ \. ]]; then
            # Converti il dominio in formato pm2-friendly
            # esempio: app.name.com -> app-name-com
            local pm2_name="${project_name//\./-}"
        else
            # Altrimenti usa utente + nome progetto
            local pm2_name="${user}-${project_name}"
        fi

        # Rimuovi caratteri non alfanumerici (tranne il trattino)
        pm2_name="${pm2_name//[^[:alnum:]-]/-}"

        # Rimuovi trattini multipli consecutivi
        pm2_name=$(echo "$pm2_name" | sed 's/-\+/-/g')

        # Rimuovi trattini all'inizio e alla fine
        pm2_name="${pm2_name#-}"
        pm2_name="${pm2_name%-}"

        # Converti in minuscolo
        pm2_name="${pm2_name,,}"

        echo "$pm2_name"
    else
        # Fallback: usa solo il nome della directory corrente
        local dir_name=$(basename "$path")
        echo "${dir_name//[^[:alnum:]]/-}" | tr '[:upper:]' '[:lower:]'
    fi
}

# Funzione per trovare una porta libera
find_free_port() {
    local start_port=${1:-3000}
    local max_port=$((start_port + 100))

    for port in $(seq $start_port $max_port); do
        if ! lsof -i:$port &>/dev/null && ! netstat -tuln | grep -q ":$port "; then
            echo $port
            return 0
        fi
    done

    # Se non trova niente, ritorna la porta di default
    echo $start_port
}

# Funzione principale per caricare le variabili d'ambiente
load_env() {
    local env_file=""
    local default_port=3000

    # Prima controlla se esiste nella directory corrente
    if [ -f "${BASE_DIR}/.env.local" ]; then
        env_file="${BASE_DIR}/.env.local"
        log "Caricamento variabili da ${env_file}..."

        # Carica le variabili dal file
        set -a
        source "$env_file"
        set +a
    else
        log "WARNING: File .env.local non trovato in ${BASE_DIR}"
        log "Utilizzo dei valori di default..."
    fi

    # REPO_URL: cerca nella cartella .git se non definito
    if [ -z "${REPO_URL:-}" ]; then
        log "REPO_URL non definito, cerco nel repository Git locale..."
        REPO_URL=$(get_git_repo_url)

        if [ -z "$REPO_URL" ]; then
            error "Impossibile determinare REPO_URL. Non trovato né in .env.local né nella configurazione Git"
        else
            log "REPO_URL trovato dalla configurazione Git: ${REPO_URL}"
            export REPO_URL
        fi
    fi

    # PM2_APP_NAME: genera dal percorso se non definito
    if [ -z "${PM2_APP_NAME:-}" ]; then
        log "PM2_APP_NAME non definito, genero dal percorso..."
        PM2_APP_NAME=$(generate_pm2_name "$BASE_DIR")

        if [ -z "$PM2_APP_NAME" ]; then
            # Fallback finale
            PM2_APP_NAME="nextjs-app-$(date +%s)"
        fi

        log "PM2_APP_NAME generato: ${PM2_APP_NAME}"
        export PM2_APP_NAME
    fi

    # PORT/PM2_APP_PORT: usa default o trova porta libera se non definito
    if [ -z "${PORT:-}" ] && [ -z "${PM2_APP_PORT:-}" ]; then
        log "PORT/PM2_APP_PORT non definiti, cerco una porta libera..."

        # Prova prima con la porta di default
        PORT=$(find_free_port $default_port)
        PM2_APP_PORT=$PORT

        log "Porta assegnata: ${PORT}"
        export PORT
        export PM2_APP_PORT
    elif [ -n "${PORT:-}" ] && [ -z "${PM2_APP_PORT:-}" ]; then
        # Se PORT è definito ma non PM2_APP_PORT
        PM2_APP_PORT=$PORT
        export PM2_APP_PORT
    elif [ -z "${PORT:-}" ] && [ -n "${PM2_APP_PORT:-}" ]; then
        # Se PM2_APP_PORT è definito ma non PORT
        PORT=$PM2_APP_PORT
        export PORT
    fi

    # Log finale delle variabili caricate
    log "Variabili d'ambiente caricate:"
    log "  REPO_URL: ${REPO_URL}"
    log "  PM2_APP_NAME: ${PM2_APP_NAME}"
    log "  PORT: ${PORT:-$PM2_APP_PORT}"
    log "  PM2_APP_PORT: ${PM2_APP_PORT:-$PORT}"

    # Verifica finale che tutte le variabili critiche siano presenti
    if [ -z "${REPO_URL:-}" ] || [ -z "${PM2_APP_NAME:-}" ] || ([ -z "${PORT:-}" ] && [ -z "${PM2_APP_PORT:-}" ]); then
        error "Variabili critiche mancanti dopo il caricamento"
    fi
}

# Funzione di cleanup
cleanup() {
    local exit_code=$?
    log "Esecuzione cleanup..."

    # Se lo script fallisce, rimuovi la release corrente
    if [ $exit_code -ne 0 ]; then
        log "Deploy fallito, rimozione della release corrente..."
        rm -rf "$RELEASE_DIR"
    fi

    exit $exit_code
}

# REGISTRA IL TRAP SUBITO DOPO LA DEFINIZIONE
trap cleanup EXIT

# Verifica prerequisiti
check_prerequisites() {
    log "Verifico i prerequisiti..."

    # Controlla git, node e npm (richiesti manualmente)
    if ! command -v git &> /dev/null; then
        error "git non trovato. Installalo manualmente prima di continuare"
    fi

    if ! command -v node &> /dev/null; then
        error "node non trovato. Installalo manualmente prima di continuare"
    fi

    if ! command -v npm &> /dev/null; then
        error "npm non trovato. Installalo manualmente prima di continuare (solitamente viene con Node.js)"
    fi

    # Controlla e installa pm2 se mancante
    if ! command -v pm2 &> /dev/null; then
        log "pm2 non trovato, installazione in corso..."

        # Installa pm2 globalmente via npm
        npm install -g pm2

        # Verifica se l'installazione è riuscita
        if ! command -v pm2 &> /dev/null; then
            error "Installazione pm2 fallita. Prova con: sudo npm install -g pm2"
        fi

        log "pm2 installato con successo"
    fi

    log "Tutti i prerequisiti sono soddisfatti"
}

# Setup directory
setup_directories() {
    log "Creo le directory necessarie..."
    mkdir -p "${RELEASES_DIR}"
}

# Funzione per verificare e copiare .env.local
check_and_copy_env() {
    log "Verifico il file .env.local..."

    # Prima controlla se esiste nella directory corrente
    if [ -f "${BASE_DIR}/.env.local" ]; then
        log "Trovato [.env.local] nella directory base, lo copio nella nuova release..."
        cp "${BASE_DIR}/.env.local" "$RELEASE_DIR/"
        return 0
    fi

    # Se non è stato trovato in nessun posto, fallisci
    log "Errore: File .env.local non trovato né nella directory base né nella release corrente"
    return 1
}

deploy_release() {
    log "Clono il repository..."
    git clone --depth 1 "$REPO_URL" "$RELEASE_DIR"

    # Verifica e copia .env.local prima di procedere
    check_and_copy_env || exit 1

    cd "$RELEASE_DIR"

    log "Installo le dipendenze..."
    npm ci --loglevel=error  # mostra solo errori | --omit=dev not work for nextjs

    log "Eseguo il build..."
    npm run build
}

# Funzione per configurare PM2 resurrect
setup_pm2_resurrect() {
    log "Verifico configurazione PM2 resurrect..."

    # Verifica se il cron job per PM2 esiste già
    if ! crontab -l 2>/dev/null | grep -q "pm2 resurrect"; then
        log "Aggiungo PM2 resurrect al crontab..."

        # Salva il PATH corrente per PM2
        CURRENT_PATH="$PATH"

        # Aggiungi il cron job preservando quelli esistenti
        (crontab -l 2>/dev/null || true; echo "PATH=$CURRENT_PATH"; echo "@reboot pm2 resurrect &> /dev/null") | crontab -

        log "PM2 resurrect configurato per l'avvio automatico"
    else
        log "PM2 resurrect già configurato nel crontab"
    fi

}

# Gestione PM2
deploy_pm2_app() {
    log "Deploy pm2 Application..."

    # Assicurati di essere nella directory current
    cd "$CURRENT_LINK"

    log "Rimozione dell'applicazione..."
    pm2 delete "$PM2_APP_NAME" > /dev/null 2>&1 || log "Nessuna applicazione da rimuovere"

    # Esporta le variabili per PM2
    export PM2_APP_NAME  # esporta la variabile già caricata da load_env()
    export PM2_APP_PORT  # esporta la variabile già caricata da load_env()

    # Controlla se esiste ecosystem.config.js
    if [ -f "ecosystem.config.js" ]; then
        log "Trovato ecosystem.config.js, avvio con configurazione personalizzata..."
        pm2 start ecosystem.config.js --wait-ready || error "Impossibile avviare l'applicazione con ecosystem"
    else
        log "File ecosystem.config.js non trovato, avvio con configurazione base..."
        # Fallback: usa npm start con nome e porta
        pm2 start npm --name "$PM2_APP_NAME" -- start -- --port "$PM2_APP_PORT" || error "Impossibile avviare l'applicazione"
    fi

    pm2 save || error "Attenzione: Impossibile salvare la configurazione PM2"

    # Configura PM2 per l'avvio automatico
    setup_pm2_resurrect

}

# Aggiornamento symlink
update_symlinks() {
    log "Aggiorno i symlink..."
    if [ -L "$CURRENT_LINK" ]; then
        rm "$CURRENT_LINK"
    fi
    ln -s "$RELEASE_DIR" "$CURRENT_LINK"
}

# Pulizia vecchie release
cleanup_old_releases() {
    log "Rimuovo le vecchie release..."
    cd "${RELEASES_DIR}"
    ls -1dt release-* | tail -n +$((KEEP_RELEASES + 1)) | xargs -r rm -rf
}

log_brand() {
    cat << 'EOF'
                 __
  /\/\__      __/ _\_ __   __ _  ___ ___
 /    \ \ /\ / /\ \| '_ \ / _` |/ __/ _ \
/ /\/\ \ V  V / _\ \ |_) | (_| | (_|  __/
\/    \/\_/\_/  \__/ .__/ \__,_|\___\___|
                   |_|     Pm2 Install v5
EOF
}

# Main
main() {
    log_brand
    log ""
    log "Inizio processo di deploy..."

    load_env

    check_prerequisites
    setup_directories
    deploy_release

    update_symlinks
    deploy_pm2_app
    cleanup_old_releases

    log "========================================="
    log "Deploy completato con successo!"
    log "Release attiva: $(basename $RELEASE_DIR)"
    log "========================================="
}

main
