#!/bin/bash
# Desinstala Prisma por completo: app, ajustes, permiso de audio e inicio automático.
# Uso: ./uninstall.sh   (no necesita contraseña)
set -uo pipefail
ID="io.github.amaestra205.prisma"

echo "Cerrando Prisma…"
pkill -x Prisma 2>/dev/null || true   # al cerrarse, el audio de todas las apps vuelve a la normalidad
sleep 1

for D in /Applications "$HOME/Applications"; do
  if [ -d "$D/Prisma.app" ]; then
    rm -rf "$D/Prisma.app" && echo "Borrada $D/Prisma.app"
  fi
done

echo "Borrando ajustes…"
defaults delete "$ID" 2>/dev/null || true
rm -rf "$HOME/Library/Preferences/$ID.plist" \
       "$HOME/Library/Caches/$ID" \
       "$HOME/Library/HTTPStorages/$ID" \
       "$HOME/Library/Saved Application State/$ID.savedState"

echo "Quitando el permiso de grabación de audio…"
tccutil reset AudioCapture "$ID" >/dev/null 2>&1 || true

echo "Hecho. Si Prisma aparece en Ajustes > General > Ítems de inicio, desaparecerá solo."
