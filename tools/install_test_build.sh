#!/bin/bash
# Copies the tested build-test/ into build/ (where the player starts the game): the exe together with the game code
# library it was built with (odyssey_game.dll and its .id) and the import library setup builds against. Copying the exe
# alone left build/ with game code for another version, and the app asked to rebuild it ("The game code builder is
# missing", update 36). Refuses while the game runs from build/ (the files are locked).
cd "$(dirname "$0")/.."
if tasklist //FI "IMAGENAME eq OdysseyRecomp.exe" 2>/dev/null | grep -qi OdysseyRecomp.exe; then
    echo "OdysseyRecomp.exe is running: close the game first"; exit 1
fi
for f in OdysseyRecomp.exe odyssey_game.dll odyssey_game.dll.id OdysseyRecomp.dll.a; do
    [ -f "build-test/$f" ] || { echo "build-test/$f missing: make B=build-test first"; exit 1; }
done
cp build-test/OdysseyRecomp.exe build-test/odyssey_game.dll build-test/odyssey_game.dll.id build-test/OdysseyRecomp.dll.a build/
echo "build/ now runs the build-test build (game code id $(cat build/odyssey_game.dll.id))"
