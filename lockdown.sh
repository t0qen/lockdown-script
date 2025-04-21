#!/usr/bin/bash

# Vérification que deux arguments numériques sont fournis
if ! [[ $1 =~ ^[0-9]+$ ]] || ! [[ $2 =~ ^[0-9]+$ ]]; then
    echo "Erreur: Veuillez fournir deux nombres entiers en arguments."
    echo "Usage: $0 <minutes_avant_blocage> <durée_blocage_en_minutes>"
    exit 1
fi

# Récupération des arguments
DELAY_MINUTES=$1
LOCK_MINUTES=$2

# Convertir en secondes
DELAY_SECONDS=$((DELAY_MINUTES * 60))
LOCK_SECONDS=$((LOCK_MINUTES * 60))

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

# Programmer l'arrêt automatique du système au moment du début du verrouillage
sudo bash -c "cat > /etc/systemd/system/lockdown-start.service << 'EOL'
[Unit]
Description=Service de démarrage du verrouillage temporaire
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'LOCK_FILE=\"/etc/lockdown_schedule\"; if [ -f \"\$LOCK_FILE\" ]; then read START_TIME END_TIME < \"\$LOCK_FILE\"; CURRENT_TIME=\$(date +%%s); if [ \$CURRENT_TIME -lt \$START_TIME ]; then shutdown -h +$(($DELAY_MINUTES)) \"Début de la période de verrouillage programmée\"; fi; fi'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOL"

# Activer les services
sudo systemctl daemon-reload
sudo systemctl enable lockdown-check.service
sudo systemctl enable lockdown-start.service
sudo systemctl start lockdown-start.service

# Afficher un message d'information
START_DATE=$(date -d "@$START_TIME" '+%H:%M:%S le %d/%m/%Y')
END_DATE=$(date -d "@$END_TIME" '+%H:%M:%S le %d/%m/%Y')

echo "Programmation du verrouillage :"
echo "- Début du verrouillage : $START_DATE (dans $DELAY_MINUTES minutes)"
echo "- Fin du verrouillage : $END_DATE (durée totale: $LOCK_MINUTES minutes)"
echo "- L'ordinateur s'éteindra automatiquement au début de la période de verrouillage"
echo "- Toute tentative de démarrage pendant la période de verrouillage échouera"
