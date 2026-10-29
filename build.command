#!/bin/bash
# Compila Prisma y la instala en Aplicaciones.
# Uso: doble clic en este archivo, o ./build.command desde el Terminal.
# Para ver el registro de diagnóstico: PRISMA_DEBUG=1 /Applications/Prisma.app/Contents/MacOS/Prisma
cd "$(dirname "$0")"
LOG="$PWD/build.log"
APPNAME="Prisma"
(
  set -e
  echo "== Compilando $(date '+%H:%M:%S')"
  scripts/build-app.sh
  DEST=/Applications
  [ -w "$DEST" ] || DEST="$HOME/Applications"
  mkdir -p "$DEST"
  pkill -x "$APPNAME" || true
  sleep 0.7
  rm -rf "$DEST/$APPNAME.app"
  cp -R "build/$APPNAME.app" "$DEST/"
  # Registra la app para que Finder, Spotlight y el Dock muestren el icono.
  LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  "$LSR" -f "$DEST/$APPNAME.app" || true
  touch "$DEST/$APPNAME.app"
  echo "== BUILD_OK $(date '+%H:%M:%S')"
) > "$LOG" 2>&1
if grep -q BUILD_OK "$LOG"; then
  DEST=/Applications; [ -w "$DEST" ] || DEST="$HOME/Applications"
  open "$DEST/$APPNAME.app"
  rm -f "$LOG"
  echo "Listo: Prisma está abierta (icono en la barra de menús)."
else
  echo "La compilación ha fallado. Detalles en build.log:"
  tail -30 "$LOG"
  osascript -e 'display notification "Revisa build.log" with title "Prisma: la compilación ha fallado"' 2>/dev/null
fi
exit 0
