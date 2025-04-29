#!/usr/bin/bash

# Vérification que deux arguments numériques (entiers ou décimaux) sont fournis
if ! [[ $1 =~ ^[0-9]+([,.][0-9]+)?$ ]] || ! [[ $2 =~ ^[0-9]+([,.][0-9]+)?$ ]]; then
    echo "Erreur: Veuillez fournir deux nombres (entiers ou décimaux) en arguments."
    echo "Usage: $0 <heures_avant_blocage> <durée_blocage_en_heures>"
    echo "Exemple: $0 0.5 2.5 (pour 30 minutes avant blocage et 2h30 de blocage)"
    exit 1
fi

# Récupération et normalisation des arguments (remplacer virgule par point)
DELAY_HOURS=$(echo $1 | tr ',' '.')
LOCK_HOURS=$(echo $2 | tr ',' '.')

# Conversion en secondes directement pour plus de précision
# bc est utilisé pour les calculs avec nombres décimaux
DELAY_SECONDS=$(echo "$DELAY_HOURS * 3600" | bc)
LOCK_SECONDS=$(echo "$LOCK_HOURS * 3600" | bc)

# Convertir en nombres entiers pour les calculs de timestamp
DELAY_SECONDS=${DELAY_SECONDS%.*}
LOCK_SECONDS=${LOCK_SECONDS%.*}

# Calculer les timestamps Unix pour le début et la fin du verrouillage
START_TIME=$(($(date +%s) + DELAY_SECONDS))
END_TIME=$((START_TIME + LOCK_SECONDS))

# Créer un fichier de verrouillage avec les dates de début et de fin
LOCK_FILE="/etc/lockdown_schedule"
echo "$START_TIME $END_TIME" | sudo tee $LOCK_FILE > /dev/null
sudo chmod 600 $LOCK_FILE

# Créer le script de vérification qui sera exécuté au démarrage
CHECKER_SCRIPT="/usr/local/bin/lockdown-checker.sh"
sudo bash -c "cat > $CHECKER_SCRIPT << 'EOL'
#!/bin/bash

LOCK_FILE=\"/etc/lockdown_schedule\"

if [ -f \"\$LOCK_FILE\" ]; then
    CURRENT_TIME=\$(date +%s)
    read START_TIME END_TIME < \"\$LOCK_FILE\"
    
    if [ \$CURRENT_TIME -ge \$START_TIME ] && [ \$CURRENT_TIME -lt \$END_TIME ]; then
        # Le système est dans la période de verrouillage, éteindre l'ordinateur
        echo \"Système verrouillé jusqu'à \$(date -d \"@\$END_TIME\" '+%H:%M:%S le %d/%m/%Y'). Arrêt en cours...\"
        sleep 3
        /usr/bin/systemctl poweroff
    elif [ \$CURRENT_TIME -ge \$END_TIME ]; then
        # La période de verrouillage est terminée, supprimer le fichier
        rm -f \"\$LOCK_FILE\"
    fi
fi
EOL"

sudo chmod +x $CHECKER_SCRIPT

# Créer un service systemd pour le contrôle au démarrage
STARTUP_SERVICE="/etc/systemd/system/lockdown-check.service"
sudo bash -c "cat > $STARTUP_SERVICE << 'EOL'
[Unit]
Description=Vérification du verrouillage temporaire
DefaultDependencies=no
After=sysinit.target
Before=display-manager.service getty@tty1.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/lockdown-checker.sh
TimeoutSec=0
StandardOutput=syslog

[Install]
WantedBy=sysinit.target
EOL"

# Créer également un hook pour le gestionnaire d'affichage
DISPLAY_HOOK="/etc/X11/Xsession.d/00lockdown-check"
sudo bash -c "cat > $DISPLAY_HOOK << 'EOL'
#!/bin/bash
/usr/local/bin/lockdown-checker.sh
EOL"
sudo chmod +x $DISPLAY_HOOK

# Créer un script pour déclencher l'arrêt à l'heure prévue
DELAY_SHUTDOWN_SCRIPT="/usr/local/bin/lockdown-trigger.sh"
sudo bash -c "cat > $DELAY_SHUTDOWN_SCRIPT << EOL
#!/bin/bash

# Attendre le délai spécifié
sleep $DELAY_SECONDS

# Vérifier si le fichier de verrouillage existe toujours
if [ -f \"$LOCK_FILE\" ]; then
    # Afficher un message d'avertissement
    DISPLAY=:0 /usr/bin/notify-send -u critical \"Verrouillage du système\" \"Le système va s'éteindre dans 60 secondes pour la période de verrouillage programmée.\" || true
    
    # Attendre un peu pour que l'utilisateur puisse voir le message
    sleep 60
    
    # Exécuter la vérification de verrouillage
    $CHECKER_SCRIPT
    
    # Si nous sommes toujours là, forcer l'arrêt
    /usr/bin/systemctl poweroff
fi
EOL"

sudo chmod +x $DELAY_SHUTDOWN_SCRIPT

# Exécuter le script de déclenchement en arrière-plan avec nohup
sudo bash -c "nohup $DELAY_SHUTDOWN_SCRIPT > /dev/null 2>&1 &"

# Activer les services
sudo systemctl daemon-reload
sudo systemctl enable lockdown-check.service

# Calculer des valeurs pour l'affichage
DELAY_MINUTES=$(echo "$DELAY_HOURS * 60" | bc)
LOCK_MINUTES=$(echo "$LOCK_HOURS * 60" | bc)

# Afficher un message d'information avec conversion en format lisible
START_DATE=$(date -d "@$START_TIME" '+%H:%M:%S le %d/%m/%Y')
END_DATE=$(date -d "@$END_TIME" '+%H:%M:%S le %d/%m/%Y')

# Fonction pour formater les heures et minutes
format_time() {
    local total_hours=$1
    local hours=${total_hours%.*}
    local decimal_part=${total_hours#*.}
    local minutes=$(echo "0.$decimal_part * 60" | bc)
    minutes=${minutes%.*}
    
    if [[ $hours -eq 0 ]]; then
        echo "$minutes minutes"
    elif [[ $minutes -eq 0 ]]; then
        echo "$hours heures"
    else
        echo "$hours heures et $minutes minutes"
    fi
}

DELAY_FORMATTED=$(format_time $DELAY_HOURS)
LOCK_FORMATTED=$(format_time $LOCK_HOURS)

echo "Programmation du verrouillage :"
echo "- Début du verrouillage : $START_DATE (dans $DELAY_FORMATTED)"
echo "- Fin du verrouillage : $END_DATE (durée totale: $LOCK_FORMATTED)"
echo "- L'ordinateur s'éteindra automatiquement au début de la période de verrouillage"
echo "- Toute tentative de démarrage pendant la période de verrouillage échouera"

# S'assurer que bc est installé
command -v bc >/dev/null 2>&1 || { echo "La commande 'bc' est nécessaire pour les calculs décimaux. Veuillez l'installer avec 'sudo dnf install bc'."; exit 1; }

