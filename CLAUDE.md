# Wallpy

App de macOS (barra de menú) que pone vídeos o imágenes en bucle como fondo de pantalla. Swift + AppKit/SwiftUI, sin dependencias externas en el código. Repo: https://github.com/drarekx/Wallpy (público).

Nació como réplica limpia (clean-room) de `iwallpaper.app` analizada con REA; no se copia nada de su binario ni de sus recursos.

## Compilar y ejecutar

```sh
swift build                      # debug, comprobación rápida
./build-app.sh                   # release universal (arm64 + x86_64) → build/Wallpy.app + build/Wallpy.zip
VERSION=1.5.0 ./build-app.sh     # versión en Info.plist (por defecto 1.0.0)
open build/Wallpy.app
build/Wallpy.app/Contents/MacOS/Wallpy --edit <vídeo>   # abre el editor de bucle directamente (desarrollo)
```

- Requisitos: macOS 14+, Xcode 16+. `Package.swift` usa tools 5.10 (modo Swift 5).
- La copia instalada vive en `/Applications/Wallpy.app`; la de `build/` es solo para desarrollo y tiene versión 1.0.0, así que su actualizador siempre ve versiones nuevas. Cierra una antes de abrir la otra (dos copias = dos fondos encima).
- No hay tests. Verificar compilando (`swift build` y `swift build --arch x86_64`) y lanzando la app.

## GitHub: ramas y protecciones

- `main` está protegida (ruleset «Protect main»): cambios por pull request con squash, comprobación `build` en verde (`.github/workflows/build.yml`: compila arm64 + x86_64 y verifica que `en` y `ca` tienen las mismas claves y que todo `tr()` está traducido), sin force-push ni borrado. El administrador puede saltárselo y empujar directo.
- Flujo normal: rama `feat/…` o `fix/…` → `gh pr create` → esperar `build` → `gh pr merge --squash`. La rama se borra sola al fusionar.
- Las etiquetas `v*` no se pueden borrar ni mover (ruleset «Protect version tags»): una versión publicada no se rehace; si sale mal, se publica la siguiente.
- Dependabot abre PR semanales para las GitHub Actions y avisa de vulnerabilidades.

## Publicar una versión

```sh
git tag v1.5.0 && git push origin v1.5.0
```

`.github/workflows/release.yml` (macos-15) compila con `VERSION` = tag, crea el release con `Wallpy.zip` y `Wallpy.zip.sha256`. Las apps instaladas se actualizan solas (`Updater.swift`) consultando `releases/latest`. Instalador: `install.sh` (`curl … | bash`). La app no está notarizada (firma ad-hoc).

## Estructura (`Sources/Wallpy/`)

| Archivo | Qué hace |
|---|---|
| `main.swift`, `AppDelegate.swift` | Arranque, app accesoria (`LSUIElement`), menú de barra, menú principal oculto (Edición), ventana de la biblioteca, limpieza de temporales, `--edit` |
| `ScreenWallpaper.swift` | Una ventana de fondo por pantalla (nivel escritorio) + ventana de oclusión; `AVPlayerLooper` para vídeo, `CALayer` para imagen |
| `WallpaperManager.swift` | Sincroniza pantallas con ajustes, decide reproducir/pausar (oclusión, batería, pantallas dormidas, pausa manual) |
| `VideoLibrary.swift` | Biblioteca (`Video` con `kind` vídeo/imagen), importación, miniaturas, GIF/APNG → MP4, `ImageLoader` |
| `OriginalsLibrary.swift` | Vídeos largos guardados para sacar más fondos |
| `Settings.swift` | `UserDefaults` (`com.egluu.wallpy`) y login item (`SMAppService`) |
| `Power.swift` | Estado de batería (IOKit) |
| `ExternalTools.swift` | Localiza y ejecuta `yt-dlp` / `ffmpeg` / `ffprobe` (no van incluidos; Homebrew) |
| `VideoProcessing.swift` | Descarga de YouTube, `SourceInfo`, exportación de bucles con ffmpeg (fundido con `xfade`) |
| `LibraryView.swift` | Ventana principal: barra lateral, Biblioteca + inspector, Originales, Ajustes |
| `EditorWindow.swift` | Editor de bucle: modelo, tramos, miniaturas, línea de tiempo, atajos |
| `LoopEditorView.swift` | Hoja de descarga de YouTube / preparación antes del editor |
| `ScheduleView.swift` | Programación: cuadrícula pantallas × momentos del día |
| `Overlays.swift` | Elementos sobre el fondo (hora, fecha): modelo `OverlayWidget`, `OverlayCanvas` (ventana de fondo y vista previa) |
| `OverlaysView.swift` | Sección «Elementos»: vista previa por pantalla y editor de cada elemento |
| `Theme.swift` | Colores, botones y controles comunes (estilo oscuro) |
| `Updater.swift` | Autoactualización desde GitHub Releases con verificación SHA-256 |
| `Migration.swift` | Migra datos del nombre antiguo (MyWallpaper) |
| `Localization.swift` | Idiomas (en, es, ca): `tr()`, `Localizer`, tablas de traducción |

Datos del usuario: `~/Library/Application Support/Wallpy/{Videos,Originals}`. Temporales: `$TMPDIR/Wallpy-*` (se borran al cerrar el editor y al arrancar).

## Convenciones

- Código, comentarios y commits en inglés. La interfaz está traducida a castellano, inglés y catalán.
- **Todo texto visible pasa por `tr("…")`** (o `tr("… %@ …", arg)` si lleva datos). La clave es el texto en castellano; añadir la traducción a las tablas `en` y `ca` de `Localization.swift` con los mismos `%@`/`%d`. Nunca interpolar (`"\(x)"`) dentro de un texto traducible.
- El idioma cambia en caliente: las vistas raíz observan `Localizer.shared` y usan `.id(localizer.language)`. Para probar un idioma sin tocar los ajustes: `Wallpy -appLanguage ca`.
- Estilo visual: usar siempre `Theme` y sus componentes (`WallpyButtonStyle`, `SegmentedControl`, `SwitchRow`, `wallpyCard`…), nunca colores sueltos. Maqueta de referencia: https://claude.ai/artifact/91yUdiBHZoDwh5x3i9LLBK
- Tipos `@MainActor` para estado de UI; lo que corre fuera (ffmpeg, decodificar imágenes) va en funciones `nonisolated`/colas de fondo.
- Mantener el README al día cuando cambian funciones visibles.

## Cosas que ya costaron (no repetir)

- **Sin menú principal no funciona ⌘V** en los campos de texto (app accesoria): por eso `setupMainMenu()` crea un menú Edición invisible.
- **`NSHostingController` encoge la ventana** a su tamaño ideal: poner `sizingOptions = []` y `setContentSize` después.
- **Nivel de ventana**: fondo en `CGWindowLevelForKey(.desktopWindow)`; con «ocultar iconos», `desktopIconWindow + 1`. `collectionBehavior` = todos los Spaces, estacionaria, fuera de ⌘Tab.
- **Pausa por oclusión**: se mide con una ventana vacía del tamaño de `visibleFrame` (sin barra de menú ni Dock), no con la ventana del fondo, que nunca queda tapada del todo.
- **`hevc_videotoolbox -q:v` solo existe en Apple Silicon**; en Intel se usa tasa de bits (`ExportQuality.encoderArguments`).
- yt-dlp suele bajar AV1 en 4K; AVFoundation lo decodifica en M3/M4. Si no se puede (`SourceInfo.isPreviewable`), se convierte antes de abrir el editor.
- Filtros de ffmpeg: pasar los argumentos como lista (`Process`), no por shell, por las comillas de `scale='if(…)'`.
- GIF → MP4: `premultiply` deja la transparencia en negro; dimensiones pares y `setsar=1`.
- **Elementos sobre el fondo**: `NSHostingView` hermana del `PlayerView` dentro de un contenedor (no subvista del reproductor, para que el fundido al cambiar de fondo no la afecte), oculta si la pantalla no tiene elementos. Un único temporizador en `WallpaperManager` alineado al minuto/segundo; nada de `TimelineView(.animation)` ni desenfoques sobre el vídeo.
- Al cambiar el nombre/ID de la app, migrar `Application Support` y el dominio de `UserDefaults`.

## Pruebas manuales

- No hay permiso de grabación de pantalla: las capturas fallan. Para comprobar ventanas, usar `CGWindowListCopyWindowInfo` filtrando por propietario `Wallpy`.
- Para probar descargas, usar vídeos con licencia libre (p. ej. Big Buck Bunny, `aqz-KE-bpKQ`) y `--download-sections` para bajar solo un trozo. No descargar vídeos largos del usuario.
- La biblioteca real del usuario tiene vídeos suyos: si una prueba la toca, hacer copia de `library.json` y de los ajustes (`defaults export com.egluu.wallpy`) y restaurarlos después.
