#!/usr/bin/bash

# Vérifier si on est root
if [ "$(id -u)" -ne 0 ]; then
   echo "Ce script doit être exécuté en tant que root (sudo)."
   exit 1
fi

# Vérifier les arguments
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <heures_avant_blocage> <durée_blocage_en_heures>"
    echo "Exemple: $0 0.5 8 (pour un blocage dans 30 min qui dure 8h)"
    exit 1
fi

# Remplacer les virgules par des points
DELAY_HOURS=$(echo $1 | tr ',' '.')
LOCK_HOURS=$(echo $2 | tr ',' '.')

# Installer bc si nécessaire
if ! command -v bc &> /dev/null; then
    echo "Installation de bc nécessaire pour les calculs..."
    dnf install -y bc
fi

# Convertir en secondes
DELAY_SECONDS=$(echo "$DELAY_HOURS * 3600" | bc | cut -d'.' -f1)
LOCK_DURATION_SECONDS=$(echo "$LOCK_HOURS * 3600" | bc | cut -d'.' -f1)

# Calculer timestamps
CURRENT_TIME=$(date +%s)
START_TIME=$((CURRENT_TIME + DELAY_SECONDS))
END_TIME=$((START_TIME + LOCK_DURATION_SECONDS))

echo "Configuration du verrouillage avancé..."

# Créer le répertoire de configuration si nécessaire
mkdir -p /etc/lockdown

# Stocker la configuration
echo "$START_TIME $END_TIME" > /etc/lockdown/schedule
chmod 600 /etc/lockdown/schedule

# NOUVEAU: Modifier directement l'initramfs pour forcer la vérification très tôt
# Créer un script qui sera exécuté très tôt dans le processus de démarrage
cat > /usr/local/bin/early-lockdown-check.sh << 'EOF'
#!/bin/bash

# Fonction pour éteindre le système en cas de verrouillage actif
check_lockdown() {
    if [ -f "/etc/lockdown/schedule" ]; then
        read START_TIME END_TIME < /etc/lockdown/schedule
        CURRENT_TIME=$(date +%s)
        
        if [ "$CURRENT_TIME" -ge "$START_TIME" ] && [ "$CURRENT_TIME" -lt "$END_TIME" ]; then
            echo "SYSTÈME VERROUILLÉ JUSQU'À $(date -d "@$END_TIME" '+%H:%M:%S le %d/%m/%Y')"
            echo "ARRÊT AUTOMATIQUE DANS 10 SECONDES..."
            sleep 10
            /sbin/poweroff -f
            # Bloquer complètement le démarrage
            exit 1
        elif [ "$CURRENT_TIME" -ge "$END_TIME" ]; then
            # Période terminée, supprimer le fichier
            rm -f /etc/lockdown/schedule
        fi
    fi
    return 0
}

# Exécuter la vérification
check_lockdown
EOF

chmod +x /usr/local/bin/early-lockdown-check.sh

# Créer un module dracut pour l'exécution très précoce
mkdir -p /usr/lib/dracut/modules.d/99lockdown/
cat > /usr/lib/dracut/modules.d/99lockdown/module-setup.sh << 'EOF'
#!/bin/bash

check() {
    return 0
}

depends() {
    return 0
}

install() {
    inst_hook pre-mount 10 "$moddir/lockdown-check.sh"
    inst_simple /etc/lockdown/schedule /etc/lockdown/schedule
    inst_multiple date cut grep head tail sed
}
EOF

chmod +x /usr/lib/dracut/modules.d/99lockdown/module-setup.sh

# Créer le script de vérification pour dracut
cat > /usr/lib/dracut/modules.d/99lockdown/lockdown-check.sh << 'EOF'
#!/bin/sh

# Point de montage temporaire pour rootfs
TEMP_MNT="/sysroot"

# Si le fichier de verrouillage existe
if [ -f "/etc/lockdown/schedule" ]; then
    # Lire les timestamps
    read START_TIME END_TIME < /etc/lockdown/schedule
    CURRENT_TIME=$(date +%s)
    
    # Si on est dans la période de verrouillage
    if [ $CURRENT_TIME -ge $START_TIME ] && [ $CURRENT_TIME -lt $END_TIME ]; then
        # Afficher message et bloquer le démarrage
        echo "SYSTÈME VERROUILLÉ JUSQU'À $(date -d "@$END_TIME" '+%H:%M:%S le %d/%m/%Y')" > /dev/tty1
        echo "ARRÊT DANS 10 SECONDES..." > /dev/tty1
        sleep 10
        /sbin/poweroff -f
        # Bloquer complètement le démarrage
        while true; do
            echo "SYSTÈME VERROUILLÉ" > /dev/tty1
            sleep 5
            /sbin/poweroff -f
        done
    fi
fi
EOF

chmod +x /usr/lib/dracut/modules.d/99lockdown/lockdown-check.sh

# Reconstruire l'initramfs
echo "Reconstruction de l'initramfs avec le module de verrouillage..."
dracut -f

# Créer aussi un script normal de vérification (comme backup)
cat > /usr/local/bin/lockdown-check.sh << 'EOF'
#!/bin/bash

# Vérifier si le fichier existe
if [ ! -f "/etc/lockdown/schedule" ]; then
    exit 0
fi

# Lire les timestamps
read START_TIME END_TIME < /etc/lockdown/schedule
CURRENT_TIME=$(date +%s)

# Vérifier la période
if [ "$CURRENT_TIME" -ge "$START_TIME" ] && [ "$CURRENT_TIME" -lt "$END_TIME" ]; then
    # En période de verrouillage
    echo "Système verrouillé jusqu'à $(date -d "@$END_TIME")"
    sleep 3
    /sbin/poweroff -f
elif [ "$CURRENT_TIME" -ge "$END_TIME" ]; then
    # Période terminée
    rm -f /etc/lockdown/schedule
fi
EOF

chmod +x /usr/local/bin/lockdown-check.sh

# Créer plusieurs services systemd pour redondance
# 1. Service très tôt dans le démarrage
cat > /etc/systemd/system/lockdown-check-early.service << 'EOF'
[Unit]
Description=Vérification précoce du verrouillage
DefaultDependencies=no
Before=sysinit.target
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/lockdown-check.sh
TimeoutSec=0

[Install]
WantedBy=sysinit.target
EOF

# 2. Service avant login
cat > /etc/systemd/system/lockdown-check.service << 'EOF'
[Unit]
Description=Vérification du verrouillage
DefaultDependencies=no
Before=display-manager.service getty@.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/lockdown-check.sh
TimeoutSec=0

[Install]
WantedBy=multi-user.target
EOF

# 3. Hook GRUB pour la vérification très précoce
mkdir -p /etc/grub.d/
cat > /etc/grub.d/01_lockdown << 'EOF'
#!/bin/sh
exec tail -n +3 $0
# Vérification de verrouillage
if [ -s ${prefix}/lockdown ]; then
    set timeout=1
    menuentry "Système verrouillé" {
        echo "Système verrouillé"
        sleep 5
        halt
    }
fi
EOF
chmod +x /etc/grub.d/01_lockdown

# Créer le déclencheur de démarrage du verrouillage
cat > /usr/local/bin/lockdown-trigger.sh << EOF
#!/bin/bash

# Attendre le délai spécifié
sleep $DELAY_SECONDS

# Ajouter aussi un blocage dans GRUB
echo "$END_TIME" > /boot/grub2/lockdown

# Exécuter la vérification
/usr/local/bin/lockdown-check.sh
EOF
chmod +x /usr/local/bin/lockdown-trigger.sh

# Activer tous les services
systemctl daemon-reload
systemctl enable lockdown-check-early.service
systemctl enable lockdown-check.service

# Démarrer le déclencheur en arrière-plan
nohup /usr/local/bin/lockdown-trigger.sh >/dev/null 2>&1 &

# Créer une tâche cron pour l'arrêt programmé comme backup
if [ "$DELAY_SECONDS" -gt 60 ]; then
    SHUTDOWN_TIME=$(date -d "@$START_TIME" '+%H:%M')
    SHUTDOWN_DATE=$(date -d "@$START_TIME" '+%d/%m/%Y')
    echo "Programmation de l'arrêt à $SHUTDOWN_TIME le $SHUTDOWN_DATE"
    (crontab -l 2>/dev/null; echo "$(date -d "@$START_TIME" '+%M %H %d %m *') /sbin/poweroff -f # LOCKDOWN") | crontab -
fi

# VERROUILLAGE SUPPLÉMENTAIRE: Ajouter une règle udev pour éteindre le système dès qu'il est détecté
cat > /etc/udev/rules.d/99-lockdown.rules << EOF
ACTION=="add", SUBSYSTEM=="module", RUN+="/usr/local/bin/lockdown-check.sh"
EOF

# Modifier le fichier /etc/fstab pour monter le système de fichiers en lecture seule
cp /etc/fstab /etc/fstab.backup
sed -i '/[[:space:]]\/[[:space:]]/s/defaults/ro,defaults/' /etc/fstab

# Programmer la restauration du système de fichiers après la période
cat > /usr/local/bin/restore-fstab.sh << EOF
#!/bin/bash
# Ce script se déclenchera après la période de verrouillage
sleep $((LOCK_DURATION_SECONDS + DELAY_SECONDS + 300))  # Ajouter 5 minutes pour être sûr
cp /etc/fstab.backup /etc/fstab
rm -f /boot/grub2/lockdown
rm -f /etc/udev/rules.d/99-lockdown.rules
grep -v "LOCKDOWN" /var/spool/cron/root > /tmp/crontab.new
crontab /tmp/crontab.new
rm /tmp/crontab.new
rm -f /etc/lockdown/schedule
EOF
chmod +x /usr/local/bin/restore-fstab.sh
nohup /usr/local/bin/restore-fstab.sh >/dev/null 2>&1 &

# Reconstruire la configuration GRUB
echo "Mise à jour de la configuration GRUB..."
grub2-mkconfig -o /boot/grub2/grub.cfg

# Afficher un récapitulatif
echo "Verrouillage renforcé programmé avec succès :"
echo "- Début : $(date -d "@$START_TIME" '+%H:%M:%S le %d/%m/%Y') (dans environ $(echo "scale=2; $DELAY_HOURS" | bc) heures)"
echo "- Fin   : $(date -d "@$END_TIME" '+%H:%M:%S le %d/%m/%Y') (durée de $(echo "scale=2; $LOCK_HOURS" | bc) heures)"
echo "L'ordinateur s'éteindra automatiquement au début de la période."
echo "IMPORTANT: Plusieurs mécanismes de protection ont été mis en place pour empêcher complètement le démarrage."
