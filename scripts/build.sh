#!/bin/zsh
# Compila e monta dist/Controle Remoto.app (para uso local).
# Uso: scripts/build.sh [--install]   (--install copia para ~/Applications e abre)
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release

APP="dist/Controle Remoto.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ControleRemoto "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
# O ícone faz parte do projeto (Resources/AppIcon.icns). Para redesenhar: scripts/make-icon.sh
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# Assina com o certificado Apple Development, se houver: com identidade estável o macOS
# lembra a permissão de Rede Local entre uma compilação e outra (ad-hoc pede de novo).
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 -o '"Apple Development[^"]*"' | tr -d '"' || true)
if [[ -n "$IDENTITY" ]]; then
    codesign --force --options runtime --sign "$IDENTITY" "$APP"
    echo "Assinado com: $IDENTITY"
else
    codesign --force --sign - "$APP"
    echo "Assinado ad-hoc (sem certificado Apple Development)"
fi
echo "Pronto: $APP"

if [[ "${1:-}" == "--install" ]]; then
    mkdir -p ~/Applications
    pkill -x ControleRemoto 2>/dev/null || true
    rm -rf ~/Applications/"Controle Remoto.app"
    cp -R "$APP" ~/Applications/
    open ~/Applications/"Controle Remoto.app"
    echo "Instalado em ~/Applications/Controle Remoto.app"
fi
